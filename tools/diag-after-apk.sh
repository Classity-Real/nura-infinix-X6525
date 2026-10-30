#!/bin/sh
# What did `apk add` change, and what broke afterwards (touch dead after screen off,
# slower boot with bpf/USB lines, a much smaller UI scale)? Run over SSH:
#   sh tools/diag-after-apk.sh       # writes /tmp/after-apk-diag.txt, send that file
# Read-only. Run it once in the state that is wrong (touch dead / small UI).
OUT=/tmp/after-apk-diag.txt
S=; [ "$(id -u)" = 0 ] || S=sudo
{
echo "== 1. identity and uptime"; uname -r; uptime; cat /proc/cmdline
echo; echo "== 2. what apk changed (transaction log) and the repositories"
$S tail -80 /var/log/apk.log 2>&1
cat /etc/apk/repositories 2>&1
echo; echo "== 3. versions of the packages that matter"
apk list -I 2>/dev/null | grep -E '^(device-infinix|linux-postmarketos|firmware-infinix|soc-unisoc|u-boot-infinix|systemd-[0-9]|systemd |musl-[0-9]|phosh|phoc|greetd|mkinitfs|postmarketos-base|libinput|mesa-[0-9]|libdrm)' | head -30
echo; echo "== 4. the boot filesystem and the root"
df -h / /boot 2>&1; ls -la /boot 2>&1 | head -12; ls -la /var/lib/x6525-boot-backup 2>&1 | head
echo; echo "== 5. units that failed, and the bpf / usb lines of this boot"
systemctl --failed --no-pager 2>&1 | head -15
$S journalctl -b --no-pager 2>&1 | grep -iE 'bpf' | head -12
$S journalctl -b --no-pager 2>&1 | grep -iE 'usb|gadget|configfs|udc' | head -20
echo; echo "== 6. display: why the UI scale may have changed"
ls -l /dev/dri/ 2>&1
$S dmesg | grep -iE 'sprd.?drm|dpu|dsi|panel|td4160|simpledrm|drm' | tail -25
$S journalctl -b --no-pager -u greetd 2>&1 | tail -15
$S journalctl -b --no-pager 2>&1 | grep -iE 'phoc|scale|output|x6525-wait-drm' | tail -15
echo; echo "== 7. touch"
$S dmesg | grep -iE 'ovt|tcm|touch|vddldo' | tail -20
grep -B1 -A6 -iE 'touch|ovt' /proc/bus/input/devices 2>&1 | head -16
grep -iE 'ovt|tcm|touch|gpio' /proc/interrupts 2>&1 | head -6
ls -l /sys/bus/spi/devices/ 2>&1
echo; echo "== 8. idle and stalls"
cat /sys/devices/system/cpu/cpuidle/current_driver 2>&1
$S dmesg | grep -iE 'rcu|stall|lockup|Oops|BUG:|WARNING:|hung task' | tail -10
echo; echo "== 9. the previous boot (the one where touch died): kernel log tail"
$S journalctl -k -b -1 --no-pager 2>&1 | tail -80
echo; echo "== 10. errors of this boot"
$S journalctl -b --no-pager -p err 2>&1 | tail -40
} > "$OUT" 2>&1
echo "wrote $OUT ($(wc -l < "$OUT") lines): please send it"
