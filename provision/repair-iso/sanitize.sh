#!/bin/bash
# Sanitize for distribution: strips everything identifying from the system and leaves
# a generic user. Runs as ROOT inside the chroot.
set -uo pipefail
OLD="${DIST_OLD_USER:-gabriel}"
NEW="${DIST_NEW_USER:-omarchy}"
log()  { echo ""; echo "==> $*"; }
warn() { echo "!!  $*" >&2; }

log "1/10 unanchoring /usr/share/omarchy from the user's home"
# It was a symlink to /home/gabriel/.local/share/omarchy, which ties the system to
# that user. It is turned into a real directory (as the pacman package would) and
# the home then points there.
if [ -L /usr/share/omarchy ]; then
  TARGET=$(readlink -f /usr/share/omarchy)
  rm -f /usr/share/omarchy
  cp -a "$TARGET" /usr/share/omarchy
  chown -R root:root /usr/share/omarchy
  rm -rf "$TARGET"
  echo "  /usr/share/omarchy is now a real directory ($(du -sh /usr/share/omarchy | cut -f1))"
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

log "7/10 system logs and caches"
rm -rf /var/log/journal/* /var/log/omarchy* /var/log/pacman.log
find /var/log -type f -name "*.log" -delete 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* /var/tmp/* /tmp/* 2>/dev/null || true
rm -rf /root/prov /root/.bash_history /root/.cache 2>/dev/null || true

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
cp /etc/motd "/home/$NEW/Desktop/LEEME.txt"
chown "$NEW:$NEW" "/home/$NEW/Desktop/LEEME.txt"

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
echo "  /usr/share/omarchy (must not point at /home):"; ls -ld /usr/share/omarchy

log "system consistency"
echo "  passwd: $(getent passwd $NEW)"
echo "  home:   $(ls -ld /home/$NEW | awk '{print $3, $4, $9}')"
echo "  omarchy symlink: $(readlink /home/$NEW/.local/share/omarchy)"
echo "  autologin: $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | tr '\n' ' ')"
echo "  omarchy binaries: $(ls /usr/local/bin | wc -l)"
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
mapfile -t BADLINKS < <(find /home/$NEW /etc /usr/local /opt -xdev -type l \
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
echo "  links to /home/$OLD: $(find /home/$NEW /etc /usr/local /opt -xdev -type l -lname "*/home/$OLD/*" 2>/dev/null | wc -l)"
echo "  broken links in home: $(find /home/$NEW -xdev -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l)"
echo "  active wallpaper: $(readlink -f /home/$NEW/.local/state/omarchy/current/background 2>/dev/null || echo NONE)"
test -e "/home/$NEW/.local/state/omarchy/current/background" \
  && echo "  wallpaper resolves: OK" || echo "  wallpaper resolves: BROKEN"
echo "  (note: /usr/local/bin/ttfx contains the compilation path in its"
echo "   debug info; it is harmless and does not expose anything useful)"

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
echo ""
echo ""
echo "==> SANITIZE_OK"
