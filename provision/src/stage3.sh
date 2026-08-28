#!/bin/bash
# Stage 3 — as a normal user inside the chroot.
# Omarchy dotfiles, theme, and the pieces that only exist in AUR.
set -uo pipefail   # no -e: this stage is best-effort in parts
. ~/config.env

log()  { echo ""; echo "==> [stage3] $*"; }
warn() { echo "!!  [stage3] $*"; }

export OMARCHY_PATH="$HOME/.local/share/omarchy"
export OMARCHY_INSTALL="$OMARCHY_PATH/install"
export PATH="$OMARCHY_PATH/bin:$PATH:$HOME/.local/bin"
export OMARCHY_CHROOT_INSTALL=1

# ------------------------------------------------------------ Omarchy repo
log "cloning basecamp/omarchy (branch ${OMARCHY_REF:-quattro} = Omarchy 4; master is 3.8.5)"
rm -rf "$OMARCHY_PATH"
mkdir -p "$(dirname "$OMARCHY_PATH")"
git clone --depth 1 --branch "${OMARCHY_REF:-quattro}" https://github.com/basecamp/omarchy.git "$OMARCHY_PATH" || { warn "clone failed"; exit 1; }
# core.fileMode=false BEFORE the chmod: otherwise the permission changes leave
# the checkout dirty and `git pull --ff-only` refuses to update it afterwards.
git -C "$OMARCHY_PATH" config core.fileMode false
find "$OMARCHY_PATH/bin" -type f -exec chmod +x {} \; 2>/dev/null
echo "  version: $(cat "$OMARCHY_PATH/version" 2>/dev/null)"

# ------------------------------------------------------------ dotfiles
# Equivalent to install/config/config.sh
log "copying dotfiles to ~/.config"
mkdir -p ~/.config
cp -R "$OMARCHY_PATH"/config/* ~/.config/
cp "$OMARCHY_PATH/default/bashrc" ~/.bashrc
ls ~/.config | tr '\n' ' '; echo

# ------------------------------------------------------------ AUR
log "AUR: Omarchy pieces that are not in the Arch Linux ARM repos"
mkdir -p /tmp/aur
aur_install() {
  local p="$1"
  echo "  --- $p"
  rm -rf "/tmp/aur/$p"
  git clone --depth 1 -q "https://aur.archlinux.org/$p.git" "/tmp/aur/$p" || { warn "clone $p"; return 1; }
  ( cd "/tmp/aur/$p" && makepkg -si --noconfirm --needed --noprogressbar ) >"/tmp/aur/$p.log" 2>&1 \
    || { warn "makepkg $p failed (log: /tmp/aur/$p.log)"; tail -15 "/tmp/aur/$p.log"; return 1; }
  echo "  ok: $p"
}

AUR_OK=(); AUR_KO=()
# xdg-terminal-exec resolves $TERMINAL. walker and elephant are NOT installed:
# quattro retires them (see bin/omarchy-upgrade-to-quattro); the launcher and
# the menu are quickshell panels (`omarchy-shell shell toggle omarchy.menu`).
for p in yay xdg-terminal-exec; do
  if aur_install "$p"; then AUR_OK+=("$p"); else AUR_KO+=("$p"); fi
done
echo "  AUR ok:     ${AUR_OK[*]:-none}"
echo "  AUR failed: ${AUR_KO[*]:-none}"

# Fallback if xdg-terminal-exec did not build: Omarchy uses $TERMINAL=xdg-terminal-exec
if ! command -v xdg-terminal-exec >/dev/null 2>&1; then
  warn "xdg-terminal-exec missing: installing a wrapper over alacritty"
  sudo install -m 0755 /dev/stdin /usr/local/bin/xdg-terminal-exec <<'EOF'
#!/bin/sh
# Minimal wrapper: Omarchy exports TERMINAL=xdg-terminal-exec.
# The fallback is foot, which IS in quattro's omarchy-base.packages
# (alacritty is not: pointing there left $TERMINAL broken).
T=$(command -v foot || command -v alacritty || command -v xterm) || exit 127
if [ "$#" -eq 0 ]; then exec "$T"; fi
exec "$T" -e "$@"
EOF
fi

# Default terminal: Omarchy prefers ghostty, which does not exist on aarch64.
# The fallback is foot, which DOES come in quattro's omarchy-base.packages (and
# alacritty does NOT: it is in neither that list nor the infra one). Naming
# Alacritty.desktop here pointed at a .desktop that does not exist in the image,
# and xdg-terminal-exec ended up picking by leftover. They are listed by
# preference and only those that are actually installed.
: > ~/.config/xdg-terminals.list
# Literal names, no ${t^}: that is bash 4 and although bash 5 is used in here,
# it is not worth leaving a bash-4-ism in a payload that is also read on a
# Mac with bash 3.2.
for f in com.mitchellh.ghostty.desktop ghostty.desktop \
         foot.desktop Alacritty.desktop alacritty.desktop xterm.desktop; do
  for d in /usr/share/applications /usr/local/share/applications "$HOME/.local/share/applications"; do
    [ -f "$d/$f" ] && { echo "$f" >> ~/.config/xdg-terminals.list; break; }
  done
done
[ -s ~/.config/xdg-terminals.list ] || printf 'foot.desktop\n' > ~/.config/xdg-terminals.list
echo "  preferred terminal: $(head -1 ~/.config/xdg-terminals.list)"

# ------------------------------------------------ system integration
# Omarchy 4 is distributed as a pacman package that places the tree in
# /usr/share/omarchy, the binaries on the system PATH, and hooks in
# /etc/profile.d and /usr/share/uwsm/env.d. That package only exists for x86_64,
# so it is replicated by hand here. Without this OMARCHY_PATH stays empty and
# Hyprland starts in emergency mode because it cannot find default/hypr/bootstrap.lua.
log "integrating Omarchy into system paths (replaces the pacman package)"
sudo ln -sfn "$OMARCHY_PATH" /usr/share/omarchy
# Commands go to /usr/bin, which is where upstream's package() puts them.
# Putting them in /usr/local/bin looked cleaner (no clash with pacman) but
# breaks things: the tree has 13 hard-wired /usr/bin/omarchy-* paths, five of
# them in .service files. enable-user-units.sh failed because of that, and
# since first-run is only marked done if NO step fails, it repeated on every
# login re-sending the "Update System" notice forever.
# Confirmed: none of the 433 names collides with an ALARM package.
sudo mkdir -p /usr/bin
# The links point to /usr/share/omarchy, NOT to $OMARCHY_PATH. Here they are
# the same thing (the first is a symlink to the second), but the sanitizer
# turns /usr/share/omarchy into a real directory and renames the user: a
# link to /home/<builder>/... is left dangling and takes down all 433
# commands. /usr/share/omarchy is the only stable path of the two.
n=0
for f in "$OMARCHY_PATH"/bin/*; do
  [ -f "$f" ] || continue
  chmod +x "$f"
  sudo ln -sfn "/usr/share/omarchy/bin/$(basename "$f")" "/usr/bin/$(basename "$f")" && n=$((n+1))
done
echo "  $n binaries in /usr/bin -> /usr/share/omarchy/bin"
# User units go to /usr/lib/systemd/user/, which is where systemd looks for
# them. They are installed by the omarchy-settings package, which also does
# not exist for ARM. Without this, install/user/first-run/enable-user-units.sh
# fails on every login, and since omarchy-provision-first-run is only marked
# done if NO step fails, first-run repeats indefinitely re-sending the
# "Update System" notice.
# Source: docs/file-layout.md, "systemd/user/*.service → /usr/lib/systemd/user/".
if [ -d "$OMARCHY_PATH/default/systemd/user" ]; then
  sudo install -d /usr/lib/systemd/user
  sudo cp -a "$OMARCHY_PATH/default/systemd/user/." /usr/lib/systemd/user/
  echo "  $(ls "$OMARCHY_PATH/default/systemd/user"/*.service 2>/dev/null | wc -l) user units in /usr/lib/systemd/user"
fi
for d in system-sleep zram-generator.conf.d; do
  [ -d "$OMARCHY_PATH/default/systemd/$d" ] && \
    sudo cp -a "$OMARCHY_PATH/default/systemd/$d" /usr/lib/systemd/ 2>/dev/null || true
done
sudo install -Dm644 "$OMARCHY_PATH/etc/profile.d/omarchy.sh" /etc/profile.d/omarchy.sh
sudo install -Dm644 "$OMARCHY_PATH/default/uwsm/env.d/10-omarchy" /usr/share/uwsm/env.d/10-omarchy
sudo cp -a "$OMARCHY_PATH/etc/sysctl.d/." /etc/sysctl.d/ 2>/dev/null || true
sudo cp -a "$OMARCHY_PATH/etc/security/." /etc/security/ 2>/dev/null || true
for d in system.conf.d user.conf.d logind.conf.d oomd.conf.d; do
  [ -d "$OMARCHY_PATH/etc/systemd/$d" ] && sudo cp -a "$OMARCHY_PATH/etc/systemd/$d" /etc/systemd/ 2>/dev/null || true
done
[ -d "$OMARCHY_PATH/etc/fastfetch" ] && sudo cp -a "$OMARCHY_PATH/etc/fastfetch" /etc/ 2>/dev/null || true
[ -d "$OMARCHY_PATH/etc/gnupg" ] && sudo cp -a "$OMARCHY_PATH/etc/gnupg/." /etc/gnupg/ 2>/dev/null || true
# systemd-oomd is configured in etc/systemd/oomd.conf.d but has to be
# enabled; NetworkManager-wait-online delays boot without contributing
# anything in a VM with user networking.
sudo systemctl enable systemd-oomd.service 2>/dev/null || true
sudo systemctl mask NetworkManager-wait-online.service 2>/dev/null || true
# gnome-keyring in SDDM's PAM blocks autologin without a configured keyring
for pf in /etc/pam.d/sddm /etc/pam.d/sddm-autologin /etc/pam.d/sddm-greeter; do
  [ -f "$pf" ] && sudo sed -i '/-auth.*pam_gnome_keyring\.so/d;/-password.*pam_gnome_keyring\.so/d' "$pf"
done

log "SDDM: Omarchy theme and session"
sudo mkdir -p /usr/share/sddm/themes /usr/local/share/wayland-sessions
sudo cp -a "$OMARCHY_PATH/default/sddm/omarchy" /usr/share/sddm/themes/ 2>/dev/null || true
[ -f "$OMARCHY_PATH/default/sddm/hyprland.lua" ] && sudo cp -a "$OMARCHY_PATH/default/sddm/hyprland.lua" /usr/share/sddm/hyprland.lua
sudo install -Dm644 "$OMARCHY_PATH/etc/sddm.conf.d/10-theme.conf"   /etc/sddm.conf.d/10-theme.conf
sudo install -Dm644 "$OMARCHY_PATH/etc/sddm.conf.d/10-wayland.conf" /etc/sddm.conf.d/10-wayland.conf
sudo install -Dm644 "$OMARCHY_PATH/default/wayland-sessions/omarchy.desktop" /usr/local/share/wayland-sessions/omarchy.desktop
sudo bash "$OMARCHY_PATH/install/config/theme-system.sh" 2>&1 | tail -2 || true

export OMARCHY_PATH=/usr/share/omarchy
export PATH="/usr/local/bin:$PATH"

# ------------------------------------------------------------ theme
log "applying the Tokyo Night theme"
mkdir -p ~/.config/omarchy/themes
if command -v omarchy-theme-set >/dev/null 2>&1; then
  omarchy-theme-set "Tokyo Night" || warn "omarchy-theme-set failed; linking by hand"
fi
if [ ! -e ~/.config/omarchy/current/theme ]; then
  mkdir -p ~/.config/omarchy/current
  ln -snf "$OMARCHY_PATH/themes/tokyo-night" ~/.config/omarchy/current/theme
fi
# Per-app theme links. In quattro the active theme lives in
# ~/.local/state/omarchy/current/theme (bin/omarchy-theme-set:12), not in
# ~/.config/omarchy/current, which is the Omarchy 3 path and does not exist here.
# There is no mako link: quattro has no external notification daemon.
mkdir -p ~/.config/btop/themes
ln -snf ~/.local/state/omarchy/current/theme/btop.theme ~/.config/btop/themes/current.theme
ls -l ~/.local/state/omarchy/current/ 2>/dev/null

# ------------------------------------------------------------ VM tweaks
log "virtual machine tweaks"
# quattro uses Lua configuration: writing monitors.conf would do nothing.
cat > ~/.config/hypr/monitors.lua <<'LUA'
-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- Available modes:  hyprctl monitors all
--
-- VM on UTM/QEMU with virtio-gpu. Two tweaks relative to Omarchy's values:
--
--  1. Scale 1 (Omarchy assumes 2x retina displays; in the VM that makes everything huge).
--  2. Fixed 1920x1200 resolution instead of "preferred", which gives 1280x800.
--
-- IMPORTANT: changing the mode LIVE (hyprctl / config reload) breaks
-- rendering under virgl: the desktop stays blank until reboot.
-- Applied from boot it works fine. If you touch this, reboot the VM.
--
-- For the resolution to follow the UTM window size:
--   hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.env("GDK_SCALE", "1")
hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })
LUA
rm -f ~/.config/hypr/monitors.conf ~/.config/hypr/autostart.conf

# Clipboard shared with the UTM host
cat > ~/.config/hypr/autostart.lua <<'LUA'
-- Extra processes at session start.
hl.on("hyprland.start", function()
  -- spice-vdagent is NOT launched: its clipboard is X11 and under Hyprland it dies
  -- with "cannot open display". Worse still, if it starts, vdagentd sees two agents
  -- in the same session and disconnects both ("multiple agents in one
  -- session"). The clipboard is handled by omarchy-arm-vdagent, as a user
  -- service.
end)
LUA

# --- seal migrations: a clean install is born at the final state ----------
# Without this omarchy-update tries to replay ~80 historical migrations and dies
# on the first one that installs an Omarchy-own package (x86_64 only).
mkdir -p ~/.local/state/omarchy/migrations
for f in "$OMARCHY_PATH"/migrations/*.sh; do
  [ -f "$f" ] && : > ~/.local/state/omarchy/migrations/"$(basename "$f")"
done
echo "  migrations sealed: $(ls -1 ~/.local/state/omarchy/migrations | wc -l)"

# --- branding (about + screensaver) -----------------------------------
mkdir -p ~/.config/omarchy/branding
cp "$OMARCHY_PATH/icon.txt" ~/.config/omarchy/branding/about.txt 2>/dev/null || true
cp "$OMARCHY_PATH/logo.txt" ~/.config/omarchy/branding/screensaver.txt 2>/dev/null || true

# --- omarchy-pkg-add tolerant of what does not exist on ARM ---------------
# CRITICAL: /usr/local/bin/omarchy-pkg-add is a symlink into the tree. Writing
# with `tee` would follow it and replace Omarchy's ORIGINAL script with this
# wrapper, whose REAL would then point at itself: infinite loop. The symlink
# must be deleted and a real file created.
sudo rm -f /usr/local/bin/omarchy-pkg-add
sudo install -Dm755 /dev/stdin /usr/local/bin/omarchy-pkg-add <<'WRAP'
#!/bin/bash
# Wrapper for Arch Linux ARM: Omarchy's own packages (tensaku,
# omarchy-nvim, ttfx...) and several proprietary apps only exist for x86_64.
# The original aborts if any is missing, which takes down omarchy-update
# entirely and leaves migrations half-done. Here they are skipped with a
# warning and the rest is installed.
REAL=/usr/share/omarchy/bin/omarchy-pkg-add
avail=(); skip=()
for p in "$@"; do
  if pacman -Q "$p" &>/dev/null || pacman -Si "$p" &>/dev/null; then
    avail+=("$p")
  else
    skip+=("$p")
  fi
done
((${#skip[@]})) && printf '\033[33mSkipped, does not exist on Arch Linux ARM: %s\033[0m\n' "${skip[*]}" >&2
((${#avail[@]})) || exit 0
exec "$REAL" "${avail[@]}"
WRAP

# --- Omarchy tools that are not published for aarch64 -------------
# Almost none are incompatible: they are Rust, Go or Qt/C++ and just need
# someone to build them. Several declare arch=(x86_64) by default, not because
# the code is not portable; in those cases adding the architecture is enough.
# They are built in increasing-cost order and none is fatal if it fails.
build_omarchy_tool() {                 # build_omarchy_tool <aur|omapkgs> <pkg>
  # A single `local` expands all values before assigning any of them,
  # so $pkg does not exist yet when constructing $dir. They must be split.
  local src="$1" pkg="$2"
  local dir="/tmp/omabuild/$pkg"
  pacman -Q "$pkg" >/dev/null 2>&1 && return 0
  rm -rf "$dir"; mkdir -p "$dir"
  case "$src" in
    aur)
      # AUR URLs use the PackageBase, which is not always the package
      # name (yaru-icon-theme lives in the "yaru" repo).
      local base
      base=$(curl -fsSL --max-time 20 "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" \
             | sed -n 's/.*"PackageBase":"\([^"]*\)".*/\1/p' | head -1)
      [ -n "$base" ] || base="$pkg"
      git clone -q "https://aur.archlinux.org/$base.git" "$dir" 2>/dev/null || return 1 ;;
    omapkgs)
      git clone --depth 1 --filter=blob:none --sparse -q \
        https://github.com/omacom-io/omarchy-pkgs.git "$dir/repo" || return 1
      ( cd "$dir/repo" && git sparse-checkout set "pkgbuilds/$pkg" >/dev/null 2>&1 )
      cp -a "$dir/repo/pkgbuilds/$pkg/." "$dir/" 2>/dev/null || return 1
      rm -rf "$dir/repo" ;;
  esac
  [ -f "$dir/PKGBUILD" ] || return 1
  # 'any' can come without quotes; mixing it with concrete architectures is a
  # makepkg error, so it is only patched when it is not 'any' and does not already have aarch64.
  grep -qE "^arch=\(.*\b(aarch64|any)\b" "$dir/PKGBUILD" || \
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
  # A PKGBUILD can generate several subpackages and only one of them have a
  # dependency missing on ARM (yaru-gtk-theme needs gtk-engine-murrine).
  # It is built without installing and then only the requested subpackage is installed.
  # -s installs the build dependencies. Without it, most of these
  # PKGBUILDs fail on the first step due to missing makedepends. -i is not used
  # because installation is done afterwards, subpackage by subpackage.
  # If it fails, the log is the only thing that explains why, and until now it
  # was lost with the `rm -rf /tmp/omabuild` two lines below: the build
  # said "failed to build: X" and there was no way to find out more.
  # The speed limit is removed by DisableDownloadTimeout in /etc/pacman.conf
  # (set by stage2): that way the pacman that makepkg -s launches for its
  # dependencies inherits it too. Passing it via the PACMAN variable does not
  # work, because makepkg invokes it quoted and a string with arguments is
  # looked up as if it were the executable name.
  if ( cd "$dir" && makepkg -s --noconfirm --needed --noprogressbar --nocheck ) >"$dir/build.log" 2>&1; then
    local built
    built=$(ls "$dir/$pkg"-*.pkg.tar.* 2>/dev/null | head -1)
    [ -n "$built" ] || built=$(ls "$dir"/*.pkg.tar.* 2>/dev/null | head -1)
    # theme-system.sh already created symlinks inside /usr/share/icons/Yaru because the
    # theme was not there: the real package collides with them. --overwrite resolves it.
    [ -n "$built" ] && sudo pacman -U --noconfirm --needed \
      --overwrite '/usr/share/icons/*' "$built" >>"$dir/build.log" 2>&1
  else
    mkdir -p "$HOME/.omarchy-arm-prov/failures"
    cp "$dir/build.log" "$HOME/.omarchy-arm-prov/failures/$pkg.log" 2>/dev/null || true
    echo "  --- $pkg failed; last lines of makepkg ---"
    tail -20 "$dir/build.log" 2>/dev/null | sed 's/^/      /'
    echo "  --- (full log at ~/.omarchy-arm-prov/failures/$pkg.log) ---"
    return 1
  fi
}

# Some PKGBUILDs invoke zig via a fixed versioned path (/opt/zig0.15/zig).
# On ARM there is only one zig version, so it is linked where they look for it.
if pacman -Si zig >/dev/null 2>&1; then
  sudo pacman -S --noconfirm --needed --disable-download-timeout zig >/dev/null 2>&1 || true
  for v in zig0.15 zig0.14; do
    sudo mkdir -p "/opt/$v" && sudo ln -sfn "$(command -v zig)" "/opt/$v/zig" 2>/dev/null || true
  done
fi

if [ "${HACER_TOOLS:-yes}" != "si" ] && [ "${HACER_TOOLS:-yes}" != "yes" ]; then
  warn "tool compilation disabled: ttfx, tensaku, omacalc,"
  warn "omacut, omawrite, aether, cliamp and omarchy-nvim will be missing (they can be added later"
  warn "with: yay -S <package>)"
else
log "compiling Omarchy tools missing on aarch64"
TOOLS_OK=(); TOOLS_KO=()
for spec in \
  "aur:yaru-icon-theme" "aur:ttf-ia-writer" "aur:tzupdate" "aur:ufw-docker" \
  "omapkgs:omarchy-nvim" "omapkgs:tobi-try" "aur:mise-bin" \
  "aur:aether" "aur:cliamp" \
  "omapkgs:omacalc" "omapkgs:omacut" "omapkgs:omawrite" \
  "aur:herdr" "omapkgs:tensaku" "omapkgs:hyprland-preview-share-picker"; do
  src=${spec%%:*}; pkg=${spec#*:}
  if build_omarchy_tool "$src" "$pkg"; then TOOLS_OK+=("$pkg"); else TOOLS_KO+=("$pkg"); fi
done
echo "  built: ${TOOLS_OK[*]:-none}"
[ ${#TOOLS_KO[@]} -gt 0 ] && warn "failed to build: ${TOOLS_KO[*]}"
rm -rf /tmp/omabuild
fi
# Omarchy deliberately replaces two Yaru icons with Adwaita's; if Yaru
# was just installed it has to be reapplied.
sudo bash "$OMARCHY_PATH/install/config/theme-system.sh" >/dev/null 2>&1 || true

# herdr is left out: its PKGBUILD uses `zig fetch` with Zig 0.15 semantics and
# Arch Linux ARM only packages 0.16 ("no build.zig file found"). Building
# zig0.15 from source takes hours and it is a development tool, not a
# desktop one.

# --- the kernel-reboot notice, which on ARM never turns off -------
# omarchy-update-restart decides whether the kernel changed by looking for a
# vmlinuz inside /usr/lib/modules/<version>/ that belongs to a package. On Arch
# x86_64 the linux package installs it there; on Arch Linux ARM, linux-aarch64
# leaves the image in /boot/Image and does NOT create that vmlinuz. The loop
# finds nothing, the variable stays "true" and it asks to reboot on every
# update, forever. This wrapper compares what actually matters: uname -r
# against the modules directory owned by the kernel package. /usr/local/bin
# comes before /usr/bin in PATH, so it replaces the original without touching
# the tree.
log "omarchy-update-restart wrapper (kernel notice on ALARM)"
sudo install -Dm755 /dev/stdin /usr/local/bin/omarchy-update-restart <<'KRN'
#!/bin/bash
# On Arch Linux ARM the kernel does not leave a vmlinuz in /usr/lib/modules/<ver>/,
# which is what the original looks for: without that it always asks to reboot.
# uname -r is compared with the modules directory that belongs to the kernel package.
if [ -z "${OMARCHY_SKIP_KERNEL_CHECK:-}" ]; then
  # modules.dep is generated by depmod and does not belong to any package. modules.builtin
  # IS shipped by linux-aarch64, so it can tell whether the running kernel's
  # modules directory is the one from the installed package.
  pkg=$(pacman -Qoq /usr/lib/modules/"$(uname -r)"/modules.builtin 2>/dev/null \
        || pacman -Qoq /usr/lib/modules/"$(uname -r)"/modules.order 2>/dev/null || true)
  if [ -n "$pkg" ]; then
    # The running kernel's modules directory belongs to the installed
    # package: there is no new kernel waiting for a reboot.
    export OMARCHY_KERNEL_CURRENT=1
  fi
fi
REAL=/usr/bin/omarchy-update-restart
[ -x "$REAL" ] || exit 0
if [ -n "${OMARCHY_KERNEL_CURRENT:-}" ]; then
  # Only the kernel block is skipped; the rest (Hyprland, services, shell)
  # is left intact by running the original with that check already resolved.
  sed 's#^kernel_updated=true$#kernel_updated=false#' "$REAL" | bash -s -- "$@"
else
  exec "$REAL" "$@"
fi
KRN
echo "  /usr/local/bin/omarchy-update-restart"

# --- ttfx: screensaver text effects (Rust, ~12 min) -----------
if ! command -v ttfx >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
  log "compiling ttfx from source (does not exist for aarch64)"
  rm -rf /tmp/ttfx-src
  # The build path stays INSIDE the binary: Rust puts the source path
  # into panic messages (.rodata), and strip cannot reach it. If it is
  # built from $HOME, the image that is distributed ends up saying who
  # built it. It is built in /tmp, with CARGO_HOME in /tmp so dependency
  # paths do not go through home either, and with --remap-path-prefix in case
  # one slips through anyway.
  if git clone --depth 1 -q https://github.com/omacom-io/ttfx.git /tmp/ttfx-src \
     && ( cd /tmp/ttfx-src \
          && CARGO_HOME=/tmp/cargo-ttfx \
             RUSTFLAGS="--remap-path-prefix=/tmp/ttfx-src=ttfx --remap-path-prefix=/tmp/cargo-ttfx=cargo --remap-path-prefix=$HOME=." \
             cargo build --release -q ); then
    sudo install -Dm755 /tmp/ttfx-src/target/release/ttfx /usr/local/bin/ttfx
    echo "  ttfx $(ttfx --version 2>/dev/null | head -1)"
  else
    warn "ttfx did not compile; the screensaver will show the logo without effects"
  fi
  rm -rf /tmp/ttfx-src /tmp/cargo-ttfx
fi

# --- keyboard: Finnish/detected layout and Super usable from macOS -------------------
# macOS intercepts Cmd before UTM sees it (Cmd+Space opens Spotlight), so
# Omarchy's SUPER shortcuts would be unreachable. altwin:swap_lalt_lwin
# swaps Alt and Super: the Mac's Option (⌥) key acts as SUPER.
cat > ~/.config/hypr/input.lua <<LUA
hl.config({
  input = {
    kb_layout  = "$VM_XKB",
    kb_options = "compose:caps,shift:both_capslock_cancel,altwin:swap_lalt_lwin",
  },
})
LUA

# --- no blur: rendering goes through llvmpipe (see 90-vm-graphics.conf) --------
cat > ~/.config/hypr/looknfeel.lua <<'LUA'
hl.config({
  decoration = {
    blur   = { enabled = false },
    shadow = { enabled = false },
  },
})
LUA

# --- environment reinforcement for apps launched by uwsm --------------------
mkdir -p ~/.config/uwsm/env.d
cat > ~/.config/uwsm/env.d/20-vm-graphics <<'ENVEOF'
export LIBGL_ALWAYS_SOFTWARE=1
ENVEOF

# User directories
xdg-user-dirs-update 2>/dev/null || true
mkdir -p ~/Pictures/Screenshots ~/Videos ~/Desktop ~/Documents ~/Downloads

# ------------------------------------------------------------ git
# --- optional installer for apps that do not ship in the image ---------------
# Several apps (1Password, Obsidian, Typora, LocalSend) DO have an official
# arm64 build, but they are proprietary: including them in an image that is
# distributed would be redistributing third-party binaries. The installer is left for the user.
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-extras" ]; then
  log "optional apps installer (omarchy-arm-extras)"
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-extras" /usr/local/bin/omarchy-arm-extras
  sudo install -Dm644 /dev/stdin /usr/local/share/applications/omarchy-arm-extras.desktop <<'DESK'
[Desktop Entry]
Name=Install missing apps (ARM)
Comment=1Password, Obsidian, Typora, LocalSend, Google Chrome
Exec=xdg-terminal-exec omarchy-arm-extras
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;PackageManager;
DESK
  echo "  available as a command and in the applications menu"
fi

# --- clipboard shared with the host ---------------------------
# The SPICE clipboard goes in three hops:
#   SPICE client (UTM) <-virtio-> spice-vdagentd <-unix socket-> agent
# The daemon talks to the host; the session agent only talks to the
# daemon. The OFFICIAL agent delivers the clipboard to X11 (vdagent.c:421 ->
# vdagent_clipboards_new(vdagent_display_get_x11(...)), zero references to
# wlr-data-control) and under Hyprland it dies with "cannot open display".
#
# omarchy-arm-vdagent fills that gap: same udscs protocol with the daemon,
# but wl-copy/wl-paste on the other side. The daemon stays as it is (with -X,
# see stage2): we replace the agent, NOT the daemon. Trying to talk over the
# virtio port directly leaves the daemon without a channel ("Device or resource
# busy") and the host ignores everything.
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-vdagent" ]; then
  log "clipboard agent for Wayland"
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-vdagent" /usr/local/bin/omarchy-arm-vdagent
  # The official agent must not start: vdagentd disconnects both if it sees
  # two agents in the same session ("multiple agents in one session").
  sudo systemctl --global mask spice-vdagent.service 2>/dev/null || true
  mkdir -p ~/.config/systemd/user
  cat > ~/.config/systemd/user/omarchy-arm-vdagent.service <<'UNIT'
[Unit]
Description=Shared clipboard with the host (SPICE over Wayland)
After=graphical-session.target
PartOf=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY

[Service]
Type=simple
# The socket is created by spice-vdagentd at start; if it is not there yet, retry.
ExecStartPre=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do [ -S /run/spice-vdagentd/spice-vdagent-sock ] && exit 0; sleep 2; done; exit 1'
ExecStart=/usr/local/bin/omarchy-arm-vdagent
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable omarchy-arm-vdagent.service 2>/dev/null || true
  echo "  /usr/local/bin/omarchy-arm-vdagent + user service"
fi
# Bridge via shared folder, as a fallback if the SPICE channel is not
# available (for example with Apple's virtualization backend).
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-clipboard" ]; then
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-clipboard" /usr/local/bin/omarchy-arm-clipboard
  echo "  /usr/local/bin/omarchy-arm-clipboard (shared-folder alternative)"
fi
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-share" ]; then
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-share" /usr/local/bin/omarchy-arm-share
  echo "  /usr/local/bin/omarchy-arm-share (mounts the folder, whether VirtFS or WebDAV)"

  # OBS Studio and Pinta are free software: they can travel inside the image, and
  # that is how it is distributed. They are installed with the same installer so as not
  # to duplicate its logic (OBS needs the browser plugin removed, whose CEF is
  # x86-only; Pinta needs Microsoft's arm64 .NET, which Arch does not package).
  # This is the most expensive part of the build: ~45 min. HACER_LIBRES=no skips it.
  if [ "${HACER_LIBRES:-yes}" = "si" ] || [ "${HACER_LIBRES:-yes}" = "yes" ]; then
    log "OBS Studio and Pinta (free software, go inside the image; ~45 min)"
    if /usr/local/bin/omarchy-arm-extras pinta obs; then
      echo "  pinta: $(pacman -Q pinta 2>/dev/null || echo MISSING)"
      echo "  obs:   $(pacman -Q obs-studio 2>/dev/null || echo MISSING)"
    else
      warn "OBS or Pinta were not installed; they can be added later with:"
      warn "  omarchy-arm-extras pinta obs"
    fi
  else
    echo "  OBS and Pinta skipped (HACER_LIBRES=no)"
  fi
fi

# --- updates: so "Update System" works and is reversible --------
# a) snapper: without it, omarchy-snapshot returns 127 and every update is done
#    without a prior snapshot, i.e. with no way to roll back.
# b) post-update hook: omarchy-update-dev only does `git pull` when
#    OMARCHY_PATH points OUTSIDE /usr/share/omarchy, and here it points right there.
#    Without the hook, the system receives packages but the Omarchy tree (scripts,
#    themes, configuration) stays frozen at the cloned version.
log "updates: snapper + post-update hook"
sudo pacman -S --noconfirm --needed --disable-download-timeout snapper >/dev/null 2>&1 || warn "snapper not available"
if command -v snapper >/dev/null 2>&1; then
  sudo bash -euo pipefail "$OMARCHY_PATH/install/config/snapper.sh" >/dev/null 2>&1 \
    && echo "  snapper configured: snapshot before each update" \
    || warn "could not configure snapper"
fi
if [ -f "$HOME/.omarchy-arm-prov/10-arm-sync" ]; then
  install -Dm755 "$HOME/.omarchy-arm-prov/10-arm-sync" ~/.config/omarchy/hooks/post-update.d/10-arm-sync
  echo "  post-update hook installed"
fi

log "git"
git config --global user.name  "$VM_FULLNAME"
git config --global user.email "$VM_EMAIL"
git config --global init.defaultBranch master

# ------------------------------------------------------------ summary
log "summary"
echo "  omarchy:   $(ls -d "$OMARCHY_PATH" 2>/dev/null || echo MISSING)"
echo "  ~/.config: $(ls ~/.config | wc -l) entries"
echo "  theme:     $(readlink -f ~/.config/omarchy/current/theme 2>/dev/null || echo 'not linked')"
echo "  hyprland:  $(command -v Hyprland || command -v hyprland || echo 'NO')"
echo "  omarchy-shell: $(command -v omarchy-shell || echo 'NO')"
echo "  terminal:  $(command -v xdg-terminal-exec || echo 'NO')"
echo ""
echo "==> [stage3] COMPLETED"
