#!/bin/sh
# Collect the Wi-Fi/Bluetooth (WCN) firmware the mainline stack needs from the phone's own stock
# system. Run it as root, either on the phone under postmarketOS or in a root shell on Android:
#
#   sh extract-wcn-firmware.sh [output-dir]        # default: ./x6525-wcn
#
# The mainline kernel loads two files and finds neither in a fresh image:
#   sprd/wcnmodem.bin           the firmware of the WCN processor (the remoteproc "btwf")
#   sprd/wifi_board_config.bin  the board's Wi-Fi configuration, sent to the chip at probe
# They are Unisoc's and are on the stock system, not on the internet. This script does not guess
# which file is which: it copies every candidate it can find, with sizes and hashes, plus a report,
# so the right ones can be chosen from facts. It only reads; it writes only into the output dir.
#   * raw partitions with wcn/btwf in their name (read with dd)
#   * files named like wcnmodem*, wifi_board_config*, *wcn*.bin on any mounted filesystem
#   * on postmarketOS, where the stock vendor partition sits inside `super` and is not mounted: it
#     says so, and how to open it (lpunpack), rather than doing it silently.
# Paths can be redirected for testing (ROOTS, PARTDIRS).
OUT=${1:-./x6525-wcn}
ROOTS=${ROOTS:-"/vendor /odm /product /system /system_ext /vendor_dlkm /odm_dlkm /mnt/vendor /data/vendor /lib/firmware /usr/lib/firmware"}
PARTDIRS=${PARTDIRS:-"/dev/block/by-name /dev/disk/by-partlabel"}
mkdir -p "$OUT/files" "$OUT/partitions" || exit 1
REP=$OUT/report.txt
: > "$REP"
say() { printf '%s\n' "$*" | tee -a "$REP"; }

[ "$(id -u)" = 0 ] || say "WARNING: not root; raw partitions will not be readable."
say "== $(date '+%F %T')  $(uname -srm)"

say; say "== candidate files"
N=0
for r in $ROOTS; do
	[ -d "$r" ] || continue
	find "$r" -xdev -type f \( -iname 'wcnmodem*' -o -iname 'wifi_board_config*' -o -iname 'wcn*.bin' \
		-o -iname 'wcn*.img' -o -iname 'btwf*' -o -iname 'wcnfdl*' -o -iname 'connectivity_configure*' \
		-o -iname 'wifi_*.ini' -o -iname 'wcn*.ini' \) 2>/dev/null
done | sort -u | while read -r f; do
	b=$(basename "$f"); d="$OUT/files/$(printf '%s' "$f" | sed 's|^/||; s|/|__|g')"
	cp "$f" "$d" 2>/dev/null || { say "cannot read $f"; continue; }
	say "$(wc -c < "$d") bytes  $(sha256sum "$d" | cut -c1-16)  $f"
	N=$((N + 1))
done
[ -n "$(ls "$OUT/files" 2>/dev/null)" ] || say "none found on the mounted filesystems"

say; say "== raw partitions"
FOUND=0
for pd in $PARTDIRS; do
	[ -d "$pd" ] || continue
	for p in "$pd"/*; do
		n=$(basename "$p")
		case $(printf '%s' "$n" | tr 'A-Z' 'a-z') in
			*wcn*|*btwf*|*cpwcn*)
				dev=$(readlink -f "$p")
				[ -e "$OUT/partitions/$n.img" ] && continue
				if dd if="$dev" of="$OUT/partitions/$n.img" bs=1M 2>/dev/null; then
					FOUND=1
					say "$(wc -c < "$OUT/partitions/$n.img") bytes  $(sha256sum "$OUT/partitions/$n.img" | cut -c1-16)  $n ($dev)"
					say "  first bytes: $(head -c 32 "$OUT/partitions/$n.img" | od -An -tx1 | tr -d '\n')"
				else say "cannot read $n ($dev)"; fi ;;
		esac
	done
done
[ "$FOUND" = 1 ] || say "no wcn/btwf partition found in: $PARTDIRS"

say; say "== where the stock vendor files live"
SUPER=""
for pd in $PARTDIRS; do [ -e "$pd/super" ] && SUPER=$(readlink -f "$pd/super"); done
if [ -n "$SUPER" ] && [ ! -d /vendor/firmware ]; then
	say "the stock vendor image is inside $SUPER (not mounted under postmarketOS)."
	if command -v lpunpack >/dev/null 2>&1; then
		say "lpunpack is installed: run   lpunpack -p vendor_a $SUPER /tmp/lp && mount -o ro,loop /tmp/lp/vendor_a.img /mnt"
		say "then re-run this script with ROOTS=/mnt"
	else
		say "to open it: apk add android-tools (or any lpunpack), then the two commands above."
		say "a virtual-A/B phone may keep the vendor image in a snapshot; if vendor_a.img is empty, boot Android and run this script there."
	fi
fi

say; say "== chip and stack in use on the stock system (Android only)"
if command -v getprop >/dev/null 2>&1; then
	getprop | grep -iE 'wcn|wifi|connectivity|sprd|bt\.' | head -30 | tee -a "$REP"
	lsmod 2>/dev/null | grep -iE 'wlan|wcn|sprd|sc23|sipc' | tee -a "$REP"
fi
ls /sys/class/remoteproc 2>/dev/null | while read -r r; do say "remoteproc $r: $(cat /sys/class/remoteproc/$r/name) $(cat /sys/class/remoteproc/$r/state)"; done

( cd "$OUT" && tar czf ../x6525-wcn-extract.tar.gz . ) 2>/dev/null && say && say "packed: $(cd "$OUT/.." && pwd)/x6525-wcn-extract.tar.gz"
say "send me that archive (or report.txt) and I will pick and convert the right files."
