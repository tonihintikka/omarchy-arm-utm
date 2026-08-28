#!/bin/bash
# Stage 2 — inside the Arch Linux ARM chroot, as root.
# Base system, kernel, UEFI boot, Omarchy stack packages, and login.
set -euo pipefail
. /root/prov/config.env
. /root/prov/fsinfo.env
export LANG=C LC_ALL=C

log()  { echo ""; echo "==> [stage2] $*"; }
warn() { echo "!!  [stage2] $*"; }

trap 'warn "failed on line $LINENO"; exit 1' ERR

# ---------------------------------------------------------------- pacman
log "initializing the Arch Linux ARM keyring"
pacman-key --init
pacman-key --populate archlinuxarm

# A one-hour build cannot die because the mirror stalls for ten seconds.
# Real case: "failed retrieving file noto-fonts-...: Operation too
# slow. Less than 1 bytes/sec transferred the last 10 seconds" -> the bulk
# install collapsed, the one-by-one retry left pipewire-jack out, and the stage
# aborted via its ERR trap, with 40 minutes already spent.
#
# --disable-download-timeout removes that minimum-speed limit, which is what
# aborted it. And a second Server is added: ALARM's mirrorlist only has the
# geo-balancer, so if the node you get is bad there is nowhere to fall back.
# An extra mirror is not a risk: pacman verifies every package signature
# against the archlinuxarm keyring.
if ! grep -q 'de.mirror.archlinuxarm.org' /etc/pacman.d/mirrorlist 2>/dev/null; then
  echo 'Server = http://de.mirror.archlinuxarm.org/$arch/$repo' >> /etc/pacman.d/mirrorlist
fi
# DisableDownloadTimeout in pacman.conf, not as a one-off flag: that way
# ALL invocations inherit it, including the one makepkg -s makes internally
# to resolve build dependencies.
grep -q '^DisableDownloadTimeout' /etc/pacman.conf \
  || sed -i 's/^\[options\]/[options]\nDisableDownloadTimeout\nParallelDownloads = 5/' /etc/pacman.conf

# Retry wrapper: the mirror fails in bursts, not steadily.
pac() {
  local intento
  for intento in 1 2 3; do
    if pacman -S --noconfirm --needed --disable-download-timeout "$@"; then return 0; fi
    warn "pacman failed (attempt $intento/3); retrying in ${intento}0 s"
    sleep "${intento}0"
    pacman -Sy --noconfirm --disable-download-timeout >/dev/null 2>&1 || true
  done
  return 1
}

log "updating the system (the tarball is from August, the repos are current)"
pacman -Syu --noconfirm --needed --disable-download-timeout \
  || pacman -Syu --noconfirm --needed --disable-download-timeout

log "base system"
# linux-firmware is omitted on purpose: ~800 MB useless in a VM
pac base base-devel linux-aarch64 \
  sudo git vim networkmanager openssh which man-db man-pages less \
  btrfs-progs dosfstools e2fsprogs efibootmgr \
  rsync wget curl unzip zip

# ---------------------------------------------------------------- localization
log "timezone, locales, keyboard, hostname"
ln -sf "/usr/share/zoneinfo/$VM_TIMEZONE" /etc/localtime
sed -i "s/^#\(${VM_LOCALE} \)/\1/; s/^#\(${VM_LOCALE_EXTRA} \)/\1/" /etc/locale.gen
grep -q "^${VM_LOCALE} " /etc/locale.gen || echo "${VM_LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$VM_LOCALE" > /etc/locale.conf
# Hyprland reads XKBLAYOUT from here (default/hypr/input.lua); KEYMAP only
# covers the text console.
printf 'KEYMAP=%s\nXKBLAYOUT=%s\n' "$VM_KEYMAP" "$VM_XKB" > /etc/vconsole.conf
echo "$VM_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $VM_HOSTNAME.localdomain $VM_HOSTNAME
EOF
systemd-machine-id-setup || true

# ---------------------------------------------------------------- fstab
log "fstab"
if [ "$ROOTFS" = btrfs ]; then
cat > /etc/fstab <<EOF
LABEL=OMROOT  /      btrfs  rw,noatime,compress=zstd:3,subvol=@         0 0
LABEL=OMROOT  /home  btrfs  rw,noatime,compress=zstd:3,subvol=@home     0 0
LABEL=OMBOOT  /boot  vfat   rw,noatime,fmask=0137,dmask=0027,utf8=true  0 2
EOF
KERNEL_ROOTFLAGS="rootflags=subvol=@"
else
cat > /etc/fstab <<EOF
LABEL=OMROOT  /      ext4   rw,noatime                                  0 1
LABEL=OMBOOT  /boot  vfat   rw,noatime,fmask=0137,dmask=0027,utf8=true  0 2
EOF
KERNEL_ROOTFLAGS=""
fi
cat /etc/fstab

# ---------------------------------------------------------------- user
log "user $VM_USER"
userdel -r alarm 2>/dev/null || true
if ! id -u "$VM_USER" >/dev/null 2>&1; then
  useradd -m -G wheel,video,audio,input,storage,network,lp -s /bin/bash -c "$VM_FULLNAME" "$VM_USER"
fi
echo "$VM_USER:$VM_PASSWORD" | chpasswd
echo "root:$VM_PASSWORD"     | chpasswd
install -m 0440 /dev/stdin /etc/sudoers.d/10-wheel <<<'%wheel ALL=(ALL:ALL) ALL'
# passwordless only for the duration of the install; removed at the end
install -m 0440 /dev/stdin /etc/sudoers.d/99-install <<<"$VM_USER ALL=(ALL:ALL) NOPASSWD: ALL"

# ---------------------------------------------------------------- initramfs
log "mkinitcpio (virtio + btrfs modules)"
sed -i 's/^MODULES=.*/MODULES=(virtio virtio_pci virtio_blk virtio_scsi virtio_net virtio_gpu 9p 9pnet 9pnet_virtio btrfs ext4)/' /etc/mkinitcpio.conf
grep -q '^MODULES=' /etc/mkinitcpio.conf || echo 'MODULES=(virtio virtio_pci virtio_blk virtio_gpu 9p 9pnet_virtio btrfs)' >> /etc/mkinitcpio.conf
mkinitcpio -P
echo "  /boot:"; ls -la /boot

# ---------------------------------------------------------------- UEFI boot
log "systemd-boot on the ESP"
# --no-variables: we do not write NVRAM; UTM boots via the fallback path
# \EFI\BOOT\BOOTAA64.EFI, which bootctl installs anyway.
bootctl --esp-path=/boot --no-variables install

# The ESP is mounted empty AFTER extracting the rootfs, so /boot has no
# kernel. "pacman -S --needed" will not restore it if the installed version
# already matches the repository, so the package is force-reinstalled.
if [ ! -f /boot/Image ] && [ ! -f /boot/vmlinuz-linux-aarch64 ]; then
  echo "  /boot empty: reinstalling linux-aarch64 to repopulate it"
  pacman -S --noconfirm --disable-download-timeout linux-aarch64 || warn "could not reinstall the kernel"
  mkinitcpio -P || warn "mkinitcpio failed after reinstall"
fi

KERNEL_IMG=""
for c in /boot/Image /boot/vmlinuz-linux-aarch64 /boot/Image.gz; do
  [ -f "$c" ] && { KERNEL_IMG="/$(basename "$c")"; break; }
done
[ -n "$KERNEL_IMG" ] || { warn "cannot find the kernel image in /boot"; ls -la /boot; exit 1; }

INITRD=""
for c in /boot/initramfs-linux-aarch64.img /boot/initramfs-linux.img; do
  [ -f "$c" ] && { INITRD="/$(basename "$c")"; break; }
done
[ -n "$INITRD" ] || { warn "cannot find the initramfs"; ls -la /boot; exit 1; }

mkdir -p /boot/loader/entries
cat > /boot/loader/loader.conf <<EOF
default  omarchy.conf
timeout  1
console-mode keep
editor   no
EOF
cat > /boot/loader/entries/omarchy.conf <<EOF
title    Arch Linux ARM — Omarchy
linux    $KERNEL_IMG
initrd   $INITRD
options  root=LABEL=OMROOT $KERNEL_ROOTFLAGS rw quiet loglevel=3
EOF
cat > /boot/loader/entries/omarchy-verbose.conf <<EOF
title    Arch Linux ARM — Omarchy (verbose)
linux    $KERNEL_IMG
initrd   $INITRD
options  root=LABEL=OMROOT $KERNEL_ROOTFLAGS rw
EOF
echo "  kernel=$KERNEL_IMG initrd=$INITRD"
echo "  ESP:"; find /boot/EFI /boot/loader -maxdepth 3 | sort

# ---------------------------------------------------------------- network
log "network: NetworkManager (disabling systemd-networkd from the tarball)"
systemctl disable systemd-networkd.service systemd-networkd.socket 2>/dev/null || true
systemctl disable systemd-resolved.service 2>/dev/null || true
rm -f /etc/systemd/network/*.network 2>/dev/null || true
systemctl enable NetworkManager.service
systemctl enable systemd-timesyncd.service 2>/dev/null || true

# ---------------------------------------------------------------- desktop
log "installing the desktop stack (Hyprland + Omarchy tools)"
install_list() {
  local file="$1" label="$2" fatal="$3"
  mapfile -t PKGS < <(grep -vE '^\s*#|^\s*$' "$file")
  echo "  $label: ${#PKGS[@]} packages"
  if pac "${PKGS[@]}"; then return 0; fi
  warn "$label: bulk install failed after 3 attempts; trying one by one"
  local FAILED=()
  for p in "${PKGS[@]}"; do
    pacman -S --noconfirm --needed --disable-download-timeout "$p" >/dev/null 2>&1 && continue
    # Second pass for the one that failed: almost always the mirror, not the package.
    sleep 3
    pacman -S --noconfirm --needed --disable-download-timeout "$p" >/dev/null 2>&1 || FAILED+=("$p")
  done
  if [ ${#FAILED[@]} -gt 0 ]; then
    warn "$label not installed: ${FAILED[*]}"
    printf '%s\n' "${FAILED[@]}" >> /root/failed-packages.txt
    [ "$fatal" = fatal ] && return 1
  fi
  return 0
}
install_list /root/prov/packages-core.txt  "core" fatal
set +e
install_list /root/prov/packages-extra.txt "extras" soft
set -e

log "system services"
systemctl enable sddm.service 2>/dev/null || warn "sddm not available"
# UTM integration: utmctl ip-address/exec/file need the guest agent
systemctl enable qemu-guest-agent.service 2>/dev/null || true
# The Arch Linux ARM rootfs comes with sshd started, and here openssh is
# installed and the same trivial password is set on the user and root. A
# personal VM (without the sanitize phase, which was the only disable) would
# keep listening with omarchy/omarchy. It is off by default; whoever wants it:
#   sudo systemctl enable --now sshd
systemctl disable sshd.service 2>/dev/null || true
systemctl disable sshd.socket  2>/dev/null || true
# SPICE clipboard has THREE pieces, not two:
#   SPICE client (UTM) <-virtio port-> spice-vdagentd <-unix socket-> agent
# The daemon is who talks to the host; the session agent only talks to the
# daemon. That is why spice-vdagentd must stay alive even though its official
# (X11) agent is useless on Hyprland: what we replace is the agent, not the
# daemon.
#
# And -X is required: the "active seat0 session" check
# (vdagentd.c:746, systemd-login.c:272) fails with Hyprland launched by SDDM,
# and then the daemon silently drops the clipboard.
mkdir -p /etc/systemd/system/spice-vdagentd.service.d
cat > /etc/systemd/system/spice-vdagentd.service.d/override.conf <<'OVR'
[Service]
# -X: no logind integration. Without this the daemon cannot find "the active
# seat0 session" under Hyprland and drops the clipboard without warning.
ExecStart=
ExecStart=/usr/bin/spice-vdagentd -X -x -f
OVR
systemctl enable spice-vdagentd.service 2>/dev/null || true
systemctl enable spice-vdagentd.socket 2>/dev/null || true
echo "  spice-vdagentd with -X (required under Hyprland)"

# NO udev rule is installed for /dev/virtio-ports/com.redhat.spice.0.
# There used to be one, and it was wrong twice over: omarchy-arm-vdagent never
# opens that port — it talks over the unix socket /run/spice-vdagentd/spice-vdagent-sock,
# as stage3 itself explains — and the port is opened exclusively by the daemon.
# Giving the seat user an ACL with TAG+="uaccess" only let something steal it
# from the daemon and leave it without a channel ("Device or resource
# busy"), which is exactly the first dead end of this problem.
# MODE="0660" also did nothing: without GROUP= the group stays root.

# UTM's shared folder has TWO modes and the user chooses which:
#   VirtFS → 9p device with mount_tag "share"
#   SPICE WebDAV → virtio port org.spice-space.webdav.0, served by
#     spice-webdavd (phodav package) at http://localhost:9843/
# Both are prepared: each activates only if its device exists.
systemctl enable spice-webdavd.service 2>/dev/null || true
echo "  spice-webdavd enabled (UTM SPICE WebDAV mode)"

# UTM shared folder. The bundle declares DirectoryShareMode=VirtFS, but
# that only exposes the device: the guest has to mount it. The tag is
# "share" (UTM, Configuration/UTMQemuConfiguration+Arguments.swift:1234).
# nofail so a boot with no folder configured does not drop into emergency,
# and x-systemd.automount so we do not pay for the mount if it is unused.
mkdir -p /mnt/share
# The fstab entry only applies to VirtFS, and the user may have chosen
# SPICE WebDAV. Instead of locking one mode, omarchy-arm-share is installed,
# which detects which is active. The fstab entry is still left with nofail:
# if the 9p device exists, it is mounted on its own at boot.
if ! grep -q '^share ' /etc/fstab; then
  cat >> /etc/fstab <<'FSTAB'

# UTM shared folder in VirtFS mode. If you chose SPICE WebDAV, this
# line does nothing (nofail) and omarchy-arm-share mounts it.
share  /mnt/share  9p  trans=virtio,version=9p2000.L,rw,nofail,x-systemd.automount,_netdev,msize=512000  0  0
FSTAB
fi
echo "  /mnt/share prepared (VirtFS via fstab, WebDAV with omarchy-arm-share)"
systemctl enable bluetooth.service 2>/dev/null || true
systemctl enable docker.service 2>/dev/null || true
usermod -aG docker "$VM_USER" 2>/dev/null || true

# ---------------------------------------------------------------- dotfiles
log "stage 3: Omarchy dotfiles as $VM_USER"
chmod +x /root/prov/stage3.sh
install -d -o "$VM_USER" -g "$VM_USER" "/home/$VM_USER"
# stage3 runs as a normal user and /root is 0750: any probe of /root/prov
# looks false without raising an error. A readable copy is left in their home.
PROVDIR="/home/$VM_USER/.omarchy-arm-prov"
mkdir -p "$PROVDIR"
for f in omarchy-arm-extras 10-arm-sync omarchy-arm-clipboard omarchy-arm-vdagent omarchy-arm-share; do
  [ -f "/root/prov/$f" ] && install -m 0644 "/root/prov/$f" "$PROVDIR/$f"
done
cp /root/prov/stage3.sh /root/prov/config.env "/home/$VM_USER/"
chown -R "$VM_USER:$VM_USER" "$PROVDIR"
chown "$VM_USER:$VM_USER" "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
echo "  available for stage3: $(ls "$PROVDIR" | tr '\n' ' ')"
# stage3's result has to reach the host: previously it was downgraded to a
# warn and stage2 still emitted its success token, so a stage3 that failed
# entirely produced a disk with not a single Omarchy dotfile declared OK.
# NOTE: with `set -e` + trap ERR, writing `su ...; RC=$?` does NOT work: if su
# returns != 0 the trap fires and the stage dies BEFORE the assignment, so
# the TOK_STAGE3_<rc> token was only emitted in the 0 case and the host never
# got to see the specific stage3 failure. With `|| RC=$?` the command is in
# a tested context and set -e does not intervene.
STAGE3_RC=0
su - "$VM_USER" -c "bash ~/stage3.sh" || STAGE3_RC=$?
[ $STAGE3_RC -eq 0 ] || warn "stage3 finished with errors (rc=$STAGE3_RC)"
echo "TOK_STAGE3_$STAGE3_RC"
rm -f "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
rm -rf "$PROVDIR"

# ---------------------------------------------------------------- SDDM login
log "SDDM: Omarchy session with autologin"
OM="/home/$VM_USER/.local/share/omarchy"
mkdir -p /usr/local/share/wayland-sessions /etc/sddm.conf.d /usr/share/sddm
if [ -f "$OM/default/wayland-sessions/omarchy.desktop" ]; then
  cp "$OM/default/wayland-sessions/omarchy.desktop" /usr/local/share/wayland-sessions/omarchy.desktop
  SESSION=omarchy
else
  SESSION=hyprland-uwsm
fi
[ -f "$OM/default/sddm/hyprland.conf" ] && cp "$OM/default/sddm/hyprland.conf" /usr/share/sddm/hyprland.conf
cat > /etc/sddm.conf.d/10-wayland.conf <<EOF
[General]
DisplayServer=wayland
EOF
cat > /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$VM_USER
Session=$SESSION
EOF
sed -i '/-auth.*pam_gnome_keyring\.so/d;/-password.*pam_gnome_keyring\.so/d' /etc/pam.d/sddm 2>/dev/null || true
echo "  session=$SESSION"
ls /usr/local/share/wayland-sessions /usr/share/wayland-sessions 2>/dev/null

# ---------------------------------------------------------------- VM tweaks
log "virtual-machine-specific tweaks"
# The hardware cursor and DRM modifiers cause problems on virtio-gpu
mkdir -p /etc/environment.d
cat > /etc/environment.d/90-vm-graphics.conf <<'EOF'
# virtio-gpu (virgl) under UTM/QEMU
WLR_NO_HARDWARE_CURSORS=1
AQ_NO_MODIFIERS=1
WLR_RENDERER_ALLOW_SOFTWARE=1
# Without this, GPU client windows (alacritty, chromium) are mapped but
# NOT painted: virgl does not deliver buffers Hyprland can compose. Only
# clients that use wl_shm (foot) render. With llvmpipe they all work.
# Confirmed that these do NOT fix it: AQ_NO_MODIFIERS, render:cm_enabled=false,
# render:explicit_sync (removed in Hyprland 0.56).
LIBGL_ALWAYS_SOFTWARE=1
EOF
# serial console useful for debugging from the host
systemctl enable serial-getty@ttyAMA0.service 2>/dev/null || true

log "cleanup"
rm -f /etc/sudoers.d/99-install
paccache -rk1 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true

log "summary"
echo "  kernel:    $(pacman -Q linux-aarch64 2>/dev/null || echo '?')"
echo "  hyprland:  $(pacman -Q hyprland 2>/dev/null || echo 'NOT INSTALLED')"
echo "  sddm:      $(pacman -Q sddm 2>/dev/null || echo 'NOT INSTALLED')"
echo "  mesa:      $(pacman -Q mesa 2>/dev/null || echo '?')"
echo "  user:      $(id "$VM_USER")"
echo "  dotfiles:  $(ls -d /home/$VM_USER/.config/hypr 2>/dev/null || echo 'MISSING')"
sync
touch /root/STAGE2_OK
echo ""
echo "==> [stage2] COMPLETED"
