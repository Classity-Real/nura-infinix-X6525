#!/bin/sh
# Add kernel command-line options to the extlinux.conf inside a pmOS boot filesystem image
# (the one flashed to `cache`), without a rebuild, and prove the edit worked.
#
#   sh tools/patch-cmdline.sh pmos-boot-fs.img                      # cpuidle.off=1 cpufreq.off=1
#   sh tools/patch-cmdline.sh pmos-boot-fs.img "some.option=1 ..."   # your own options
#
# Safe to run again: options already present are not added twice. Only the `append` line changes
# (the script shows a diff and stops if anything else differs). Needs debugfs and e2fsck
# (e2fsprogs); works on a copy first and replaces the image only after every check passes.
set -eu
IMG=${1:?usage: patch-cmdline.sh <pmos-boot-fs.img> [options]}
OPTS=${2:-cpuidle.off=1 cpufreq.off=1}
[ -f "$IMG" ] || { echo "no such file: $IMG"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp "$IMG" "$W/img"

debugfs -R "cat /extlinux/extlinux.conf" "$W/img" > "$W/old" 2>/dev/null
[ -s "$W/old" ] || { echo "FAIL: could not read /extlinux/extlinux.conf (wrong image?)"; exit 1; }
grep -q '^[[:space:]]*append ' "$W/old" || { echo "FAIL: no append line in extlinux.conf"; exit 1; }

cp "$W/old" "$W/new"
for o in $OPTS; do
	# whole-word test on the append lines
	if grep '^[[:space:]]*append ' "$W/new" | grep -qE "(^|[[:space:]])$(printf '%s' "$o" | sed 's/[.[\*^$]/\\&/g')([[:space:]]|\$)"; then
		echo "already there: $o"
	else
		sed -i "/^[[:space:]]*append /s/\$/ $o/" "$W/new"
		echo "added:         $o"
	fi
done

echo "--- change (only the append line may differ) ---"
diff "$W/old" "$W/new" || true
# every differing line must be an append line
if diff "$W/old" "$W/new" | grep -E '^[<>]' | grep -vqE '^[<>][[:space:]]*append '; then
	echo "FAIL: something other than the append line changed"; exit 1
fi

if cmp -s "$W/old" "$W/new"; then
	echo "nothing to do: $IMG already has every option"
else
	debugfs -w -R "rm /extlinux/extlinux.conf" "$W/img" >/dev/null 2>&1
	debugfs -w -R "write $W/new /extlinux/extlinux.conf" "$W/img" >/dev/null 2>&1
fi

# verify from the image itself, not from the file we meant to write
debugfs -R "cat /extlinux/extlinux.conf" "$W/img" > "$W/back" 2>/dev/null
cmp -s "$W/new" "$W/back" || { echo "FAIL: image content differs from what was written; $IMG left untouched"; exit 1; }
for o in $OPTS; do
	grep '^[[:space:]]*append ' "$W/back" | grep -q -- "$o" || { echo "FAIL: $o missing after write"; exit 1; }
done
e2fsck -fn "$W/img" >"$W/fsck" 2>&1 || { cat "$W/fsck"; echo "FAIL: filesystem check; $IMG left untouched"; exit 1; }
# the kernel and initramfs must still be there
for f in vmlinuz initramfs; do
	debugfs -R "stat /$f" "$W/img" >/dev/null 2>&1 || { echo "FAIL: /$f missing; $IMG left untouched"; exit 1; }
done

if cmp -s "$W/old" "$W/new"; then
	echo "OK: $IMG unchanged. The append line reads:"
else
	[ -e "$IMG.orig" ] || cp "$IMG" "$IMG.orig"   # keep the first original, never overwrite it
	cp "$W/img" "$IMG"
	echo "OK: $IMG patched (original kept as $IMG.orig). The append line now reads:"
fi
grep '^[[:space:]]*append ' "$W/back"
