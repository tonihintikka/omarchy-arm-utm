#!/bin/bash
# 16 · The grey desktop
#
# Symptom: the already sanitised image booted with a flat grey wallpaper and
# notifications as grey boxes with no style. No error in journalctl.
#
# Two independent causes, neither visible with the checks I was doing:
#
#  a) `grep -rl gabriel` returned 0 matches because grep reads CONTENT, and a
#     symlink's target is not that. 439 links remained pointing at the old
#     home, including the 431 omarchy-* commands in /usr/local/bin and the
#     active wallpaper (~/.local/state/omarchy/current/background).
#
#  b) I had mako, swayosd, walker and elephant installed. Omarchy 4 retires them
#     (bin/omarchy-upgrade-to-quattro uninstalls them) because quickshell does
#     that work. mako activates over D-Bus and steals the
#     org.freedesktop.Notifications name from the shell.
#
# Fixed at the source: provision/src/sanitize.sh rewrites the symlinks and
# verifies that the wallpaper resolves; stage3.sh no longer installs those four packages.
set -uo pipefail
NEW=omarchy; OLD=gabriel

echo "==> a) symlinks that point at the old home"
mapfile -t BAD < <(find /home/$NEW /etc /usr/local /opt -xdev -type l -lname "*/home/$OLD/*" 2>/dev/null)
echo "  found: ${#BAD[@]}"
for l in "${BAD[@]:-}"; do
  [ -n "$l" ] || continue
  t=$(readlink "$l"); ln -sfn "${t//\/home\/$OLD\//\/home\/$NEW\/}" "$l"
done
echo "  remaining: $(find /home/$NEW /etc /usr/local /opt -xdev -type l -lname "*/home/$OLD/*" 2>/dev/null | wc -l)"
echo "  wallpaper: $(readlink -f /home/$NEW/.local/state/omarchy/current/background)"

echo "==> b) packages that Omarchy 4 retires"
pacman -Rns --noconfirm mako swayosd walker elephant 2>&1 | tail -3
rm -rf /home/$NEW/.config/mako /home/$NEW/.config/walker /home/$NEW/.config/swayosd
rm -f  /usr/local/bin/walker
O=$(pacman -Qtdq 2>/dev/null | tr '\n' ' '); [ -n "${O// /}" ] && pacman -Rns --noconfirm $O >/dev/null 2>&1

echo "==> verification"
echo "  broken links: $(find /home/$NEW /usr/local/bin -xdev -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l)"
echo "  retired still present: $(for p in mako swayosd walker elephant; do pacman -Q $p >/dev/null 2>&1 && echo -n "$p "; done; echo -n none)"
sync
