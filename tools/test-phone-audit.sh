#!/bin/sh
# Tests for phone-audit.sh against a fake /sys, /proc, /dev and firmware tree (no phone needed).
#   sh tools/test-phone-audit.sh
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILED=0
check() { # name, pattern, file
	if grep -qE "$2" "$3"; then echo "ok   $1"; else echo "FAIL $1"; FAILED=1; fi
}
absent() {
	if grep -qE "$2" "$3"; then echo "FAIL $1"; FAILED=1; else echo "ok   $1"; fi
}
mk() { # tree
	R=$T/$1; mkdir -p "$R"/sys/devices/system/cpu "$R"/proc/bus/input "$R"/dev "$R"/fw "$R"/sys/class/net "$R"/sys/class/power_supply/battery "$R"/sys/class/udc/musb "$R"/sys/class/graphics/fb0 "$R"/sys/class/thermal/thermal_zone0 "$R"/proc/asound "$R"/sys/class/leds/red
	echo 0-7 > "$R"/sys/devices/system/cpu/online; echo 0-7 > "$R"/sys/devices/system/cpu/present
	echo "Linux version 7.2.0-rc6-sprd (x) #1" > "$R"/proc/version
	echo "loglevel=7 cpuidle.off=1 cpufreq.off=1" > "$R"/proc/cmdline
	echo "700.12 100" > "$R"/proc/uptime
	printf 'MemTotal:        3900000 kB\n' > "$R"/proc/meminfo
	printf '/dev/mmcblk0p2 / ext4 rw 0 0\n' > "$R"/proc/mounts
	touch "$R"/dev/mmcblk0 "$R"/dev/mmcblk0p1 "$R"/dev/mmcblk0p2
	echo Battery > "$R"/sys/class/power_supply/battery/type; echo Discharging > "$R"/sys/class/power_supply/battery/status
	echo 80 > "$R"/sys/class/power_supply/battery/capacity; echo 4000000 > "$R"/sys/class/power_supply/battery/voltage_now
	echo fb > "$R"/sys/class/graphics/fb0/name; echo 720,1612 > "$R"/sys/class/graphics/fb0/virtual_size
	echo 40000 > "$R"/sys/class/thermal/thermal_zone0/temp; echo cpu > "$R"/sys/class/thermal/thermal_zone0/type
	echo " 0 [x]: card" > "$R"/proc/asound/cards
	printf 'N: Name="omnivision_tcm_touch"\nN: Name="gpio-keys"\nN: Name="sc27xx-vibra"\n' > "$R"/proc/bus/input/devices
	printf '  5:  12 0 GIC tcm\n' > "$R"/proc/interrupts
	: > "$R"/dmesg
	mkdir -p "$R"/fw/postmarketos/sprd; echo x > "$R"/fw/postmarketos/sprd/hdl_firmware_01.img
}
run() { # tree
	R=$T/$1
	SYS=$R/sys PROC=$R/proc DEVD=$R/dev FW=$R/fw DMESG_FILE=$R/dmesg OUT=$R/out sh "$HERE/phone-audit.sh" > "$R/stdout" 2>&1
	echo $? > "$R/rc"
}

mk good; run good
check "healthy touch passes" 'PASS +touch +input device omnivision' "$T/good/stdout"
check "healthy battery passes" 'PASS +battery' "$T/good/stdout"
check "all CPUs online" 'PASS +cpu +all CPUs online' "$T/good/stdout"
check "past the watchdog window" 'PASS +watchdog' "$T/good/stdout"
check "workaround noted" 'INFO +cmdline +workaround active: cpuidle.off=1' "$T/good/stdout"
check "missing wifi firmware is a FAIL with the fix named" 'FAIL +wifi.*firmware missing' "$T/good/stdout"
check "summary printed" 'PASS [0-9]+ +WARN [0-9]+ +FAIL [0-9]+' "$T/good/stdout"
check "exit status 1 when something fails" '^1$' "$T/good/rc"
check "report file written" 'PASS' "$T/good/out"

mk bad; printf 'rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:\n vddldo0: disabling\nsprd-power: wait for vbus off failed, ret = -110\n' > "$T/bad/dmesg"
echo 0-5 > "$T/bad/sys/devices/system/cpu/online"; rm "$T/bad/dev/mmcblk0"
echo "initcall_debug initcall_blacklist=sprd_drm_init" > "$T/bad/proc/cmdline"; echo "100.00 1" > "$T/bad/proc/uptime"
run bad
check "RCU stall detected" 'FAIL +stability +RCU stall' "$T/bad/stdout"
check "touch rail cut detected" 'FAIL +touch +vddldo0 was switched off' "$T/bad/stdout"
check "offline CPUs detected" 'FAIL +cpu' "$T/bad/stdout"
check "no eMMC detected" 'FAIL +storage' "$T/bad/stdout"
check "debug option warned" 'WARN +cmdline +debug option still set: initcall_debug' "$T/bad/stdout"
check "display driver off warned" 'WARN +display +the real display driver is switched off' "$T/bad/stdout"
check "short uptime is not a pass" 'INFO +watchdog +uptime only 100s' "$T/bad/stdout"
absent "bad tree has no healthy stability line" 'PASS +stability +no RCU' "$T/bad/stdout"

mk wifi; mkdir -p "$T/wifi/fw/sprd" "$T/wifi/sys/class/net/wlan0" "$T/wifi/sys/class/remoteproc/remoteproc0"
echo x > "$T/wifi/fw/sprd/wcnmodem.bin"; echo x > "$T/wifi/fw/sprd/wifi_board_config.bin"; echo down > "$T/wifi/sys/class/net/wlan0/operstate"
run wifi
check "wlan0 passes" 'PASS +wifi +wlan0 present' "$T/wifi/stdout"
mk wifi2; mkdir -p "$T/wifi2/fw/sprd" "$T/wifi2/sys/class/remoteproc/remoteproc0"
echo x > "$T/wifi2/fw/sprd/wcnmodem.bin"; echo x > "$T/wifi2/fw/sprd/wifi_board_config.bin"; echo btwf > "$T/wifi2/sys/class/remoteproc/remoteproc0/name"; echo offline > "$T/wifi2/sys/class/remoteproc/remoteproc0/state"
run wifi2
check "firmware present but WCN offline is named" "FAIL +wifi +no wlan0; remoteproc state 'offline'" "$T/wifi2/stdout"

[ "$FAILED" = 0 ] && echo "all passed" || { echo "SOME FAILED"; exit 1; }
