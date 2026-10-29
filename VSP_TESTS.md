# Tests for the first ROM with the VSP and JPEG bring-up (kernel patches 0038-0042)

What this build adds: the `AP_VSP` power domain, the `video-codec@32000000` and `jpeg-codec@36000000`
nodes, and `sprd-vsp.ko` (binds both; not loaded automatically; kernel package pkgrel 35 or later). Nothing here decodes video. The goal is to learn whether the block powers
up and answers, and to capture its registers. **Do these over SSH, not on the phone's screen**, and
in this order: the first tests can already tell you the build is not the one you think.

Everything is read-only except test 4 (loading the module), and test 4 is the only one that can hang
the phone. Do it last, with nothing unsaved.

## 0. Is this the right build?
```sh
uname -r
ls /lib/modules/$(uname -r)/kernel/drivers/media/platform/sprd/vsp/ 2>&1
apk info -v linux-postmarketos-unisoc-ums9230 device-infinix-x6525
```
Expect `sprd-vsp.ko*` in the listing and the kernel package at `pkgrel 34` or later. If the file is
missing, the image predates patch 0040: stop and reflash from a newer `rom` run.

## 1. Did the new power domain and node survive boot?
```sh
sudo dmesg | grep -iE 'ap_vsp|power.domain|pmu|genpd' | head -20
ls /proc/device-tree/soc/video-codec@32000000 2>&1 | head
tr '\0' ' ' < /proc/device-tree/soc/video-codec@32000000/compatible; echo
```
Expect no error mentioning `ap_vsp`, and the compatible `sprd,ums9230-vsp`. An error like
`undefined domain id 13` means the pmdomain patch (0038) is not in the running kernel. Everything
else on the phone should behave as before (display, touch, audio): note if anything regressed.

## 2. What the kernel says about the domains and clocks
```sh
sudo cat /sys/kernel/debug/pm_genpd/pm_genpd_summary | grep -iE 'domain|ap_vsp|mm ' | head
sudo grep -iE 'vsp' /sys/kernel/debug/clk/clk_summary
```
Record the state of `ap_vsp` and `mm` (on/off), and the `vsp-clk` / `vsp-eb` rates and enable counts.
Before the module loads, `ap_vsp` is expected to be off (unused domains are switched off at
`late_init`) and `vsp-clk` should show a rate other than 26 MHz only if something configured it.

## 3. A baseline before touching anything
```sh
sudo dmesg | tail -n 5 > /tmp/dmesg-before.txt
cat /proc/interrupts | grep -iE 'vsp|video' ; echo "(none expected yet)"
```

## 4. Load the driver and read the registers (can hang the phone)
```sh
sudo modprobe sprd-vsp; echo "modprobe=$?"
sudo dmesg | grep -iE 'vsp' | tail
sudo cat /sys/kernel/debug/sprd-vsp/regs | tee /tmp/vsp-regs-1.txt
```
Possible outcomes, and what each means:

| Result | Meaning | Send |
|--------|---------|------|
| Probe line `video codec ready`, then 32 rows of `0000: ...` with mixed values | Power, clocks and resets are right; the block answers | `/tmp/vsp-regs-1.txt` |
| Rows are all `ffffffff`, or one constant everywhere | The window is not really enabled (a gate, reset or power step is missing, or the MM domain is off) | the file + test 2 output |
| Structured values somewhere (not one constant), zeros elsewhere | The window answers. The first 0x80 bytes are the IOMMU's registers (seen on the first dump), so those prove power and clock; zeros elsewhere prove nothing by themselves (idle or unimplemented registers). Judge the codec core by the rows at `0x1000`, `0x1028`, `0x8000` | the file |
| `modprobe` fails with `-EPROBE_DEFER` / `failed to get the clocks|resets|power domains` | A DT reference is wrong | the exact `dmesg` line |
| The `cat` hangs, the phone reboots, or the UI freezes | Bus access to an unpowered or ungated block | after the reboot: `sudo dmesg` of the previous boot (`journalctl -k -b -1`), and which line you ran last |

Then read it again, it should be stable:
```sh
sudo cat /sys/kernel/debug/sprd-vsp/regs > /tmp/vsp-regs-2.txt
diff /tmp/vsp-regs-1.txt /tmp/vsp-regs-2.txt && echo "stable across reads"
```
Differences are interesting too (counters, status bits): send both files.

## 4b. The JPEG codec (same module, same risk)
Do this after test 4 has finished without a hang; the JPEG block sits under the MM power domain only.
```sh
sudo dmesg | grep -iE 'jpeg|sprd-jpg' | tail -3
ls /sys/kernel/debug/sprd-jpg/regs
sudo cat /sys/kernel/debug/sprd-jpg/regs | tee /tmp/jpg-regs-1.txt
sudo cat /sys/kernel/debug/sprd-jpg/regs > /tmp/jpg-regs-2.txt; diff /tmp/jpg-regs-1.txt /tmp/jpg-regs-2.txt && echo stable
```
Outcomes are the same as in the table above (real values / all `ffffffff` or zero / hang). A JPEG
block that answers while the VSP does not (or the reverse) is useful: it separates a shared MM
problem from a VSP-only one. Send both register files.

## 5. After the read: did it power down again?
```sh
sleep 6
sudo cat /sys/kernel/debug/pm_genpd/pm_genpd_summary | grep -iE 'ap_vsp|mm '
sudo grep -iE 'vsp' /sys/kernel/debug/clk/clk_summary
```
The driver uses runtime PM: after the read the domain and clocks should be released again (the
domain may stay on briefly). A domain or `vsp-eb` that stays on forever is a leak: note it.

## 6. Does anything else still work? (regression check)
```sh
sudo dmesg | grep -iE 'rcu.*stall|Oops|BUG:|WARNING:' | head
sh tools/check-gpu.sh | tail -3
sh tools/check-idle.sh 10 | tail -3
```
The new power domain is switched on at boot and the MM domain is shared with the camera: if the
camera or the display behaves differently from the previous build, say so.

## What to send back
1. The output of tests 0, 1, 2 and 5 (short).
2. `/tmp/vsp-regs-1.txt`, `/tmp/vsp-regs-2.txt` (test 4) and `/tmp/jpg-regs-1.txt`, `/tmp/jpg-regs-2.txt` (test 4b).
3. `sudo dmesg | grep -iE 'vsp|jpg|jpeg|genpd|ap_vsp'`.
4. If the phone hung: `journalctl -k -b -1 | tail -60` after the reboot.

## What I will do with it
- Registers answer with plausible values: compare offsets `0x1010`, `0x101c`, `0x1028`, `0x8000-0x8024`
  with what the stock library does (`VIDEO_CODEC.md`, "Steps 2-3"), then wire the interrupt (SPI 34)
  and start the bitstream-module experiments.
- Registers dead or the bus hangs: check whether the MM domain needs its own enable, whether the
  `vsp-eb` gate parent ordering matters, and the `vsp-dev-eb-syscon` bit from the stock tree
  (`0x9 0x4 0x20`).
