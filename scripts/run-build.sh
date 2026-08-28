#!/bin/bash
set -e
# The root is deduced from this script's location, so the repo can be
# cloned anywhere without editing anything.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

echo "=== preparing provisioning ISO ==="
rm -rf provision/iso && mkdir -p provision/iso
cp provision/src/stage1.sh provision/src/stage2.sh provision/src/stage3.sh \
   provision/src/config.env provision/src/packages-core.txt provision/src/packages-extra.txt \
   provision/iso/
# short name so we don't depend on ISO9660 extensions
ln dl/ArchLinuxARM-aarch64-latest.tar.gz provision/iso/alarm-rootfs.tgz 2>/dev/null \
  || cp dl/ArchLinuxARM-aarch64-latest.tar.gz provision/iso/alarm-rootfs.tgz
rm -f provision/provision.iso
hdiutil makehybrid -iso -joliet -default-volume-name PROVISION \
  -o provision/provision.iso provision/iso/ >/dev/null
ls -lh provision/provision.iso

echo "=== clean destination disk ==="
rm -f vm/omarchy-arm.qcow2 vm/efi-vars.fd
qemu-img create -f qcow2 vm/omarchy-arm.qcow2 80G >/dev/null
dd if=/dev/zero of=vm/efi-vars.fd bs=1m count=64 status=none

echo "=== $(date '+%F %T') building Arch Linux ARM + Hyprland + Omarchy ==="
exec expect -f scripts/build.exp
