#!/bin/sh
# Runtime feature audit for the Infinix X6525 running postmarketOS (tools/audit-features.sh audits the source
# tree and the built image instead; this one checks the live phone). Run it ON THE PHONE (as root if you can;
# most checks also work as the normal user):
#
#   sh phone-audit.sh            # prints a table and saves it to /tmp/phone-audit.txt
#   sh phone-audit.sh -q         # only the FAIL / WARN lines and the summary
#
# Every line is one of:
#   PASS  the feature is there and looks healthy
#   FAIL  expected to work (or must work for the boot to be trusted) and does not
#   WARN  present but suspicious, or a debug option is still on
#   INFO  a fact worth knowing, not a verdict
#   SKIP  not supported yet on this port (so a missing item is not a regression)
# The script only reads: it never writes outside $OUT, loads no module, and changes no setting.
# Paths can be redirected for testing (SYS, PROC, DEVD, FW, DMESG_FILE).
#
# What it can and cannot tell you: it checks that the kernel exposes the device and that nothing is
# logged against it. It cannot tell whether the picture looks right or the speaker is loud.

SYS=${SYS:-/sys}
PROC=${PROC:-/proc}
DEVD=${DEVD:-/dev}
FW=${FW:-/lib/firmware}
OUT=${OUT:-/tmp/phone-audit.txt}
QUIET=0
[ "${1:-}" = "-q" ] && QUIET=1

NPASS=0; NFAIL=0; NWARN=0
FAILS=""
: > "$OUT" 2>/dev/null || OUT=/dev/null

emit() { # status area text
	line=$(printf '%-5s %-10s %s' "$1" "$2" "$3")
	printf '%s\n' "$line" >> "$OUT"
	if [ "$QUIET" = 0 ] || [ "$1" = FAIL ] || [ "$1" = WARN ] || [ "$1" = "====" ]; then printf '%s\n' "$line"; fi
}
pass() { NPASS=$((NPASS + 1)); emit PASS "$1" "$2"; }
fail() { NFAIL=$((NFAIL + 1)); FAILS="$FAILS $1"; emit FAIL "$1" "$2"; [ -n "${3:-}" ] && emit "  ->" "" "$3"; }
warn() { NWARN=$((NWARN + 1)); emit WARN "$1" "$2"; [ -n "${3:-}" ] && emit "  ->" "" "$3"; }
info() { emit INFO "$1" "$2"; }
skip() { emit SKIP "$1" "$2"; }

dm() { if [ -n "${DMESG_FILE:-}" ]; then cat "$DMESG_FILE"; else dmesg 2>/dev/null; fi; }
DM=$(dm)
[ -n "$DM" ] || warn dmesg "kernel log not readable (run as root, or: sudo sh $0)" "most log-based checks below are blind without it"
dmgrep() { printf '%s\n' "$DM" | grep -iE "$1"; }
dmcount() { printf '%s\n' "$DM" | grep -ciE "$1"; }
first() { for f in "$@"; do [ -e "$f" ] && { echo "$f"; return 0; }; done; return 1; }
rd() { cat "$1" 2>/dev/null; }

# ---------------------------------------------------------------- kernel and boot
KVER=$(rd "$PROC/version" | cut -d' ' -f3)
info kernel "${KVER:-unknown}"
CMD=$(rd "$PROC/cmdline")
for o in cpuidle.off=1 cpufreq.off=1 regulator_ignore_unused; do
	case " $CMD " in *" $o "*) info cmdline "workaround active: $o" ;; esac
done
case " $CMD " in *initcall_blacklist=sprd_drm_init*) DRM_OFF=1 ;; *) DRM_OFF=0 ;; esac
for o in initcall_debug ignore_loglevel pmos.debug-shell; do
	case " $CMD " in *" $o "*) warn cmdline "debug option still set: $o" "remove it once the build is stable" ;; esac
done

n=$(dmcount "rcu_preempt detected stalls|rcu: INFO: .*detected stall|rcu_sched detected stalls")
if [ "$n" -eq 0 ]; then pass stability "no RCU stall in the kernel log"
else fail stability "RCU stall reported $n time(s): a CPU stopped taking timer interrupts" \
	"known cause: CPU idle or cpufreq; boot with cpuidle.off=1 cpufreq.off=1 (see FIRST_BOOT.md)"; fi
n=$(dmcount "soft lockup|hard LOCKUP|hung task|blocked for more than|Kernel panic|Oops|BUG:|Call trace")
if [ "$n" -eq 0 ]; then pass stability "no lockup, oops or panic in the kernel log"
else fail stability "$n lockup/oops/panic line(s)" "run: dmesg | grep -iE 'lockup|hung task|Oops|BUG:|Call trace' | head"; fi

UP=$(cut -d. -f1 "$PROC/uptime" 2>/dev/null)
if [ -n "$UP" ]; then
	if [ "$UP" -ge 330 ]; then pass watchdog "uptime ${UP}s, past the old 5-minute reset window"
	else info watchdog "uptime only ${UP}s; wait until 6 minutes to prove the PMIC watchdog stays off"; fi
fi
YEAR=$(date +%Y 2>/dev/null)
if [ -n "$YEAR" ] && [ "$YEAR" -ge 2026 ]; then pass clock "date is $(date '+%F %T')"
else warn clock "date is $(date '+%F %T' 2>/dev/null): wrong clock breaks TLS and apk" "set it: date -s @<epoch from another machine>"; fi
RTC=$(first "$SYS"/class/rtc/rtc0) && info rtc "present ($(rd "$RTC/name"))" || warn rtc "no rtc0: the clock resets at every boot"

# ---------------------------------------------------------------- CPU and memory
ONL=$(rd "$SYS/devices/system/cpu/online"); PRES=$(rd "$SYS/devices/system/cpu/present")
if [ -n "$ONL" ] && [ "$ONL" = "$PRES" ]; then pass cpu "all CPUs online ($ONL)"
else fail cpu "online '$ONL' but present '$PRES'" "dmesg | grep -iE 'psci|CPU[0-9]'"; fi
if [ -d "$SYS/devices/system/cpu/cpufreq" ]; then pass cpufreq "cpufreq policies present: $(ls "$SYS"/devices/system/cpu/cpufreq | tr '\n' ' ')"
else info cpufreq "no policy (expected while cpufreq.off=1: CPUs run at the bootloader's frequency)"; fi
if [ -d "$SYS/devices/system/cpu/cpu0/cpuidle" ]; then pass cpuidle "idle states present"
else info cpuidle "off (expected while cpuidle.off=1: higher power use)"; fi
MEM=$(awk '/^MemTotal/ {print $2}' "$PROC/meminfo" 2>/dev/null)
if [ -n "$MEM" ] && [ "$MEM" -ge 3500000 ]; then pass memory "$((MEM / 1024)) MiB"
else warn memory "${MEM:-?} kB total (4 GiB phone)" "check the memory node and reserved regions in the DT"; fi

# ---------------------------------------------------------------- storage
if [ -e "$DEVD/mmcblk0" ]; then
	pass storage "eMMC mmcblk0 present ($(ls "$DEVD" 2>/dev/null | grep -c '^mmcblk0p') partitions)"
else fail storage "no /dev/mmcblk0" "dmesg | grep -iE 'mmc|sdhci'"; fi
ROOT=$(awk '$2=="/" {print $1}' "$PROC/mounts" 2>/dev/null | tail -1)
[ -n "$ROOT" ] && pass rootfs "mounted from $ROOT" || fail rootfs "no / in /proc/mounts"
FREE=$(df -k / 2>/dev/null | awk 'NR==2 {print $4}')
[ -n "$FREE" ] && { [ "$FREE" -gt 200000 ] && pass rootfs "$((FREE / 1024)) MiB free" || warn rootfs "only $((FREE / 1024)) MiB free"; }
[ -e "$DEVD/mmcblk1" ] && info sdcard "microSD present" || info sdcard "no microSD inserted"

# ---------------------------------------------------------------- USB
UDC=$(ls "$SYS/class/udc" 2>/dev/null | head -1)
[ -n "$UDC" ] && pass usb "UDC $UDC" || fail usb "no USB device controller" "dmesg | grep -iE 'musb|udc'"
BOUND=$(cat "$SYS"/kernel/config/usb_gadget/*/UDC 2>/dev/null | head -1)
[ -n "$BOUND" ] && pass usb "gadget bound to $BOUND" || info usb "no gadget bound (normal after the initramfs hands over without USB networking)"
if [ -e "$SYS/class/net/usb0" ]; then pass usbnet "usb0 present, $(rd "$SYS/class/net/usb0/operstate")"
else info usbnet "no usb0 (no USB network function active)"; fi
n=$(dmcount "wait for vbus off failed")
[ "$n" -eq 0 ] && pass typec "no VBUS timeout messages" || warn typec "$n 'wait for vbus off failed' message(s)" \
	"seen while the cable is toggling or keys are held; matters only if USB networking is unstable"

# ---------------------------------------------------------------- touch and keys
INPUTS=$(rd "$PROC/bus/input/devices")
if printf '%s\n' "$INPUTS" | grep -qi "omnivision_tcm_touch"; then
	pass touch "input device omnivision_tcm_touch registered"
	T=$(awk 'tolower($0) ~ /tcm/ {c=0; for (i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) c+=$i; print c; exit}' "$PROC/interrupts" 2>/dev/null)
	info touch "interrupt count ${T:-unknown} (tap the screen and run again: it must rise)"
else fail touch "no touch input device" "dmesg | grep -iE 'tcm|ovt|hdl'; check firmware $FW/postmarketos/sprd/hdl_firmware_01.img"; fi
if [ -e "$FW/postmarketos/sprd/hdl_firmware_01.img" ]; then pass touch "touch firmware present"
else fail touch "touch firmware missing: $FW/postmarketos/sprd/hdl_firmware_01.img" "install firmware-infinix-x6525 (repo: firmware/hdl_firmware_01.img)"; fi
n=$(dmcount "vddldo0: disabling")
[ "$n" -eq 0 ] && pass touch "touch rail (vddldo0) was not switched off by the 30 s cleanup" || \
	fail touch "vddldo0 was switched off ($n): the controller loses power and its firmware" "boot with regulator_ignore_unused or mark &vddldo0 regulator-always-on"
if printf '%s\n' "$INPUTS" | grep -qiE 'N: Name=.*(key|button|power|volume)'; then
	pass buttons "key input devices: $(printf '%s\n' "$INPUTS" | grep -iE 'N: Name=.*(key|button|power|volume)' | sed 's/N: Name=//' | tr '\n' ' ')"
else fail buttons "no key/power/volume input device" "dmesg | grep -iE 'gpio-keys|pwrkey|eic'"; fi

# ---------------------------------------------------------------- display
if [ -d "$SYS/class/graphics/fb0" ]; then pass display "framebuffer fb0 ($(rd "$SYS/class/graphics/fb0/name"), $(rd "$SYS/class/graphics/fb0/virtual_size"))"
else fail display "no fb0" "dmesg | grep -iE 'simpledrm|drm|framebuffer'"; fi
if [ "$DRM_OFF" = 1 ]; then warn display "the real display driver is switched off (initcall_blacklist=sprd_drm_init); only the bootloader's framebuffer works" "re-enable it once the boot is stable"
else
	[ -e "$DEVD/dri/card0" ] && pass display "DRM card0 present" || fail display "no /dev/dri/card0"
fi
n=$(ls "$SYS/class/backlight" 2>/dev/null | wc -l)
[ "$n" -gt 0 ] && pass backlight "$n backlight device(s)" || skip backlight "none (the panel's brightness is set over DCS by the display driver)"

# ---------------------------------------------------------------- power, thermal
BATT=""
for p in "$SYS"/class/power_supply/*; do
	[ -e "$p/type" ] || continue
	t=$(rd "$p/type")
	if [ "$t" = Battery ]; then
		BATT=$p
		pass battery "$(basename "$p"): $(rd "$p/status"), $(rd "$p/capacity")% , $(( $(rd "$p/voltage_now") / 1000 )) mV"
	else
		info supply "$(basename "$p") ($t) online=$(rd "$p/online")"
	fi
done
[ -n "$BATT" ] || fail battery "no battery power supply" "dmesg | grep -iE 'fgu|sc27xx-fg|battery'"
NZ=0; HOT=""
for z in "$SYS"/class/thermal/thermal_zone*; do
	[ -e "$z/temp" ] || continue
	NZ=$((NZ + 1)); v=$(rd "$z/temp"); [ -n "$v" ] && [ "$v" -gt 70000 ] && HOT="$HOT $(rd "$z/type")=$((v / 1000))C"
done
if [ "$NZ" -eq 0 ]; then warn thermal "no thermal zones" "no protection against overheating"
elif [ -n "$HOT" ]; then warn thermal "$NZ zones, hot:$HOT"
else pass thermal "$NZ zones, none above 70C"; fi

# ---------------------------------------------------------------- wireless
RP=""
for r in "$SYS"/class/remoteproc/*; do
	[ -e "$r/state" ] || continue
	info remoteproc "$(rd "$r/name"): $(rd "$r/state")"
	[ "$(rd "$r/name")" != "" ] && case "$(rd "$r/name")" in *btwf*|*wcn*) RP="$r" ;; esac
done
if [ -e "$SYS/class/net/wlan0" ]; then pass wifi "wlan0 present ($(rd "$SYS/class/net/wlan0/operstate"))"
else
	HINT="dmesg | grep -iE 'wcn|sc23xx|sipc|firmware'"
	MISS=""
	for f in sprd/wcnmodem.bin sprd/wifi_board_config.bin; do [ -e "$FW/$f" ] || MISS="$MISS $f"; done
	if [ -n "$MISS" ]; then fail wifi "no wlan0; firmware missing in $FW:$MISS" "get them from the stock ROM: tools/extract-wcn-firmware.sh"
	elif [ -z "$RP" ]; then fail wifi "no wlan0; no WCN remoteproc" "$HINT"
	else fail wifi "no wlan0; remoteproc state '$(rd "$RP/state")'" "$HINT"; fi
fi
for f in sprd/wcnmodem.bin sprd/wifi_board_config.bin; do
	[ -e "$FW/$f" ] && info wifi "firmware present: $f ($(wc -c < "$FW/$f") bytes)"
done
[ -e "$FW/regulatory.db" ] && info wifi "regulatory.db present" || warn wifi "no $FW/regulatory.db" "install wireless-regdb, or the regdomain stays restricted"
if [ -e "$SYS/class/bluetooth/hci0" ]; then pass bluetooth "hci0 present"
else skip bluetooth "no hci0 (depends on the WCN firmware as Wi-Fi does)"; fi
n=$(dmcount "sc23xx.*(fail|error)|sprd_wcn.*(fail|error)|wcn.*firmware.*(fail|not found)")
[ "$n" -gt 0 ] && warn wifi "$n WCN/sc23xx error line(s) in dmesg" "dmesg | grep -iE 'sc23xx|wcn' | tail -20"

# ---------------------------------------------------------------- other hardware
if [ -s "$PROC/asound/cards" ]; then pass audio "$(head -1 "$PROC/asound/cards" | sed 's/^ *//')"
else fail audio "no ALSA card" "dmesg | grep -iE 'snd|asoc|audio'"; fi
n=$(ls "$SYS/class/leds" 2>/dev/null | wc -l); [ "$n" -gt 0 ] && pass leds "$n LED(s): $(ls "$SYS/class/leds" | tr '\n' ' ')" || warn leds "no LED class devices"
printf '%s\n' "$INPUTS" | grep -qi vibra && pass vibrator "vibrator input device" || warn vibrator "no vibrator device" "module sc27xx-vibra loaded? lsmod | grep vibra"
[ -e "$DEVD/dri/renderD128" ] && pass gpu "render node present" || skip gpu "no render node (GPU driver not enabled on this port)"
n=$(ls "$SYS/bus/iio/devices" 2>/dev/null | wc -l); [ "$n" -gt 0 ] && info sensors "$n IIO device(s)" || skip sensors "no IIO sensors (sensorhub not supported yet)"
ls "$DEVD"/video* >/dev/null 2>&1 && info camera "video devices present" || skip camera "no video devices (camera not supported yet)"
ls "$DEVD"/wwan* "$DEVD"/cdc-wdm* >/dev/null 2>&1 && info modem "WWAN device present" || skip modem "no modem/cellular (not supported yet)"

# ---------------------------------------------------------------- network and services
GW=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')
if [ -n "$GW" ]; then
	pass network "default route via $GW"
	if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
		pass internet "reaches 1.1.1.1"
		ping -c1 -W3 dl-cdn.alpinelinux.org >/dev/null 2>&1 && pass internet "DNS works (dl-cdn.alpinelinux.org)" || fail internet "IP works, name resolution does not" "check /etc/resolv.conf"
	else fail internet "default route set but 1.1.1.1 unreachable" "the uplink may not be forwarding"; fi
else fail network "no default route: no internet" "Wi-Fi: iwctl station wlan0 connect <ssid>; or share one from the USB host"; fi
if command -v rc-status >/dev/null 2>&1; then
	BAD=$(rc-status -a 2>/dev/null | grep -iE 'crashed|stopped' | tr -s ' ' | tr '\n' ';')
	[ -z "$BAD" ] && pass services "no crashed/stopped OpenRC service" || warn services "$BAD"
fi
n=$(dmcount "failed with error|probe of .* failed|error -[0-9]+")
[ "$n" -eq 0 ] && pass drivers "no probe failures logged" || warn drivers "$n probe failure/error line(s)" "dmesg | grep -iE 'probe of .* failed|failed with error' | head"

# ---------------------------------------------------------------- summary
printf '\n' >> "$OUT"; [ "$QUIET" = 0 ] && printf '\n'
emit "====" "" "PASS $NPASS   WARN $NWARN   FAIL $NFAIL"
[ -n "$FAILS" ] && emit "====" "" "failing areas:$FAILS"
[ "$OUT" = /dev/null ] || printf 'report saved to %s\n' "$OUT"
[ "$NFAIL" -eq 0 ]
