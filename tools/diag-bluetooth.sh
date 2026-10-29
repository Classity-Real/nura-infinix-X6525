#!/bin/sh
# Why does the Bluetooth toggle switch itself off? Run on the phone over SSH:
#   sh tools/diag-bluetooth.sh            # writes /tmp/bt-diag.txt, send that file
# Read-only except for one power-on attempt (step 4), done while the logs are watched.
OUT=/tmp/bt-diag.txt
S=; [ "$(id -u)" = 0 ] || S=sudo
{
echo "== 1. identity"; uname -r; apk info -v linux-postmarketos-unisoc-ums9230 device-infinix-x6525 bluez 2>&1
echo; echo "== 2. modules and the transport"
lsmod | grep -iE 'btsprd|sprd_wcn|sipc|rpmsg|bluetooth|hci|sc23xx' 
ls /sys/class/bluetooth/ 2>&1; ls /sys/bus/rpmsg/devices 2>&1 | head
$S dmesg | grep -iE 'btsprd|wcn|sipc|sbuf|bluetooth|hci[0-9]|pskey|bt_config' | tail -50
echo; echo "== 3. rfkill and BlueZ state"
$S rfkill list 2>&1
systemctl is-active bluetooth; systemctl is-enabled bluetooth
$S btmgmt info 2>&1 | head -20
$S bluetoothctl show 2>&1 | head -15
echo; echo "== 4. firmware, MAC service and files"
ls -l /lib/firmware/sprd/ 2>&1 | grep -iE 'bt|wcn' | head
systemctl status x6525-prodnv-mac --no-pager 2>&1 | head -12
$S ls -l /mnt/prodnv/btmac.txt /var/lib/x6525*/ 2>&1 | head
echo; echo "== 5. one power-on attempt, with the logs watched"
$S dmesg -C 2>/dev/null; $S dmesg -w > /tmp/bt-dmesg-live.txt 2>&1 & W=$!
$S journalctl -u bluetooth -f --no-pager > /tmp/bt-journal-live.txt 2>&1 & J=$!
sleep 1
$S rfkill unblock bluetooth
$S btmgmt power on 2>&1 | head -5
sleep 4
$S btmgmt info 2>&1 | grep -iE 'current settings|powered|addr' 
kill $W $J 2>/dev/null
echo "--- kernel log during the attempt"; cat /tmp/bt-dmesg-live.txt | tail -60
echo "--- bluetoothd log during the attempt"; cat /tmp/bt-journal-live.txt | tail -40
echo; echo "== 6. after"; $S rfkill list bluetooth 2>&1; $S bluetoothctl show 2>&1 | grep -iE 'Powered|PowerState|Address'
echo; echo "== 7. earlier bluetoothd errors this boot"
$S journalctl -u bluetooth -b --no-pager 2>&1 | grep -iE 'fail|error|timeout|unable|denied|rfkill|power' | tail -25
} > "$OUT" 2>&1
echo "wrote $OUT ($(wc -l < "$OUT") lines): please send it"
