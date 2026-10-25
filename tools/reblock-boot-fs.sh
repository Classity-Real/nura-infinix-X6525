#!/bin/sh
# Rebuild an ext2/3/4 image with a larger filesystem block size, in place.
#
#     sh tools/reblock-boot-fs.sh pmos-boot-fs.img [4096]
#
# Why: a UFS unit's LUN has 4096-byte logical blocks, and neither U-Boot's ext4
# driver nor Linux can read a filesystem whose block size is smaller than the
# device's. pmbootstrap makes the small boot filesystem with mke2fs's "small"
# defaults, i.e. 1024-byte blocks; U-Boot then prints
# "Read outside partition 9223372036854775808" on the UFS `cache` partition.
# A 4096-byte-block filesystem is read fine on eMMC (512-byte blocks) as well,
# so every image gets it.
#
# The label and the UUID are kept (extlinux and the initramfs name them), the
# files are copied through debugfs (no mount, no root, and no extended
# attributes, which not every filesystem the build runs on supports), and the
# result is compared against the original before it replaces it.
#
# Exit 0 if the image already has blocks of at least the wanted size.

set -eu

img=${1:?usage: reblock-boot-fs.sh IMAGE [BLOCKSIZE]}
want=${2:-4096}

[ -f "$img" ] || { echo "reblock-boot-fs: no such file: $img" >&2; exit 1; }
for t in dumpe2fs debugfs mke2fs e2fsck; do
	command -v "$t" >/dev/null 2>&1 || { echo "reblock-boot-fs: $t is not installed (e2fsprogs)" >&2; exit 1; }
done

hdr=$(dumpe2fs -h "$img" 2>/dev/null) || { echo "reblock-boot-fs: $img is not an ext2/3/4 image" >&2; exit 1; }
have=$(printf '%s\n' "$hdr" | awk '/^Block size:/{print $3}')
[ -n "$have" ] || { echo "reblock-boot-fs: cannot read the block size of $img" >&2; exit 1; }

if [ "$have" -ge "$want" ]; then
	echo "reblock-boot-fs: $img already has $have-byte blocks"
	exit 0
fi

label=$(printf '%s\n' "$hdr" | sed -n 's/^Filesystem volume name: *//p')
uuid=$(printf '%s\n' "$hdr" | sed -n 's/^Filesystem UUID: *//p')
feat=$(printf '%s\n' "$hdr" | sed -n 's/^Filesystem features: *//p')
[ "$label" = "<none>" ] && label=""
case "$feat" in
	*extent*) fstype=ext4 ;;
	*)        fstype=ext2 ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
src=$tmp/src
chk=$tmp/chk
new=$tmp/new.img
mkdir "$src" "$chk"

# Copy the contents out. "rdump /" puts the root directory's entries straight
# into $src; lost+found belongs to the old filesystem, the new one makes its own.
debugfs -R "rdump / $src" "$img" >/dev/null 2>&1
rm -rf "$src/lost+found"

# debugfs command files are whitespace-separated; the boot filesystem has no
# such names, so refuse rather than mangle one.
if (cd "$src" && find . | grep -q '[[:space:]]'); then
	echo "reblock-boot-fs: a file name with whitespace; not handled" >&2
	exit 1
fi

# The new filesystem is the old image's size rounded up to a whole number of
# wanted-size blocks. The caller already leaves headroom (8 MiB in the rom job),
# which is far more than the few KiB that larger blocks waste on a handful of files.
bytes=$(stat -c %s "$img")
size=$(( (bytes + want - 1) / want * want ))
truncate -s "$size" "$new"

set -- -q -F -t "$fstype" -b "$want"
[ -n "$label" ] && set -- "$@" -L "$label"
[ -n "$uuid" ] && set -- "$@" -U "$uuid"
mke2fs "$@" "$new"

cmds=$tmp/cmds.txt
(
	cd "$src"
	find . -type d ! -name . | sed 's|^\./||' | LC_ALL=C sort | sed 's|^|mkdir |'
	find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do
		echo "write $src/$f $f"
	done
	find . -type l | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r l; do
		echo "symlink $l $(readlink "$l")"
	done
) > "$cmds"

debugfs -w -f "$cmds" "$new" >"$tmp/debugfs.log" 2>&1 || { cat "$tmp/debugfs.log" >&2; exit 1; }
# debugfs reports a failed command on its output and still exits 0.
if grep -qiE 'not found|no such|error|failed|cannot|unable|file exists' "$tmp/debugfs.log"; then
	echo "reblock-boot-fs: debugfs reported problems:" >&2
	cat "$tmp/debugfs.log" >&2
	exit 1
fi

e2fsck -fn "$new" >"$tmp/fsck.log" 2>&1 || { cat "$tmp/fsck.log" >&2; echo "reblock-boot-fs: the new filesystem does not check clean" >&2; exit 1; }

got=$(dumpe2fs -h "$new" 2>/dev/null | awk '/^Block size:/{print $3}')
[ "$got" = "$want" ] || { echo "reblock-boot-fs: new block size is $got, wanted $want" >&2; exit 1; }

# Same files, same bytes, same modes as before.
debugfs -R "rdump / $chk" "$new" >/dev/null 2>&1
rm -rf "$chk/lost+found"
diff -r "$src" "$chk" >/dev/null || { echo "reblock-boot-fs: the rebuilt filesystem differs from the original" >&2; diff -rq "$src" "$chk" >&2 || true; exit 1; }
(cd "$src" && find . -type f -exec stat -c '%a %n' {} +) | LC_ALL=C sort > "$tmp/modes.old"
(cd "$chk" && find . -type f -exec stat -c '%a %n' {} +) | LC_ALL=C sort > "$tmp/modes.new"
diff -q "$tmp/modes.old" "$tmp/modes.new" >/dev/null || echo "reblock-boot-fs: note: file modes differ from the original (U-Boot ignores them)" >&2

mv "$new" "$img"
echo "reblock-boot-fs: $img rebuilt with $want-byte blocks (was $have), label '${label:-}', UUID ${uuid:-new}"
