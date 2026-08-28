#!/bin/bash
# 17 · The 37 defects the builder audit found
#
# This is not a script that is run: it is the record of what was corrected in
# build-omarchy-arm.sh and in provision/src/* after auditing it against its
# own sources of truth (the previous 16 fixes and the findings of the
# article), with an independent refuter per finding.
#
# BLOCKERS
#  1. sanitize.sh deleted /root/prov in step 7 and read it in steps 8a/8b:
#     the image shipped without the post-update hook or omarchy-arm-extras, in
#     silence. The deletion is now done by repair.sh on leaving the chroot.
#  2. stage3 runs as a user and /root is 0750: its [ -f /root/prov/... ] guards
#     returned false without error. stage2 leaves a copy in ~/.omarchy-arm-prov.
#  3. DIST_OLD_USER/DIST_NEW_USER were exported on the host and never crossed
#     into the guest: sanitising always renamed the literal "gabriel". Now
#     they travel in config.env and sanitize aborts if the user does not exist.
#  4. A total failure of stage3 was degraded to warn and the build declared
#     itself correct. stage2 emits TOK_STAGE3_<rc> and ph_build checks it.
#  5. The distributable bundle's config.plist advertised "User: gabriel /
#     gabriel": false and a leak. Parameterised, with a check in ph_package.
#  6. ph_utm deleted without asking any UTM VM of the same name.
#  7. make-utm.sh killed the entire UTM application, with the user's VMs inside.
#  8. ALPINE_ISO pinned to 3.24.1, which Alpine withdraws from the CDN when
#     publishing the next patch. Now the latest is resolved and its sha256 verified.
#  9. OMARCHY_REF=quattro with no fallback: if the branch disappears, prepare dies without
#     explaining why. Now it falls back to the default branch with a warning.
#
# SERIOUS (selection)
#  · ph_verify collected metrics and never compared them: it could not fail.
#  · ph_utm swallowed make-utm.sh's error with "| tail -4".
#  · ph_fetch announced "MD5 verified" even if the checksum curl failed.
#  · ph_package did not use -c: it did not reproduce the compressed image that was distributed.
#  · write_readme() generated a 17-line README with two false claims.
#    dist/LEEME.md is now embedded as-is.
#  · The compile loop had lost makepkg's -s: without build
#    dependencies, most PKGBUILDs fail at the first step.
#  · Fix 15 (thinning) was not folded in anywhere.
#  · ph_build destroyed the previous disk (40 min of work) without warning.
#
# MINOR (selection)
#  · The $TERMINAL fallback pointed at alacritty, which quattro does not install (foot).
#  · spice-vdagentd was never enabled: no shared clipboard.
#  · Four steps from fix 01 were missing: /etc/gnupg, systemd-oomd,
#    NetworkManager-wait-online and gnome-keyring PAM in SDDM.
#  · /root/STAGE2_OK and the randomness seed travelled in the image.
#  · build.exp checked the dotfiles at /mnt/home/gabriel, hard-coded.
#
# AND FOUR COMMITTED WHILE FIXING, which only appeared by RUNNING
#  · confirm() used ${ans,,}, from bash 4: macOS ships bash 3.2 and there the expansion
#    error aborts the function, returning "yes" by accident. It appeared when
#    testing the questionnaire under a pty with expect; bash -n does not see it.
#  · config.env was written without quotes and VM_FULLNAME="Omarchy ARM" made
#    "ARM" execute as a command on source: dead chroot with rc=127.
#  · The ph_verify heredoc was not quoted, so the host
#    bash expanded the $(...) and the checks ran ON THE MAC
#    (pgrep with BSD syntax, systemctl missing) instead of inside the VM.
#    Rewritten with <<'"'"'EXPEOF'"'"' and the variables via Tcl $env(...).
#  · spice-vdagentd is a "static" unit: it is not enabled. You have to enable
#    spice-vdagentd.socket. Revealed by the freshly built VM.
#
# VALIDATION
#  Complete from-scratch build (8/8 phases) on 2026-08-23 on an M3 Max:
#   · 17/17 tools compiled (only herdr fails, because of the Zig version)
#   · extras=si menu=si hook=si  <- the three blockers, resolved
#   · verify inside the guest: H=1 Q=1 BINS=436 -> VEREDICTO_OK
#   · final image 4.1 GB; ~57 min without OBS/Pinta, ~1 h 50 with them
#  And the call stage3 makes for OBS and Pinta, tested separately on that same
#  VM: rc=0, obs-studio 32.2.2-1, pinta 3.1.2-2, /usr/bin/obs ELF ARM aarch64.
echo "Documentary record. The fixes are in build-omarchy-arm.sh and provision/src/."
