#!/bin/bash
# Sanitize for distribution: strips everything identifying from the system and leaves
# a generic user. Runs as ROOT inside the chroot.
set -uo pipefail
# config.env is left by stage1 inside the guest: it is the only way the
# host can communicate the build user. Without this, changing
# VM_USER made sanitize rename a user that does not exist.
[ -f /root/prov/config.env ] && . /root/prov/config.env
OLD="${DIST_OLD_USER:-${VM_USER:-}}"
NEW="${DIST_NEW_USER:-omarchy}"
[ -n "$OLD" ] || { echo "sanitize: do not know which user to start from" >&2; exit 1; }
getent passwd "$OLD" >/dev/null || { echo "sanitize: user '$OLD' does not exist" >&2; exit 1; }
log()  { echo ""; echo "==> $*"; }
warn() { echo "!!  $*" >&2; }

log "1/10 unanchoring /usr/share/omarchy from the user's home"
# It was a symlink to /home/<user>/.local/share/omarchy, which ties the system to
# that user. It is turned into a real directory (as the pacman package would) and
# the home then points there.
if [ -L /usr/share/omarchy ]; then
  TARGET=$(readlink -f /usr/share/omarchy)
  rm -f /usr/share/omarchy
  # Without set -e, a half-done cp (typically disk full: we just
  # duplicated the tree) did not stop the rm -rf below. The original was deleted
  # and /usr/share/omarchy was left incomplete: desktop with no themes and no
  # commands, with the phase saying OK. Now the original is only deleted if the
  # copy is complete.
  # Rollback has to leave the system EXACTLY as it was, or the
  # next attempt finds /usr/share/omarchy converted into a half-done
  # directory, skips this whole block (the guard is [ -L ... ]) and treats the
  # image as good. That is why the partial copy is deleted before remaking the
  # link: 'ln -sfn' on a real directory creates the link INSIDE it.
  volver_atras() {
    warn "$1"
    rm -rf /usr/share/omarchy
    ln -sfn "$TARGET" /usr/share/omarchy
    exit 1
  }
  cp -a "$TARGET" /usr/share/omarchy \
    || volver_atras "could not copy $TARGET to /usr/share/omarchy"
  chown -R root:root /usr/share/omarchy
  N_ORIG=$(find "$TARGET" -mindepth 1 | wc -l)
  N_COPIA=$(find /usr/share/omarchy -mindepth 1 | wc -l)
  [ "$N_COPIA" -ge "$N_ORIG" ] \
    || volver_atras "the copy was left incomplete ($N_COPIA of $N_ORIG entries)"
  rm -rf "$TARGET"
  echo "  /usr/share/omarchy is now a real directory ($(du -sh /usr/share/omarchy | cut -f1), $N_COPIA entries)"
fi

log "2/10 renaming user $OLD -> $NEW"
if id -u "$OLD" >/dev/null 2>&1; then
  pkill -u "$OLD" 2>/dev/null || true
  usermod -l "$NEW" -d "/home/$NEW" -m "$OLD"
  groupmod -n "$NEW" "$OLD" 2>/dev/null || true
  echo "$NEW:$NEW" | chpasswd
  echo "root:$NEW"  | chpasswd
fi
id "$NEW"
# the user's home points at the system tree
install -d -o "$NEW" -g "$NEW" "/home/$NEW/.local/share"
rm -rf "/home/$NEW/.local/share/omarchy"
ln -sfn /usr/share/omarchy "/home/$NEW/.local/share/omarchy"
chown -h "$NEW:$NEW" "/home/$NEW/.local/share/omarchy"

log "3/10 SDDM: autologin to the generic user"
cat > /etc/sddm.conf.d/20-autologin.conf <<EOF
[Autologin]
User=$NEW
Session=omarchy
EOF
grep -rl "$OLD" /etc/sddm.conf.d/ 2>/dev/null | while read -r f; do sed -i "s/\b$OLD\b/$NEW/g" "$f"; done
cat /etc/sddm.conf.d/20-autologin.conf

log "4/10 credentials and keys"
rm -rf "/home/$NEW/.ssh"
rm -f /etc/ssh/ssh_host_*        # they regenerate on their own at first boot
systemctl disable sshd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/sshd.service
rm -f /etc/sudoers.d/99-fix /etc/sudoers.d/99-install
rm -rf "/home/$NEW/.gnupg" "/home/$NEW/.local/share/keyrings" "/home/$NEW/.password-store"
echo "  sshd: $(systemctl is-enabled sshd 2>&1)"

log "5/10 machine identity"
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/hostname; echo omarchy > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   omarchy.localdomain omarchy
EOF

log "6/10 personal identity (git, histories, cache)"
rm -f "/home/$NEW/.gitconfig" "/home/$NEW/.config/git/config"
rm -f "/home/$NEW/.bash_history" "/home/$NEW/.zsh_history" "/home/$NEW/.local/share/fish/fish_history"
rm -rf "/home/$NEW/.cache" "/home/$NEW/.local/state/omarchy/first-run.log"
rm -rf "/home/$NEW/.local/share/omarchy-"* 2>/dev/null || true
rm -rf "/home/$NEW/shots" "/home/$NEW"/*.sh "/home/$NEW/config.env" 2>/dev/null || true
# NetworkManager: remove saved wifi networks
rm -f /etc/NetworkManager/system-connections/* 2>/dev/null || true

log "7b/10 proprietary apps out of the distributable image"
# These are installed with omarchy-arm-extras on the end user's machine.
# Packaging them in a .zip that is distributed would be redistributing
# third-party binaries, so they are removed even if they were in the source VM.
for pkg in 1password 1password-cli typora localsend-bin google-chrome obsidian-bin; do
  pacman -Q "$pkg" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$pkg" >/dev/null 2>&1 && echo "  removed $pkg"; }
done
for d in /opt/1Password /opt/obsidian /opt/typora; do
  [ -e "$d" ] && { rm -rf "$d"; echo "  removed $d"; }
done
rm -f /usr/local/bin/obsidian /usr/local/share/applications/obsidian.desktop 2>/dev/null || true
# Removing /opt/1Password leaves its /usr/bin links pointing at nothing. Same
# old oversight: a text sweep does not see a link's target.
for l in $(find /usr/bin /usr/local/bin -maxdepth 1 -xtype l 2>/dev/null); do
  case "$(readlink "$l")" in
    /opt/1Password/*|/opt/obsidian/*|/opt/typora/*)
      rm -f "$l"; echo "  dangling link removed: $l" ;;
  esac
done
# Traces they leave when installing: if Chrome is removed the Spotify webapp
# shortcut and launcher, which invoke it, must be removed too. Otherwise
# the image ships with a SUPER+SHIFT+M that points at a missing binary.
BIND="/home/$NEW/.config/hypr/bindings.lua"
if [ -f "$BIND" ] && grep -q "open.spotify.com" "$BIND"; then
  sed -i '/^-- Spotify has no native client/,/^o.bind("SUPER + SHIFT + M", "Spotify"/d' "$BIND"
  sed -i '/open\.spotify\.com/d' "$BIND"
  echo "  removed the SUPER+SHIFT+M shortcut for the Spotify webapp"
fi
rm -f "/home/$NEW/.local/share/applications/Spotify.desktop" \
      "/home/$NEW/.local/share/applications/spotify.desktop" 2>/dev/null || true
rm -rf "/home/$NEW/.local/share/omarchy/webapps" 2>/dev/null || true
echo "  (reinstall with: omarchy-arm-extras)"

log "7c/10 slimming: what was only needed to compile"
# Compiling the tools leaves entire compilation stacks behind (the .NET
# SDK is 425 MiB) and Rust and Go toolchains in the home. None of that is
# needed to use the image, and it takes ~2 GB out of the zip.
for p in dotnet-sdk-bin dotnet-targeting-pack-bin aspnet-targeting-pack-bin; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  removed $p"; }
done
# Omarchy 4 retires these four: quickshell is the bar, the menu, the OSD and the
# notification daemon. mako also steals org.freedesktop.Notifications via
# D-Bus activation and leaves notifications without a theme. They should not be
# installed, but if a future version of the list reintroduces them, they go.
for p in mako swayosd walker elephant; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  retired $p"; }
done
rm -rf "/home/$NEW/.config/mako" "/home/$NEW/.config/walker" "/home/$NEW/.config/swayosd"
rm -f  /usr/local/bin/walker
orph=$(pacman -Qdtq 2>/dev/null | tr '\n' ' ')
[ -n "${orph// /}" ] && { echo "  orphans: $orph"; pacman -Rns --noconfirm $orph >/dev/null 2>&1; }
rm -rf "/home/$NEW/.cargo" "/home/$NEW/go" "/home/$NEW/.rustup" "/home/$NEW/.npm" 2>/dev/null
echo "  essentials that must remain: $(for p in hyprland quickshell sddm; do printf '%s ' "$(pacman -Q $p 2>/dev/null || echo MISSING-$p)"; done)"

log "7d/10 slimming: what cannot be needed in a VM"
# Measured on a real image: 675 MiB of firmware for hardware that in a
# QEMU VM with virtio devices cannot exist. linux-firmware is not installed on
# purpose, but the per-vendor splits come in as dependencies.
FW=$(pacman -Qq 2>/dev/null | grep -E '^linux-firmware-(intel|nvidia|amdgpu|atheros|broadcom|realtek|mediatek|marvell|qcom|qlogic|liquidio|bnx2x|mellanox|nfp|other)$' | tr '\n' ' ')
if [ -n "${FW// /}" ]; then
  echo "  firmware for absent hardware: $FW"
  # -Rdd: the splits are claimed by the linux-firmware metapackage, which is
  # not needed either. If something objects, it is left as-is and nothing breaks.
  pacman -Rdd --noconfirm $FW linux-firmware >/dev/null 2>&1 \
    && echo "  removed" || echo "  (could not remove; leaving them)"
fi
# Documentation and manuals: 469 MiB. This is an image to try a desktop,
# not a server where you will read man. Omarchy's .md files are NOT touched.
for d in /usr/share/doc /usr/share/man /usr/share/info /usr/share/gtk-doc; do
  [ -d "$d" ] && { echo "  $d: $(du -shx "$d" 2>/dev/null | cut -f1)"; rm -rf "$d"; }
done
mkdir -p /usr/share/man /usr/share/doc
echo "  occupancy after the trim: $(df -h / | awk 'NR==2{print $3}')"

log "7/10 system logs and caches"
rm -rf /var/log/journal/* /var/log/omarchy* /var/log/pacman.log
find /var/log -type f -name "*.log" -delete 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* /var/tmp/* /tmp/* 2>/dev/null || true
# NOTE: /root/prov is NOT deleted here. Steps 8a and 8b read the update
# hook and the optional-apps installer from there; deleting it earlier left the
# image without either, silently. repair.sh removes it on leaving the
# chroot, which is where it belongs.
rm -rf /root/.bash_history /root/.cache 2>/dev/null || true
rm -f /root/STAGE2_OK 2>/dev/null || true
# Written by stage2 when some package does not install. In an image that is
# distributed, it tells the recipient what failed for the builder.
rm -f /root/failed-packages.txt 2>/dev/null || true
# The verify phase boots the VM before sanitizing, and that boot leaves a
# randomness seed and credential secret: identical in every copy.
rm -f /var/lib/systemd/random-seed /var/lib/systemd/credential.secret 2>/dev/null || true
: > /var/log/wtmp 2>/dev/null || true
: > /var/log/btmp 2>/dev/null || true
: > /var/log/lastlog 2>/dev/null || true

log "8/10 notice to the recipient"
cat > /etc/motd <<'EOF'

  Omarchy on Arch Linux ARM (aarch64) — UTM image for Apple Silicon

  User: omarchy   Password: omarchy   (also for root)

  >> CHANGE THE PASSWORD NOW:  passwd

  Keys: the Mac's Option (⌥) key acts as SUPER.
        ⌥+Space  Omarchy menu      ⌥+Return  terminal

  Missing 1Password, Obsidian, Typora, Spotify or LocalSend?
  They are not included because of licensing, but all have an official ARM64 build:

      omarchy-arm-extras --list     see what it can install
      omarchy-arm-extras            interactive menu

EOF
install -d -o "$NEW" -g "$NEW" "/home/$NEW/Desktop"
cp /etc/motd "/home/$NEW/Desktop/README.txt"
chown "$NEW:$NEW" "/home/$NEW/Desktop/README.txt"

log "8a/10 update hook for ARM"
# omarchy-update-dev does not update the tree when OMARCHY_PATH is
# /usr/share/omarchy, which is our case: without this hook Omarchy freezes.
if [ -f /root/prov/10-arm-sync ]; then
  install -Dm755 /root/prov/10-arm-sync "/home/$NEW/.config/omarchy/hooks/post-update.d/10-arm-sync"
  chown -R "$NEW:$NEW" "/home/$NEW/.config/omarchy/hooks" 2>/dev/null || true
  echo "  post-update.d/10-arm-sync"
fi
# The checkout must not get dirty from permission changes, or the pull will fail
git -C /usr/share/omarchy config core.fileMode false 2>/dev/null || true
git -C /usr/share/omarchy checkout -- . 2>/dev/null || true
echo "  clean checkout: $(git -C /usr/share/omarchy status --porcelain 2>/dev/null | wc -l) files"

log "8b/10 optional apps installer"
# repair.sh copies extras.sh as omarchy-arm-extras, but if that copy did not
# happen the whole block was skipped silently and the image shipped without the
# menu entry. Both names are accepted and a warning is issued if it is missing.
EXTRAS_SRC=""
for c in /root/prov/omarchy-arm-extras /root/prov/extras.sh; do
  [ -f "$c" ] && { EXTRAS_SRC="$c"; break; }
done
if [ -n "$EXTRAS_SRC" ]; then
  install -Dm755 "$EXTRAS_SRC" /usr/local/bin/omarchy-arm-extras
  install -Dm644 /dev/stdin /usr/local/share/applications/omarchy-arm-extras.desktop <<'DESK'
[Desktop Entry]
Name=Install missing apps (ARM)
Comment=1Password, Obsidian, Typora, LocalSend, Chrome, OBS, Pinta
Exec=xdg-terminal-exec omarchy-arm-extras
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;PackageManager;
DESK
  chown "$NEW:$NEW" /usr/local/share/applications/omarchy-arm-extras.desktop 2>/dev/null || true
  echo "  /usr/local/bin/omarchy-arm-extras + menu entry"
else
  warn "the optional-apps installer was not in the ISO: the image will ship without it"
fi

log "9/10 checking that nothing stayed tied to $OLD"
echo "  references in /etc:"; grep -rl "\b$OLD\b" /etc 2>/dev/null | head -5 || echo "    none"
echo "  home:"; ls -ld "/home/$NEW"; ls /home/
echo "  owner of leftover files:"; find /home/$NEW -maxdepth 2 ! -user "$NEW" 2>/dev/null | head -3 || echo "    all correct"

log "10/10 freeing unused space (so it compresses better)"
sync
fstrim -av 2>&1 | head -3 || true
echo ""
log "usermod backup files (contain the old user and hash)"
rm -f /etc/passwd- /etc/shadow- /etc/group- /etc/gshadow-
log "subuid/subgid"
sed -i "s/^$OLD:/$NEW:/" /etc/subuid /etc/subgid 2>/dev/null || true
cat /etc/subuid /etc/subgid 2>/dev/null

log "final sweep of references to $OLD"
echo "  /etc:"; grep -rl "\b$OLD\b" /etc 2>/dev/null || echo "    none"
echo "  /home:"; grep -rl "\b$OLD\b" /home/$NEW/.config /home/$NEW/.bashrc 2>/dev/null | head -5 || echo "    none"
echo "  /usr/local/bin:"; grep -rl "\b$OLD\b" /usr/local/bin 2>/dev/null | head -5 || echo "    none"
echo "  broken links in /usr/bin: $(find /usr/bin -xtype l 2>/dev/null | wc -l)"
echo "  /usr/share/omarchy (must not point at /home):"; ls -ld /usr/share/omarchy

log "system consistency"
echo "  passwd: $(getent passwd $NEW)"
echo "  home:   $(ls -ld /home/$NEW | awk '{print $3, $4, $9}')"
echo "  omarchy symlink: $(readlink /home/$NEW/.local/share/omarchy)"
echo "  autologin: $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | tr '\n' ' ')"
echo "  omarchy binaries: $(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l) in /usr/bin"
echo "  ttfx: $(command -v ttfx || echo NO)"
echo "  migrations sealed: $(ls -1 /home/$NEW/.local/state/omarchy/migrations 2>/dev/null | wc -l)"
sync
echo ""
log "Nautilus/GTK bookmarks pointing at the old home"
for f in /home/$NEW/.config/gtk-3.0/bookmarks /home/$NEW/.config/gtk-4.0/bookmarks; do
  [ -f "$f" ] && { sed -i "s#/home/$OLD#/home/$NEW#g" "$f"; echo "  $f:"; cat "$f"; }
done

log "real name in passwd (shown in the greeter)"
chfn -f "Omarchy" "$NEW" 2>/dev/null || usermod -c "Omarchy" "$NEW"
getent passwd "$NEW"

log "user-dirs with absolute paths"
for f in /home/$NEW/.config/user-dirs.dirs; do
  [ -f "$f" ] && sed -i "s#/home/$OLD#/home/$NEW#g" "$f"
done

log "symlinks that point at the old home"
# grep -rl only looks at file CONTENTS: a symbolic link's target
# is not content, so the text sweep treats them as clean.
# Omarchy stores the active theme and wallpaper as links
# (~/.local/state/omarchy/current/{theme,background}), so a dangling
# link leaves the desktop grey and unstyled, with no visible error.
mapfile -t BADLINKS < <(find /home/$NEW /etc /usr/bin /usr/local /opt -xdev -type l \
  -lname "*/home/$OLD/*" 2>/dev/null)
echo "  found: ${#BADLINKS[@]}"
for l in "${BADLINKS[@]:-}"; do
  [ -n "$l" ] || continue
  tgt=$(readlink "$l")
  ln -sfn "${tgt//\/home\/$OLD\//\/home\/$NEW\/}" "$l"
  echo "  $l -> $(readlink "$l")"
done
chown -h $NEW:$NEW "${BADLINKS[@]:-/home/$NEW}" 2>/dev/null || true

log "final sweep"
echo "  /etc:   $(grep -rl "\b$OLD\b" /etc 2>/dev/null | wc -l) matches"
echo "  /home:  $(grep -rl "\b$OLD\b" /home/$NEW/.config /home/$NEW/.bashrc /home/$NEW/.bash_profile 2>/dev/null | wc -l) matches"
echo "  links to /home/$OLD: $(find /home/$NEW /etc /usr/bin /usr/local /opt -xdev -type l -lname "*/home/$OLD/*" 2>/dev/null | wc -l)"
echo "  broken links in home: $(find /home/$NEW -xdev -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l)"
echo "  broken links in /usr/bin: $(find /usr/bin -xtype l 2>/dev/null | wc -l)"
echo "  active wallpaper: $(readlink -f /home/$NEW/.local/state/omarchy/current/background 2>/dev/null || echo NONE)"
test -e "/home/$NEW/.local/state/omarchy/current/background" \
  && echo "  wallpaper resolves: OK" || echo "  wallpaper resolves: BROKEN"
# ttfx is compiled from source inside the VM, and the binary keeps the
# compilation path in its debug info: /home/<builder>/... That is
# exactly what this phase exists to erase, so symbols are stripped
# instead of declaring it harmless, which is what it did before.
for b in /usr/local/bin/ttfx /usr/local/bin/omarchy-arm-vdagent; do
  [ -f "$b" ] || continue
  case "$(file -b "$b" 2>/dev/null)" in
    *ELF*) strip --strip-unneeded "$b" 2>/dev/null || true ;;
  esac
done
if strings /usr/local/bin/ttfx 2>/dev/null | grep -q "$OLD"; then
  echo "  ttfx: STILL mentions '$OLD' after strip"
else
  echo "  ttfx: no trace of the builder"
fi

log "final state for distribution"
echo "  user:            $(getent passwd $NEW | cut -d: -f1,5,6)"
echo "  autologin:       $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | sort -u | tr '\n' ' ')"
echo "  sshd:            $(systemctl is-enabled sshd 2>&1)"
echo "  optional installer: $(test -x /usr/local/bin/omarchy-arm-extras && echo yes || echo MISSING)"
echo "  menu entry:         $(test -f /usr/local/share/applications/omarchy-arm-extras.desktop && echo yes || echo MISSING)"
echo "  machine-id: $(wc -c < /etc/machine-id) bytes (empty = regenerates)"
echo ""
echo "  WARNING: from here on the image must not be booted again. The first"
echo "  boot regenerates machine-id, randomness seed and logs, and those"
echo "  would be identical in every distributed copy. If it has to be"
echo "  booted to verify something, repeat this phase afterwards."
echo "  ssh host keys: $(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l) (0 = they regenerate)"
echo "  hostname:   $(cat /etc/hostname)"
sync
fstrim -av 2>&1 | head -2 || true

# ─────────────────────── invariants: this CAN fail ──────────────────
# Until here everything was `echo`: the script runs without -e and always ended
# in an echo, so its rc was 0 no matter what. repair.sh collected that 0, the
# host saw TOK_REPAIR_0 and treated the image as clean. If usermod failed,
# an image with the builder's user and password was distributed.
log "distributable-image invariants"
FALLOS=0
mal() { echo "  ✗ $*"; FALLOS=$((FALLOS+1)); }
bien() { echo "  ✓ $*"; }

getent passwd "$NEW" >/dev/null && bien "user $NEW exists" || mal "user $NEW does not exist"
if [ "$OLD" != "$NEW" ]; then
  getent passwd "$OLD" >/dev/null && mal "the builder user ($OLD) still exists" \
                                  || bien "the builder user no longer exists"
fi
[ -d /usr/share/omarchy ] && [ ! -L /usr/share/omarchy ] \
  && bien "/usr/share/omarchy is a real directory" \
  || mal "/usr/share/omarchy is not a real directory"

N_CMD=$(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l)
[ "$N_CMD" -ge 400 ] && bien "$N_CMD omarchy-* commands" || mal "only $N_CMD omarchy-* commands (expected >=400)"

N_ROTO=$(find /usr/bin /usr/local/bin /home/"$NEW" -xdev -xtype l 2>/dev/null | wc -l)
[ "$N_ROTO" -le 5 ] && bien "$N_ROTO dangling links" || mal "$N_ROTO dangling links"

# File names, not just content: the sweep above uses grep -rl, which
# looks inside files. A file that CARRIES the builder's name in
# its own path (mise stores one per trusted directory) passed
# clean and travelled inside the image.
if [ "$OLD" != "$NEW" ]; then
  # NOTE: as a WORD, never as a substring. With "*$OLD*" and VM_USER=dev, this
  # matched /etc/udev and the rm -rf left the image without a single udev rule;
  # with VM_USER=arch it matched all of /home/omarchy. The build user's name
  # is chosen by environment, so the pattern has to require
  # that $OLD appear delimited by something that is not alphanumeric.
  RX_OLD=".*/([^/]*[^[:alnum:]])?$OLD([^[:alnum:]][^/]*)?"
  mapfile -t PORNOMBRE < <(find /home/"$NEW" /etc /usr/local /opt -xdev -mindepth 1 \
      -regextype posix-extended -regex "$RX_OLD" 2>/dev/null)
  if [ "${#PORNOMBRE[@]}" -gt 0 ] && [ -n "${PORNOMBRE[0]:-}" ]; then
    echo "  removing ${#PORNOMBRE[@]} file(s) whose NAME carries '$OLD':"
    for f in "${PORNOMBRE[@]}"; do echo "    $f"; rm -rf "$f"; done
  fi
  RESTAN=$(find /home/"$NEW" /etc /usr/local /opt -xdev -mindepth 1 \
      -regextype posix-extended -regex "$RX_OLD" 2>/dev/null | wc -l)
  [ "$RESTAN" -eq 0 ] && bien "no file name mentions $OLD" || mal "$RESTAN names still mention $OLD"
fi

# Clipboard: the five pieces that can break it.
[ -x /usr/local/bin/omarchy-arm-vdagent ] && bien "clipboard agent installed" || mal "missing /usr/local/bin/omarchy-arm-vdagent"
grep -qs -- ' -X ' /etc/systemd/system/spice-vdagentd.service.d/override.conf \
  && bien "spice-vdagentd with -X" || mal "spice-vdagentd without -X: clipboard will not work"
[ -e "/home/$NEW/.config/systemd/user/graphical-session.target.wants/omarchy-arm-vdagent.service" ] \
  && bien "agent enabled in the graphical session" \
  || mal "the agent was not enabled for $NEW"
if grep -vs -- '^[[:space:]]*--' "/home/$NEW/.config/hypr/autostart.lua" 2>/dev/null | grep -qs spice-vdagent; then
  mal "autostart.lua launches the official agent: vdagentd will disconnect both"
else
  bien "autostart.lua does not launch the official agent"
fi

[ "$(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l)" -eq 0 ] && bien "no ssh host keys" || mal "ssh host keys remain"

# Binaries compiled inside the VM: the compilation path stays in their
# debug info. grep -rl does not see them because it looks at text, not symbols.
if [ "$OLD" != "$NEW" ]; then
  # strings may not be present (it comes in binutils); if missing, say so and do not
  # invent a verdict.
  if ! command -v strings >/dev/null 2>&1; then
    echo "  ? binaries in /usr/local/bin: cannot check without 'strings'"
  else
    SUCIOS=""
    for b in /usr/local/bin/*; do
      [ -f "$b" ] || continue
      strings "$b" 2>/dev/null | grep -q "/home/$OLD" && SUCIOS="$SUCIOS $b"
    done
    [ -z "$SUCIOS" ] && bien "no binary in /usr/local/bin mentions the builder" \
                     || mal "binaries with the builder path inside:$SUCIOS (see RUSTFLAGS/CARGO_HOME in stage3)"
  fi
fi
[ -f /root/failed-packages.txt ] && mal "/root/failed-packages.txt remains" \
                                 || bien "no builder leftovers in /root"

echo ""
if [ "$FALLOS" -ne 0 ]; then
  echo "==> SANITIZE_FAILED: $FALLOS invariant(s) broken; this image CANNOT be distributed"
  exit 1
fi
echo ""
echo "==> SANITIZE_OK"
