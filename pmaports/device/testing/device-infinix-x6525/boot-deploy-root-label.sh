#!/bin/sh
# boot-deploy hook: name the two pmOS-owned filesystems by label, not UUID.
#
# Why: boot-deploy builds extlinux's `append` line from /etc/fstab. A `UUID=`
# entry becomes `pmos_root_uuid=`/`pmos_boot_uuid=` and the initramfs accepts
# only that exact filesystem UUID. A cache-only flash (new kernel/display on
# the old rootfs) then stops at "Waiting for root partition", because the new
# extlinux names a root UUID the phone does not have. With labels, boot-deploy
# adds no UUID (see get_cmdline() in boot-deploy-functions.sh) and the
# initramfs falls back to the pmOS_root/pmOS_boot labels (find_partition() in
# postmarketos-initramfs). Those labels are stable across builds, so boot and
# root images from different builds work together.
#
# The initramfs hooks-cleanup script in this package rewrites an older rootfs's
# fstab the same way at boot, so the first label-based cache also works with a
# rootfs built before this hook existed.
#
# Only the two entries this port owns are touched. A root on /dev/mapper (full
# disk encryption) is left alone; the boot entry still becomes a label.
set -eu

fstab=/etc/fstab
[ -f "$fstab" ] || exit 0

tmp="${fstab}.x6525"
awk '
	$1 ~ /^UUID=/ && $2 == "/"     { $1 = "LABEL=pmOS_root" }
	$1 ~ /^UUID=/ && $2 == "/boot" { $1 = "LABEL=pmOS_boot" }
	{ print }
' "$fstab" > "$tmp"

if ! cmp -s "$fstab" "$tmp"; then
	echo "x6525: naming / and /boot by label in $fstab"
	cat "$tmp" > "$fstab"
fi
rm -f "$tmp"
