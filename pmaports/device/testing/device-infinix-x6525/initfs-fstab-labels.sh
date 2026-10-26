#!/bin/sh
# Runs in the initramfs from /hooks-cleanup, after /sysroot is mounted and
# before switch_root. Migrate an fstab that still names root/boot by UUID to
# labels, so it agrees with the label-based extlinux this build writes.
#
# Without this, a cache flashed alone (a new boot filesystem with the old
# rootfs) would find and mount the root by label, then systemd would try the
# stale UUIDs from the old fstab and could fail / or /boot. The rewrite is
# idempotent, so it costs nothing once the fstab is already label-based.
set -eu

fstab=/sysroot/etc/fstab
[ -f "$fstab" ] || exit 0

mkdir -p /tmp
tmp=/tmp/fstab.x6525
awk '
	$1 ~ /^UUID=/ && $2 == "/"     { $1 = "LABEL=pmOS_root" }
	$1 ~ /^UUID=/ && $2 == "/boot" { $1 = "LABEL=pmOS_boot" }
	{ print }
' "$fstab" > "$tmp"

if ! cmp -s "$fstab" "$tmp"; then
	echo "x6525: migrating $fstab to labels"
	cat "$tmp" > "$fstab"
	sync
fi
rm -f "$tmp"
