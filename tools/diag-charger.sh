#!/bin/sh
# Record charger and USB state around a plug-in, to explain slow charging and
# the "unknown USB mode/modem" message that appears after plugging in.
#
#   sh tools/diag-charger.sh [seconds] [interval]      # default 90 s, every 2 s
#
# Start it with the charger UNPLUGGED, then plug the charger in a few seconds
# later and wait for the message. It writes ~/diag-charger-<date>.txt. Read
# only; the sudo password is asked once (dmesg needs it).
#
# What it records every interval: the USB-C port's roles, the USB gadget (UDC)
# state, every power_supply's status/online/current/voltage/temperature, and
# the AW32257/bq24158 charger's own mode, input limit, charge current and
# registers. Alongside it: kernel messages, udev events and the user journal.

DUR=${1:-90}
STEP=${2:-2}
OUT=$HOME/diag-charger-$(date +%Y%m%d-%H%M%S).txt
T=$(mktemp -d)

sudo -v 2>/dev/null || echo "note: no sudo, kernel messages will be missing" >&2

rd() { [ -r "$1" ] && cat "$1" 2>/dev/null || echo "-"; }

snap() {
	printf '\n--- t=%ss ---\n' "$1"
	for f in data_role power_role power_operation_mode vconn_source; do
		printf 'typec/port0/%s: %s\n' "$f" "$(rd /sys/class/typec/port0/$f | tr '\n' ' ')"
	done
	for u in /sys/class/udc/*; do [ -d "$u" ] && printf 'udc %s: %s\n' "${u##*/}" "$(rd "$u/state")"; done
	for r in /sys/class/usb_role/*; do [ -d "$r" ] && printf 'usb_role %s: %s\n' "${r##*/}" "$(rd "$r/role")"; done
	for p in /sys/class/power_supply/*; do
		[ -d "$p" ] || continue
		printf '%s:' "${p##*/}"
		for k in type status online present current_now current_max voltage_now temp capacity; do
			[ -r "$p/$k" ] && printf ' %s=%s' "$k" "$(cat "$p/$k" 2>/dev/null)"
		done
		echo
		for k in mode reported_mode current_limit charge_current termination_current \
			charge_status fault_status boost_status; do
			[ -r "$p/$k" ] && printf '  %s=%s\n' "$k" "$(cat "$p/$k" 2>/dev/null | tr '\n' ' ')"
		done
		[ -r "$p/registers" ] && printf '  registers: %s\n' "$(cat "$p/registers" 2>/dev/null | tr '\n' ' ')"
	done
	for z in /sys/class/thermal/thermal_zone*; do
		[ -r "$z/type" ] && printf 'thermal %s=%s\n' "$(cat "$z/type")" "$(cat "$z/temp" 2>/dev/null)"
	done | grep -iE 'board|chg|pa-|battery' 
}

# background recorders, each line stamped with seconds since start
S0=$(date +%s)
stamp() { while IFS= read -r l; do printf '[%3ss] %s\n' "$(( $(date +%s) - S0 ))" "$l"; done; }
sudo -n dmesg -w 2>/dev/null | stamp > "$T/dmesg" &
P1=$!
udevadm monitor --udev --kernel -s usb -s typec -s power_supply -s udc -s usb_role 2>/dev/null | stamp > "$T/udev" &
P2=$!
journalctl -f -n0 --no-pager 2>/dev/null | stamp > "$T/journal" &
P3=$!

echo "recording ${DUR}s: plug the charger in now, then wait for the message ..."
t=0
: > "$T/snaps"
while [ "$t" -le "$DUR" ]; do
	snap "$t" >> "$T/snaps"
	sleep "$STEP"
	t=$((t + STEP))
done

kill "$P1" "$P2" "$P3" 2>/dev/null
# $! is the stamping subshell, so stop the readers themselves as well
pkill -f 'journalctl -f -n0' 2>/dev/null
pkill -f 'udevadm monitor' 2>/dev/null
sudo -n pkill -f 'dmesg -w' 2>/dev/null
sleep 1

{
	echo "x6525 charger diagnostics, $(date), kernel $(uname -r)"
	echo "interval ${STEP}s, duration ${DUR}s (plug-in time is where online=1 first appears)"
	echo; echo "==== SNAPSHOTS ===="; cat "$T/snaps"
	echo; echo "==== KERNEL (dmesg -w) ===="; cat "$T/dmesg"
	echo; echo "==== UDEV EVENTS ===="; cat "$T/udev"
	echo; echo "==== JOURNAL ===="; cat "$T/journal"
	echo; echo "==== TYPEC / USB DRIVERS ===="
	sudo -n dmesg 2>/dev/null | grep -iE 'typec|tcpm|sc27xx|musb|bq2415x|usb.*(role|mode|gadget)|extcon|unknown' | tail -40
	echo; echo "==== USB GADGET FUNCTIONS ===="
	for g in /sys/kernel/config/usb_gadget/*; do
		[ -d "$g" ] && { echo "$g: UDC=$(rd "$g/UDC")"; ls "$g/functions" 2>/dev/null; }
	done
} > "$OUT" 2>&1

rm -rf "$T"
echo "wrote $OUT ($(wc -l < "$OUT") lines)"
