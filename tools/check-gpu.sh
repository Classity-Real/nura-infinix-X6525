#!/bin/sh
# Is the GPU really doing the work, or is the session on the CPU?
#
#   sh tools/check-gpu.sh            # on the phone, as the normal user
#
# "Compiled in" proves nothing: wlroots/KWin fall back to pixman/llvmpipe
# silently. This script looks for what cannot be faked:
#   1. panfrost bound to the GPU, and the GPU model it found;
#   2. the compositor process holds the render node open and has the Panfrost
#      Mesa driver mapped (software rendering maps LLVM/swrast instead);
#   3. the GPU's job interrupt counter and devfreq state move while you use the UI;
#   4. the GPU clocks left their 26 MHz reset parent (patches 0028/0029).
# It only reads state. sudo is used, when available, for dmesg and clk_summary.
# clk_summary columns are: clock enable prepare protect rate accuracy phase duty.
# Every line is PASS, FAIL or INFO; a final VERDICT line sums it up.

R=0 F=0
pass() { printf 'PASS  %s\n' "$*"; R=$((R + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; F=$((F + 1)); }
info() { printf 'INFO  %s\n' "$*"; }
S=; command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && S='sudo -n'
[ -n "$S" ] || [ "$(id -u)" = 0 ] || info "no passwordless sudo: run 'sudo -v' first for the dmesg and clock checks"

echo "== 1. Panfrost bound to the GPU =="
if lsmod 2>/dev/null | grep -q '^panfrost'; then pass "panfrost module loaded"
else fail "panfrost module not loaded (modprobe panfrost)"; fi
dm=$($S dmesg 2>/dev/null | grep -iE 'panfrost|mali' | tail -12)
if [ -n "$dm" ]; then printf '%s\n' "$dm" | sed 's/^/      /'; fi
case "$dm" in
*"Unknown GPU"*|*"unknown GPU"*) fail "Panfrost does not know this GPU id (needs a GPU_MODEL entry)" ;;
*"failed"*|*"error"*) fail "Panfrost reported an error (see above)" ;;
*"mali-g57"*|*"Mali-G57"*|*"mali-g"*) pass "Panfrost identified the GPU" ;;
*) info "no Panfrost line in dmesg (need sudo, or the ring buffer wrapped)" ;;
esac
render=
for n in /sys/class/drm/renderD*; do
	[ -e "$n" ] || continue
	d=$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)")
	info "$(basename "$n") -> driver $d"
	[ "$d" = panfrost ] && render=/dev/dri/$(basename "$n")
done
[ -n "$render" ] && pass "render node $render belongs to panfrost" || fail "no render node owned by panfrost"

echo "== 2. The compositor really uses it =="
cp=
for p in phoc kwin_wayland; do
	pid=$(pgrep -o "$p" 2>/dev/null) && [ -n "$pid" ] && { cp=$p; break; }
done
if [ -z "$cp" ]; then
	fail "no phoc or kwin_wayland process (is the session running? run this over SSH while logged in)"
else
	info "compositor: $cp (pid $pid)"
	fds=$($S ls -l /proc/"$pid"/fd 2>/dev/null)
	maps=$($S cat /proc/"$pid"/maps 2>/dev/null)
	[ -n "$maps" ] || info "cannot read /proc/$pid/maps (run with sudo)"
	if printf '%s\n' "$fds" | grep -q 'renderD'; then pass "$cp holds a render node open"
	else fail "$cp holds NO render node: it is composing on the CPU (pixman/QPainter) or on the display card only"; fi
	if printf '%s\n' "$maps" | grep -qE 'panfrost_dri|libgallium|kmsro_dri|libvulkan_panfrost'; then pass "$cp has the Mesa Panfrost/gallium driver mapped"
	elif [ -n "$maps" ]; then fail "no Panfrost Mesa driver mapped in $cp"; fi
	if printf '%s\n' "$maps" | grep -qE 'libLLVM|swrast|llvmpipe|libvulkan_lvp|lvp_icd'; then fail "$cp has LLVM/swrast mapped: software rendering is in use"
	elif [ -n "$maps" ]; then pass "no LLVM/swrast in $cp"; fi
	env=$($S tr '\0' '\n' < /proc/"$pid"/environ 2>/dev/null | grep -E '^(WLR_|KWIN_|LIBGL_|GSK_|MESA_|EGL_)')
	[ -n "$env" ] && printf '%s\n' "$env" | sed 's/^/      env /'
	case "$env" in
	*WLR_RENDERER=pixman*|*LIBGL_ALWAYS_SOFTWARE=1*|*KWIN_COMPOSE=Q*) fail "a software-rendering variable is set (above)" ;;
	esac
fi
j=$(journalctl -b --no-pager 2>/dev/null | grep -iE 'renderer|gles2|pixman|vulkan' | tail -5)
[ -n "$j" ] && { info "compositor renderer log:"; printf '%s\n' "$j" | sed 's/^/      /'; }
if command -v eglinfo >/dev/null 2>&1; then
	e=$(eglinfo -B 2>/dev/null | grep -iE 'OpenGL (core )?(profile )?renderer|OpenGL ES profile renderer' | head -3)
	[ -n "$e" ] && printf '%s\n' "$e" | sed 's/^/      /'
	case "$e" in *llvmpipe*) fail "Mesa clients get llvmpipe" ;; *Mali*|*Panfrost*) pass "Mesa clients get Panfrost" ;; esac
fi

echo "== 3. The GPU does work while the UI moves =="
irq() { awk '/panfrost|mali/ && /job|gpu|mmu/ {for(i=2;i<NF;i++) if ($i ~ /^[0-9]+$/) s+=$i} END{print s+0}' /proc/interrupts; }
dev=$(ls -d /sys/class/devfreq/*gpu* 2>/dev/null | head -1)
a=$(irq)
if [ -n "$dev" ]; then
	info "devfreq: $(basename "$dev") governor $(cat "$dev"/governor 2>/dev/null), available $(cat "$dev"/available_frequencies 2>/dev/null)"
	f0=$(cat "$dev"/cur_freq 2>/dev/null)
else
	fail "no GPU devfreq device (no OPP table, or Panfrost not bound)"
fi
echo "      for the next 6 s: swipe the shade up and down / scroll an app / run a video"
mx=0; i=0
while [ "$i" -lt 12 ]; do
	[ -n "$dev" ] && { f=$(cat "$dev"/cur_freq 2>/dev/null); [ "${f:-0}" -gt "$mx" ] && mx=$f; }
	sleep 0.5; i=$((i + 1))
done
b=$(irq)
d=$((b - a))
if [ "$d" -gt 20 ]; then pass "GPU interrupts advanced by $d in 6 s"
elif [ "$d" -gt 0 ]; then info "GPU interrupts advanced only $d: barely used; scroll more and re-run"
else fail "GPU interrupts did not move: nothing is being rendered on the GPU"; fi
[ -n "$dev" ] && info "GPU frequency: ${f0:-?} Hz at start, highest seen ${mx} Hz"
[ -n "$dev" ] && [ "$mx" -gt 384000000 ] 2>/dev/null && pass "devfreq scaled above the lowest OPP" ||
	{ [ -n "$dev" ] && info "devfreq never left the lowest OPP (normal if the UI is light)"; }

echo "== 4. GPU clocks left their 26 MHz reset parent =="
cs=$($S cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -iE 'gpu')
if [ -z "$cs" ]; then info "clk_summary not readable (needs root and debugfs)"
else
	printf '%s\n' "$cs" | sed 's/^/      /'
	printf '%s\n' "$cs" | grep -iE 'gpu.*(core|mem)' | awk '{ if ($(NF-3)+0 > 0 && $(NF-3)+0 <= 26000000) bad=1 } END{exit bad}' &&
		pass "GPU core/mem clocks run above 26 MHz" || fail "a GPU clock is still at <= 26 MHz (patches 0028/0029 not effective)"
fi

echo "== 5. Faults =="
f=$($S dmesg 2>/dev/null | grep -iE 'panfrost.*(fault|timeout|error|reset)|gpu sched timeout|iommu.* fault' | tail -5)
[ -n "$f" ] && { fail "GPU faults in dmesg:"; printf '%s\n' "$f" | sed 's/^/      /'; } || pass "no GPU faults in dmesg"

echo
if [ "$F" -eq 0 ]; then echo "VERDICT: the GPU is in use ($R checks passed)"
else echo "VERDICT: NOT fully accelerated ($F failed, $R passed): read the FAIL lines above"; fi
