#!/bin/sh
# Collect the diagnostics for graphics, keyboard, Bluetooth, camera, cellular
# and audio from a running X6525 into one text file you can paste or attach.
#
#   sh tools/diag-phone.sh            # on the phone, as the normal user
#   -> writes ~/diag-<date>.txt and prints its path
#
# It only reads state; nothing is changed. It asks for the sudo password once
# (dmesg needs it). Missing tools are reported in the output, not fatal.
# tools/phone-audit.sh is the pass/fail checklist; this one is the raw evidence.

OUT=${1:-$HOME/diag-$(date +%Y%m%d-%H%M%S).txt}
UID_NUM=$(id -u)
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$UID_NUM}
export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-1}

sudo -v 2>/dev/null || echo "note: no sudo, dmesg sections will be empty" >&2

sec() { printf '\n==== %s ====\n' "$1"; }
run() {
	printf '\n$ %s\n' "$*"
	sh -c "$*" 2>&1 | head -${LINES_MAX:-60}
}
dmesg_grep() { run "sudo -n dmesg 2>&1 | grep -iE '$1' | tail -${2:-40}"; }

{
echo "x6525 diagnostics, $(date), kernel $(uname -r)"

sec "BOOT / CPU (cpufreq.off and cpuidle.off disable scaling and idle)"
run "cat /proc/cmdline"
run "ls /sys/devices/system/cpu/cpu0/cpufreq 2>&1 | head -5; cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>&1"
run "cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name 2>&1"
run "uptime; cat /sys/class/thermal/thermal_zone*/temp 2>&1 | head -8"
dmesg_grep 'rcu.*stall|blocked for|BUG:|Oops|WARNING:' 20

sec "GRAPHICS (is KWin on the GPU or on llvmpipe?)"
run "ls -l /dev/dri/ /dev/dri/x6525-primary"
run "for c in /dev/dri/card* /dev/dri/renderD*; do echo \"\$c: \$(udevadm info -q path -n \$c)\"; done"
run "qdbus6 org.kde.KWin /KWin supportInformation | grep -iE 'compositing type|opengl renderer|opengl vendor|gl version|gl platform|driver|egl'"
run "pgrep -a kwin_wayland; cat /proc/\$(pgrep -o kwin_wayland)/environ 2>/dev/null | tr '\\0' '\\n' | grep -E 'KWIN|MESA|WLR|LIBGL|EGL'"
run "pgrep -a phoc; cat /proc/\$(pgrep -o phoc)/environ 2>/dev/null | tr '\\0' '\\n' | grep -E 'WLR|MESA|EGL'"
run "journalctl -b -u greetd --no-pager | grep -iE 'renderer|gles|pixman|egl|panfrost|render' | tail -20"
run "eglinfo 2>&1 | grep -iE 'renderer|vendor|driver|device' | head -20"
run "top -H -b -n1 | head -15"
run "vulkaninfo --summary 2>&1 | grep -iE 'deviceName|driverName|apiVersion'"
run "cat /sys/class/devfreq/*/cur_freq /sys/class/devfreq/*/governor 2>&1"
dmesg_grep 'panfrost|mali|sprd.?(dpu|dsi|drm)|iommu.*fault|flip_done|td4160' 40
run "journalctl -b --no-pager _UID=$UID_NUM | grep -iE 'kwin|egl|gbm|zink|llvmpipe|panfrost|no outputs|drm' | tail -30"

sec "KEYBOARD"
run "kreadconfig6 --file kwinrc --group Wayland --key InputMethod"
run "grep -n -A3 '\\[Wayland\\]' ~/.config/kwinrc"
run "ls /usr/share/applications | grep -iE 'keyboard|maliit'"
run "pgrep -a -f 'maliit|plasma-keyboard'; pgrep -a buffyboard"
run "apk info -e maliit-keyboard maliit-framework plasma-keyboard 2>&1"

sec "BLUETOOTH"
dmesg_grep 'btsprd|wcn_bt|channel .*(not found|in use)|endpoint|bluetooth|hci' 40
run "bluetoothctl show 2>&1 | head -8"
run "systemctl is-active bluetooth; ls /lib/firmware/sprd/bt_config* 2>&1"

sec "CAMERA"
dmesg_grep 's5k3l6|ov8856|camsys|sprd.*isp|csi' 40
run "ls -l /dev/video* /dev/media* /dev/v4l-subdev* 2>&1"
run "v4l2-ctl --list-devices 2>&1"
run "media-ctl -p 2>&1 | head -40"
run "lsmod | grep -iE 'camsys|isp|s5k3l6|ov8856'"

sec "CELLULAR"
run "systemctl status x6525-modem-nv --no-pager 2>&1 | head -15"
run "for r in /sys/class/remoteproc/*; do echo \"\$r \$(cat \$r/name) \$(cat \$r/state)\"; done"
dmesg_grep 'sprd_modem|l_modem|pubcp|modem|rpmsg|wwan' 40
run "ls -l /lib/firmware/sprd/ 2>&1"
run "ls -l /dev/wwan* 2>&1"
run "systemctl is-active ModemManager; mmcli -L 2>&1"
run "apk info -e modemmanager 2>&1"

sec "AUDIO"
run "cat /proc/asound/cards"
run "aplay -l 2>&1"
run "pactl list short cards sinks sources 2>&1"
dmesg_grep 'asoc|snd|sc2730|codec|speaker|dai|audio' 40
run "journalctl -b --no-pager _UID=$UID_NUM | grep -iE 'callaudiod|pulseaudio|pipewire|wireplumber|alsa' | tail -20"

sec "FAILED UNITS / RECENT ERRORS"
run "systemctl --failed --no-pager"
run "journalctl -b --no-pager -p err | tail -40"
} > "$OUT" 2>&1

echo "wrote $OUT ($(wc -l < "$OUT") lines)"
