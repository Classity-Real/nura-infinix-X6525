#!/bin/sh
# Collect what is needed to write a mainline driver for the video codec (VSP)
# and JPEG blocks: run it on the STOCK Android system (Termux with root, or
# `adb shell` as root), not on postmarketOS. It only reads.
#
#   su -c 'sh /sdcard/dump-stock-codec.sh'          # writes /sdcard/codec-dump/
#   adb pull /sdcard/codec-dump                      # then attach it
#
# What it answers: where the blocks sit (MMIO base, IRQ, clocks, power domain,
# IOMMU), which IP they are (compatible strings), what the vendor kernel and
# userspace driver are called, and which register names the driver knows.
OUT=${1:-/sdcard/codec-dump}
mkdir -p "$OUT" || exit 1
W() { printf '== %s\n' "$*"; }

{
W "kernel / device"
uname -a; getprop ro.product.model 2>/dev/null; getprop ro.board.platform 2>/dev/null
cat /proc/cmdline | tr ' ' '\n' | grep -iE 'chipid|lcd|platform|boot_devices'

W "live device tree: every node that looks like a codec, JPEG, GSP or IOMMU"
DT=/proc/device-tree
[ -d "$DT" ] || DT=/sys/firmware/devicetree/base
find -L "$DT/" -maxdepth 6 -type d 2>/dev/null | grep -iE 'vsp|vpu|vdec|venc|jpg|jpeg|codec|gsp|iommu|mm-?sub' | head -60
for d in $(find -L "$DT/" -maxdepth 6 -type d 2>/dev/null | grep -iE 'vsp|vpu|vdec|venc|jpg|jpeg|codec' | head -20); do
	echo "--- $d"
	for f in compatible reg interrupts clock-names clocks power-domains iommus resets reset-names sprd,name sprd,ip_version sprd,version sprd,vsp_clk_freq operating-points; do
		[ -e "$d/$f" ] && { printf '%s: ' "$f"; od -An -tx1 -v "$d/$f" 2>/dev/null | tr -d '\n' | cut -c1-200; printf ' | '; tr '\0' ' ' < "$d/$f" 2>/dev/null | tr -cd '[:print:]' | cut -c1-120; echo; }
	done
done

W "iomem / interrupts / clocks / power domains the kernel knows"
grep -iE 'vsp|vpu|vdec|venc|jpg|jpeg|codec' /proc/iomem /proc/interrupts 2>/dev/null
grep -iE 'vsp|vpu|jpg|codec' /sys/kernel/debug/clk/clk_summary 2>/dev/null | head -20
ls /sys/class/devfreq 2>/dev/null
ls /sys/kernel/debug/pm_genpd 2>/dev/null | head; grep -iE 'vsp|codec|mm' /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | head

W "device nodes and kernel modules"
ls -l /dev | grep -iE 'vsp|vpu|jpg|jpeg|codec|ion|dma_heap'
ls /sys/class | grep -iE 'vsp|vpu|jpg|codec|video'
lsmod 2>/dev/null | grep -iE 'vsp|vpu|jpg|codec|mm|sprd' | head -30
find /vendor_dlkm /vendor/lib/modules /vendor/lib64/modules /system/lib/modules /lib/modules -name '*.ko' 2>/dev/null | grep -iE 'vsp|vpu|jpg|jpeg|codec|vdec|venc' | head

W "userspace codec libraries and the OMX/Codec2 service"
ls -l /vendor/lib64 /vendor/lib 2>/dev/null | grep -iE 'vsp|sprd.*(h264|hevc|vp9|dec|enc)|libomx|libstagefright_sprd|codec2' | head -40
ls /vendor/etc 2>/dev/null | grep -iE 'media_codecs|vsp|omx'
dumpsys media.codec 2>/dev/null | grep -iE 'name|sprd|vsp|hw' | head -30

W "recent kernel log lines from the blocks"
dmesg 2>/dev/null | grep -iE 'vsp|vpu|vdec|venc|jpg|jpeg' | tail -60
} > "$OUT/info.txt" 2>&1

# the whole flattened device tree: one ~200 KB file with every node's registers,
# interrupts, clocks, syscon offsets and IOMMU links (find on a symlinked
# /proc/device-tree used to come back empty)
for f in /sys/firmware/fdt /proc/device-tree/../fdt; do
	[ -f "$f" ] && { cp "$f" "$OUT"/stock.dtb 2>/dev/null && break; }
done

# the module itself, the firmware it loads, and the libs (small files only)
for f in $(find /vendor_dlkm /vendor/lib/modules /vendor/lib64/modules /system/lib/modules -name '*.ko' 2>/dev/null | grep -iE 'vsp|vpu|jpg|jpeg|codec|vdec|venc'); do
	cp "$f" "$OUT"/ 2>/dev/null
done
for f in $(ls /vendor/lib64/*vsp* /vendor/lib64/libomx*sprd* /vendor/lib64/libstagefright_sprd* /vendor/firmware/*vsp* /vendor/firmware/*vpu* 2>/dev/null); do
	[ -f "$f" ] && [ "$(wc -c < "$f")" -lt 8000000 ] && cp "$f" "$OUT"/ 2>/dev/null
done

# the module's own strings often name every register and ioctl
for k in "$OUT"/*.ko; do
	[ -f "$k" ] && strings "$k" 2>/dev/null | grep -iE 'reg|offset|base|irq|mmu|clk|freq|ioctl|vsp|vpu|dec|enc|jpg|ver' | head -300 > "$k.strings.txt"
done

echo "wrote $OUT ($(ls "$OUT" | wc -l) files)"
echo "if no .ko appeared, the driver is built into the stock kernel: info.txt still has the device-tree nodes"
