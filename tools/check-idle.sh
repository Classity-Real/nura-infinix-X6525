#!/bin/sh
# Does CPU idle work now that cpuidle.off=1 is gone, and is the broadcast timer
# (patch 0033) what wakes the CPUs? Run on the phone, ideally after 10+ minutes
# of normal use with the screen on and off, then once more over SSH:
#
#   sh tools/check-idle.sh [seconds]     # default 30 s soak
#
# Read-only. Output is PASS / FAIL / INFO lines and a final VERDICT.
SOAK=${1:-30}
P=0 F=0
pass() { printf 'PASS  %s\n' "$*"; P=$((P + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; F=$((F + 1)); }
info() { printf 'INFO  %s\n' "$*"; }
S=; command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && S='sudo -n'

echo "== command line =="
cl=$(cat /proc/cmdline)
case " $cl " in *" cpuidle.off=1 "*) fail "cpuidle.off=1 is still on the command line: idle is disabled, nothing to test" ;; *) pass "cpuidle.off=1 is not set" ;; esac
case " $cl " in *" cpufreq.off=1 "*) info "cpufreq.off=1 is set: CPUs run at the bootloader's frequency (no DVFS)" ;; *) info "cpufreq is enabled" ;; esac

echo "== idle states =="
i=/sys/devices/system/cpu/cpu0/cpuidle
if [ -d "$i" ]; then
	for s in "$i"/state*; do
		info "$(basename "$s"): $(cat "$s"/name) usage=$(cat "$s"/usage) time=$(cat "$s"/time)us disabled=$(cat "$s"/disable)"
	done
	pass "cpuidle states are registered"
else
	fail "no cpuidle states (driver not bound: check dmesg for psci / cpuidle)"
fi
cat /sys/devices/system/cpu/cpuidle/current_driver /sys/devices/system/cpu/cpuidle/current_governor 2>/dev/null | sed 's/^/      /'

echo "== broadcast timer =="
tl=$(cat /proc/timer_list 2>/dev/null)
bc=$(printf '%s\n' "$tl" | grep -A1 '^Broadcast device' | grep 'Clock Event Device' | head -1)
if [ -n "$bc" ] && ! printf '%s\n' "$bc" | grep -q '<NULL>'; then
	pass "a tick broadcast device exists:${bc#*:}"
	printf '%s\n' "$tl" | grep -A4 '^Broadcast device' | sed 's/^/      /'
else
	fail "no tick broadcast device in /proc/timer_list: CPUs entering a local-timer-stop state have nothing to wake them"
fi
$S dmesg 2>/dev/null | grep -iE 'sprd.*timer|clockevent|arch_timer|broadcast' | tail -6 | sed 's/^/      /'

echo "== stalls so far =="
st=$($S dmesg 2>/dev/null | grep -iE 'rcu.*(stall|self-detected)|rcu_preempt.*starved|blocked for more than|soft lockup|hard LOCKUP|watchdog.*lockup')
if [ -n "$st" ]; then fail "stall / lockup messages in dmesg:"; printf '%s\n' "$st" | tail -8 | sed 's/^/      /'
else pass "no RCU stall or lockup messages in dmesg"; fi

echo "== ${SOAK}s soak: do idle states get used? =="
before=$(cat /sys/devices/system/cpu/cpu*/cpuidle/state*/usage 2>/dev/null | awk '{s+=$1} END{print s+0}')
sleep "$SOAK"
after=$(cat /sys/devices/system/cpu/cpu*/cpuidle/state*/usage 2>/dev/null | awk '{s+=$1} END{print s+0}')
if [ "$after" -gt "$before" ]; then pass "idle entries advanced by $((after - before)) in ${SOAK}s"
else fail "no idle entries in ${SOAK}s"; fi
if $S dmesg 2>/dev/null | grep -qiE 'rcu.*(stall|self-detected)'; then fail "an RCU stall appeared during the soak"; else pass "still no RCU stall"; fi
up=$(cut -d. -f1 /proc/uptime); info "uptime ${up}s; a stall that is going to happen usually shows within a few minutes of idle"

echo
if [ "$F" -eq 0 ]; then echo "VERDICT: idle works and no stalls ($P checks passed)"
else echo "VERDICT: problem ($F failed): if RCU stalled, put cpuidle.off=1 back in kernel-cmdline.conf"; fi
