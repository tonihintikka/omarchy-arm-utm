#!/bin/bash
#
#  omarchy-arm-extras — installs apps on Arch Linux ARM that do not ship in the image
#  ───────────────────────────────────────────────────────────────────────────
#  Proprietary ones are NOT shipped inside on purpose: packaging them in a
#  .zip that is distributed would be redistributing third-party binaries. This
#  script downloads them from their OFFICIAL source, on your machine and at your discretion.
#
#  Almost all have an official arm64 build. Those already inside the image
#  (free software) are marked [already installed] and skipped.
#
#  Usage:
#    omarchy-arm-extras                    interactive menu
#    omarchy-arm-extras --list             see what it can install
#    omarchy-arm-extras 1password obsidian install specific items
#    omarchy-arm-extras --all              everything that is missing
#    omarchy-arm-extras --force <key>      reinstall even if already present
#
set -uo pipefail

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_hi=$'\033[1;36m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
title() { echo; echo "${c_hi}━━━ $* ━━━${c_off}"; }
info()  { echo "  $*"; }
ok()    { echo "  ${c_ok}✓${c_off} $*"; }
warn()  { echo "  ${c_warn}!${c_off} $*" >&2; }
fail()  { echo "  ${c_err}✗${c_off} $*" >&2; }

# /tmp is tmpfs and is limited by RAM: compiling .NET or OBS there runs
# out of space halfway. Work is done on real disk.
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-arm-extras"
OK_LIST=(); KO_LIST=()

# ── catalog ────────────────────────────────────────────────────────────────
#  key|title|description
CATALOG=(
  "1password|1Password|Password manager. Official arm64 tarball from AgileBits"
  "1password-cli|1Password CLI|The op command. Official static arm64 binary"
  "obsidian|Obsidian|Markdown notes. Official arm64 AppImage"
  "typora|Typora|WYSIWYG markdown editor. Official arm64 package via AUR"
  "localsend|LocalSend|Send files between devices. Official arm64 build"
  "chrome|Google Chrome|Includes Widevine for arm64: enables Spotify and Netflix web"
  "spotify-web|Spotify (webapp)|Launcher for open.spotify.com + rebinds SUPER+SHIFT+M"
  "pinta|Pinta|Image editor. Built with Microsoft's arm64 .NET"
  "obs|OBS Studio|Capture and streaming. Built without the browser plugin"
)

catalog_keys()  { printf '%s\n' "${CATALOG[@]}" | cut -d'|' -f1; }
catalog_title() { printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" '$1==k{print $2}'; }
catalog_desc()  { printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" '$1==k{print $3}'; }

# ── utilities ──────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# Pinta and OBS Studio are free software and travel inside the image; the rest
# do not. Without this check, `--all` would recompile all of OBS (half an hour)
# to reinstall what is already there.
is_installed() {
  case "$1" in
    1password)     pacman -Q 1password        >/dev/null 2>&1 || [ -d /opt/1Password ] ;;
    1password-cli) have op ;;
    obsidian)      [ -d /opt/obsidian ] ;;
    typora)        pacman -Q typora           >/dev/null 2>&1 ;;
    localsend)     pacman -Q localsend-bin    >/dev/null 2>&1 ;;
    chrome)        pacman -Q google-chrome    >/dev/null 2>&1 || have google-chrome-stable ;;
    spotify-web)   grep -q "open.spotify.com" "$HOME/.config/hypr/bindings.lua" 2>/dev/null ;;
    pinta)         pacman -Q pinta            >/dev/null 2>&1 ;;
    obs)           pacman -Q obs-studio       >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

need_sudo() {
  sudo -n true 2>/dev/null && return 0
  info "sudo is needed to install packages."
  sudo -v || { fail "no privileges"; return 1; }
}

# Builds an AUR package, handling the usual ARM traps:
#  · the clone URL uses the PackageBase, which is not always the name
#  · many PKGBUILDs declare arch=(x86_64) by default, not because of incompatibility
#  · a PKGBUILD can generate several subpackages and only one have the broken dependency
aur_build() {
  # A single `local` expands ALL values before assigning any, so
  # $pkg would not exist when constructing $dir and with set -u the script aborts.
  local pkg="$1" want="${2:-$1}"
  local dir="$WORK/$pkg" base
  pacman -Q "$want" >/dev/null 2>&1 && { ok "$want already installed"; return 0; }

  base=$(curl -fsSL --max-time 20 "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" \
         | sed -n 's/.*"PackageBase":"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$base" ] || base="$pkg"

  rm -rf "$dir"; mkdir -p "$WORK"
  git clone -q "https://aur.archlinux.org/$base.git" "$dir" 2>/dev/null
  [ -f "$dir/PKGBUILD" ] || { fail "could not clone $pkg (base: $base)"; return 1; }

  # Several PKGBUILDs verify the upstream signature in check(). If the key is not
  # in the keyring, makepkg aborts. The keys the PKGBUILD itself
  # declares are imported, instead of skipping verification.
  local keys k
  keys=$(sed -n '/^validpgpkeys=(/,/)/p' "$dir/PKGBUILD" | grep -oE '[0-9A-Fa-f]{40}')
  for k in $keys; do
    [ ${#k} -ge 16 ] || continue
    gpg --list-keys "$k" >/dev/null 2>&1 && continue
    info "importing GPG key ${k: -8}"
    gpg --keyserver keyserver.ubuntu.com --recv-keys "$k" >/dev/null 2>&1 \
      || gpg --keyserver keys.openpgp.org --recv-keys "$k" >/dev/null 2>&1 \
      || warn "could not import ${k: -8}: signature verification will fail"
  done

  if ! grep -qE "^arch=\(.*\b(aarch64|any)\b" "$dir/PKGBUILD"; then
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
    info "arch= patched to include aarch64"
  fi

  ( cd "$dir" && makepkg -si --noconfirm --needed --noprogressbar ) >"$dir/build.log" 2>&1 && return 0
  fail "compilation of $pkg failed — log: $dir/build.log"
  tail -5 "$dir/build.log" | sed 's/^/      /'
  return 1
}

# ── installers ────────────────────────────────────────────────────────────

do_1password() {
  title "1Password"
  info "AgileBits publishes arm64 ONLY as a tarball: there is no .deb or .rpm for this architecture."
  local url=https://downloads.1password.com/linux/tar/stable/aarch64/1password-latest.tar.gz
  mkdir -p "$WORK"; rm -rf "$WORK/1p"; mkdir -p "$WORK/1p"
  curl -fL --progress-bar "$url" -o "$WORK/1p/1p.tar.gz" || { fail "download failed"; return 1; }
  # It is a password manager: the signature is verified before installing it.
  local KEY=3FEF9748469ADBE15DA7CA80AC2D62742012EA22
  if curl -fsSL "$url.sig" -o "$WORK/1p/1p.tar.gz.sig" 2>/dev/null; then
    gpg --list-keys "$KEY" >/dev/null 2>&1 \
      || gpg --keyserver keyserver.ubuntu.com --recv-keys "$KEY" >/dev/null 2>&1 \
      || gpg --keyserver keys.openpgp.org --recv-keys "$KEY" >/dev/null 2>&1
    if gpg --verify "$WORK/1p/1p.tar.gz.sig" "$WORK/1p/1p.tar.gz" >/dev/null 2>&1; then
      ok "AgileBits GPG signature verified"
    else
      fail "THE SIGNATURE DOES NOT VERIFY — install is aborted"; return 1
    fi
  else
    warn "no .sig available; installing without verifying the signature"
  fi
  tar -xzf "$WORK/1p/1p.tar.gz" -C "$WORK/1p" || { fail "could not extract"; return 1; }
  local src; src=$(find "$WORK/1p" -maxdepth 1 -type d -name '1password-*' | head -1)
  [ -n "$src" ] || { fail "the tarball does not have the expected shape"; return 1; }
  sudo mkdir -p /opt/1Password
  sudo cp -a "$src"/. /opt/1Password/
  ( cd /opt/1Password && sudo ./after-install.sh ) >/dev/null 2>&1 || warn "after-install.sh reported errors (usually harmless)"
  have 1password && ok "$(1password --version 2>/dev/null | head -1 || echo installed)" || { fail "did not end up in PATH"; return 1; }
  info "${c_dim}On Hyprland it is best launched with --ozone-platform=wayland${c_off}"
}

do_1password_cli() { title "1Password CLI"; aur_build 1password-cli && ok "$(op --version 2>/dev/null)"; }

do_obsidian() {
  title "Obsidian"
  info "There are official AppImage and arm64 tarball. The tarball is used: it does not depend on fuse2."
  # NOTE: releases/latest can be an Android-ONLY release (a lone .apk).
  # We have to look for the latest one that actually publishes the desktop arm64 tarball.
  local url
  url=$(curl -fsSL --max-time 30 "https://api.github.com/repos/obsidianmd/obsidian-releases/releases?per_page=15" \
        | grep -oE '"browser_download_url": *"[^"]*obsidian-[0-9.]+-arm64\.tar\.gz"' \
        | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
  [ -n "$url" ] || { fail "found no arm64 tarball in the latest releases"; return 1; }
  info "$(basename "$url")"
  mkdir -p "$WORK"; curl -fL --progress-bar "$url" -o "$WORK/obsidian.tar.gz" || { fail "download failed"; return 1; }
  sudo rm -rf /opt/obsidian; sudo mkdir -p /opt/obsidian
  sudo tar -xzf "$WORK/obsidian.tar.gz" -C /opt/obsidian --strip-components=1 || { fail "could not extract"; return 1; }
  sudo ln -sfn /opt/obsidian/obsidian /usr/local/bin/obsidian
  sudo install -Dm644 /dev/stdin /usr/local/share/applications/obsidian.desktop <<'DESK'
[Desktop Entry]
Name=Obsidian
Exec=obsidian --ozone-platform-hint=auto %u
Icon=obsidian
Type=Application
Categories=Office;
MimeType=x-scheme-handler/obsidian;
DESK
  [ -f /opt/obsidian/resources/app.asar ] && sudo find /opt/obsidian -name 'icon.png' -exec \
    sudo install -Dm644 {} /usr/local/share/icons/hicolor/512x512/apps/obsidian.png \; 2>/dev/null
  ok "Obsidian installed in /opt/obsidian ($(basename "$url"))"
}

do_typora() {
  title "Typora"
  info "The AUR package 'typora' downloads the official arm64 .deb. Do not use typora-electron: it wants electron42, which does not exist on ARM."
  aur_build typora && ok "$(pacman -Q typora)"
}

do_localsend() { title "LocalSend"; aur_build localsend-bin localsend-bin && ok "$(pacman -Q localsend-bin)"; }

do_chrome() {
  title "Google Chrome"
  info "Chrome arm64 includes Widevine (the DRM that Spotify and Netflix web require)."
  info "Repo Chromium does NOT ship it, and the chromium-widevine package is x86_64 only."
  aur_build google-chrome || return 1
  ok "$(pacman -Q google-chrome)"
  info "${c_dim}Check DRM at chrome://components → 'Widevine Content Decryption Module'${c_off}"
}

do_spotify_web() {
  title "Spotify (webapp)"
  # Omarchy treats Spotify as a native package, not a webapp — and that package is
  # x86_64. On ARM the path that works is the web, which needs Widevine.
  if ! have google-chrome-stable; then
    warn "without Google Chrome the Spotify web will not play: install 'chrome' first"
  fi
  if have omarchy-webapp-install; then
    omarchy-webapp-install "Spotify" "https://open.spotify.com" \
      "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/spotify.png" \
      "$(have google-chrome-stable && echo 'google-chrome-stable --app=https://open.spotify.com')" \
      >/dev/null 2>&1 && ok "launcher created in the applications menu"
  else
    warn "omarchy-webapp-install is not available"
  fi
  # Rebind SUPER+SHIFT+M, which in Omarchy points at the native binary
  local f="$HOME/.config/hypr/bindings.lua"
  if [ -f "$f" ] && ! grep -q "open.spotify.com" "$f"; then
    cat >> "$f" <<'LUA'

-- Spotify has no native client for aarch64: SUPER+SHIFT+M opens the webapp.
-- Needs Google Chrome, which is what ships Widevine on arm64.
o.bind("SUPER + SHIFT + M", "Spotify", o.launch("google-chrome-stable --app=https://open.spotify.com"))
LUA
    ok "SUPER+SHIFT+M rebound (restart the session to apply it)"
  fi
  info "${c_dim}Terminal alternative, already installed: spotify-player${c_off}"
}

do_pinta() {
  title "Pinta"
  info "Microsoft does publish .NET for linux-arm64; Arch only packages it for x86_64."
  info "The runtime is installed from the official tarball and then the Pinta package, which is arch=any."
  aur_build dotnet-runtime-bin dotnet-runtime-bin || { fail "cannot continue without a .NET runtime"; return 1; }
  local url=https://geo.mirror.pkgbuild.com/extra/os/x86_64/
  local file; file=$(curl -fsSL --max-time 30 "$url" | grep -o 'pinta-[0-9][^"]*-any\.pkg\.tar\.zst' | sort -V | tail -1)
  [ -n "$file" ] || { fail "could not find the Pinta package"; return 1; }
  info "$file  ${c_dim}(the path says x86_64 but the package is arch=any)${c_off}"
  mkdir -p "$WORK"; curl -fL --progress-bar "$url$file" -o "$WORK/$file" || return 1
  sudo pacman -U --noconfirm "$WORK/$file" >/dev/null 2>&1 && ok "$(pacman -Q pinta)" || { fail "pacman -U failed"; return 1; }
  warn "it stays outside the update manager: each version has to be repeated by hand"
}

do_obs() {
  title "OBS Studio"
  info "OBS compiles fine on aarch64. The only thing blocking it on Arch Linux ARM is the"
  info "browser subpackage, whose 'cef' only exists for x86_64. It is disabled."
  warn "compiling Qt6 + OBS inside the VM takes a while"
  local dir="$WORK/obs-studio"
  rm -rf "$dir"; mkdir -p "$WORK"
  git clone -q --depth 1 https://gitlab.archlinux.org/archlinux/packaging/packages/obs-studio.git "$dir" \
    || { fail "could not clone Arch's PKGBUILD"; return 1; }
  cd "$dir" || return 1
  sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" PKGBUILD
  # NOTE: 'cef' is on the SAME line as makedepends=, not on its own, so
  # it has to be removed as a token and not as a whole line.
  sed -i "s/'cef'[[:space:]]*//g" PKGBUILD
  sed -i "/cef_api_versions\.h/d; /-DCEF_API_VERSION/d; /_cef_api_version/d" PKGBUILD
  sed -i 's/-DENABLE_BROWSER=ON/-DENABLE_BROWSER=OFF/' PKGBUILD
  # package_obs-studio() sets aside the browser plugin files for the
  # separate subpackage. Without browser those files do not exist and the `mv` aborts
  # packaging AFTER compiling everything: those two lines have to be removed.
  sed -i '/mv \$pkgdir\/usr\/lib\/obs-plugins\/{obs-browser-page,obs-browser.so}/d' PKGBUILD
  sed -i '/mv \$pkgdir\/usr\/share\/obs\/obs-plugins\/obs-browser /d' PKGBUILD
  # and the plugin patches, which no longer apply to anything
  sed -i '/patch -d plugins\/obs-browser/d' PKGBUILD
  # source=() and sha256sums=() are NOT touched: deleting entries from one without the other
  # makes makepkg abort with "Integrity checks differ in size from the source
  # array". Downloading extra obs-browser is just bandwidth.
  sed -i '/INSTALL_RPATH.*cef/d' PKGBUILD
  # The browser subpackage is no longer generated
  sed -i '/^package_obs-studio-plugin-browser()/,/^}/d' PKGBUILD
  sed -i "s/^pkgname=(.*)/pkgname=('obs-studio')/" PKGBUILD
  info "PKGBUILD patched: aarch64, no CEF, no browser plugin"
  if makepkg -si --noconfirm --needed --noprogressbar >"$dir/build.log" 2>&1; then
    ok "$(pacman -Q obs-studio)"
    info "${c_dim}No hardware acceleration in the VM: it will encode with x264 on CPU${c_off}"
  else
    fail "compilation failed — log: $dir/build.log"
    tail -6 "$dir/build.log" | sed 's/^/      /'
    return 1
  fi
}

run_item() {
  local k="$1"
  if [ "${FORCE:-0}" != "1" ] && is_installed "$k"; then
    title "$(catalog_title "$k")"
    ok "already shipped in this image (--force to reinstall)"
    return 0
  fi
  case "$k" in
    1password)     do_1password ;;
    1password-cli) do_1password_cli ;;
    obsidian)      do_obsidian ;;
    typora)        do_typora ;;
    localsend)     do_localsend ;;
    chrome)        do_chrome ;;
    spotify-web)   do_spotify_web ;;
    pinta)         do_pinta ;;
    obs)           do_obs ;;
    *) fail "I do not know '$k'"; return 1 ;;
  esac
}

show_list() {
  echo
  echo "${c_hi}Apps installed from their official source${c_off}"
  echo "${c_dim}Proprietary ones are not shipped inside on purpose: redistributing their binaries"
  echo "in an image that is distributed would be problematic. Here they are downloaded on your"
  echo "machine, from the vendor's site.${c_off}"
  echo
  local k
  while read -r k; do
    if is_installed "$k"; then
      printf "  ${c_hi}%-15s${c_off} %s ${c_dim}[already installed]${c_off}\n" "$k" "$(catalog_desc "$k")"
    else
      printf "  ${c_hi}%-15s${c_off} %s\n" "$k" "$(catalog_desc "$k")"
    fi
  done < <(catalog_keys)
  echo
  echo "${c_dim}Usage: omarchy-arm-extras <key> [key...]   ·   --all for everything${c_off}"
  echo
}

# ── main ────────────────────────────────────────────────────────────────────
SELECTED=()
FORCE=0
if [ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ]; then FORCE=1; shift; fi
case "${1:-}" in
  --list|-l) show_list; exit 0 ;;
  --all|-a)  mapfile -t SELECTED < <(catalog_keys) ;;
  -h|--help) sed -n '3,20p' "$0" | sed 's/^#\{0,2\} \{0,1\}//'; exit 0 ;;
  "")
    if have gum; then
      show_list
      mapfile -t SELECTED < <(
        while read -r k; do printf '%s — %s\n' "$k" "$(catalog_title "$k")"; done < <(catalog_keys) \
        | gum choose --no-limit --header "Select what to install (space to mark, enter to confirm)" \
        | cut -d' ' -f1
      )
    else
      show_list; exit 0
    fi ;;
  *) SELECTED=("$@") ;;
esac

[ ${#SELECTED[@]} -gt 0 ] || { info "nothing selected"; exit 0; }

need_sudo || exit 1
mkdir -p "$WORK"

for k in "${SELECTED[@]}"; do
  [ -z "$k" ] && continue
  if run_item "$k"; then OK_LIST+=("$k"); else KO_LIST+=("$k"); fi
done

title "Summary"
[ ${#OK_LIST[@]} -gt 0 ] && ok "installed: ${OK_LIST[*]}"
if [ ${#KO_LIST[@]} -gt 0 ]; then
  fail "failed: ${KO_LIST[*]}"
  # The work directory is not deleted: the build.log files are inside it, and they are
  # the only way to find out why it failed.
  info "logs in $WORK/<package>/build.log"
else
  rm -rf "$WORK"
fi
echo
