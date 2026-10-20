# Bring-up checklist: touch, Wi-Fi, then GUI

What to run after flashing a ROM build, and what each result means. Work in this order: each step
needs the one before it. Everything here runs in the initramfs debug shell (USB serial on the host,
`minicom -D /dev/ttyACM0`, or telnet `172.16.42.1`) or over SSH once booted.

Flash `boot_a`, `cache` and `userdata` from the **same** ROM run. Keep the stock `boot.img` backup off
the phone (see FIRST_BOOT.md, "Recovery").

## 1. Touch

Status on 2026-10-20: the controller answers. The driver downloads the firmware, the SPI path works,
and it registers the input device:

```
input: omnivision_tcm_touch as .../spi0.0/input/input2
omnivision_tcm_spi spi0.0: touch ready: 5759x12895, 5 objects, config id
```

That boot had it as `event2`. The interrupt is not the blocker: `/proc/interrupts` shows
`sprd-eic 16 Level ovt-tcm`, and its count went 1050 -> 1166 -> 1610 across the session, so the
controller asserts and the driver's threaded handler runs. What is still unknown is whether the
handler turns those interrupts into input events - the event node has not been read successfully yet
(both attempts used the literal `/dev/input/eventN`). Use the block in 1.1, which derives the node
from `Handlers=`.

A count that also rises while nobody touches would mean the controller keeps sending reports (or
re-asserts the line); the `od` result says which of them reach userspace.

### 1.1 The test

In the debug shell:

```sh
ls /dev/input
grep -A4 omnivision /proc/bus/input/devices
dmesg | grep -iE "tcm|ovt|vddldo0|regulator"
grep -iE "ovt-tcm|eic" /proc/interrupts

# let the command pick the event node from the Handlers= line, so a literal
# "eventN" cannot be read by mistake
node=$(grep -A4 -i omnivision /proc/bus/input/devices |
       sed -n 's/.*Handlers=\(event[0-9]*\).*/\1/p')
echo "reading /dev/input/$node"                # must be event<number>, not empty
timeout 10 od -An -tx1 -v "/dev/input/$node"   # touch the screen during these 10 s

grep -iE "ovt-tcm|eic" /proc/interrupts
```

`buffyboard` (the on-screen keyboard) is not the test: it can ignore a device that appeared after it
started. The `od` output is the test. Replace `eventN` with the number from `Handlers=eventN` -
`eventN` as written is not a file. (`od` is a busybox applet; the rootfs also has `/usr/bin/hexdump`.)

The IRQ action is registered as **`ovt-tcm`** (`devm_request_threaded_irq(..., "ovt-tcm", ...)` in
`drivers/ovt-tcm-spi.c`); `omnivision` is the input device's name, not the interrupt's. A
`grep omnivision /proc/interrupts` that prints nothing therefore proves nothing.

### 1.2 If events appear (touch works)

1. The driver and the hardware are fine. If `buffyboard` still ignores the screen, restart it:
   `killall buffyboard; buffyboard &`. If that makes the keyboard work, the cause is start order
   (`buffyboard` starts before the module has created the device). Tell the maintainer; the fix is in the
   initramfs, not the driver.
2. Run `pmos_continue_boot`, log in over SSH, and run `sudo sh phone-audit.sh` (from `tools/`). The touch
   lines should be PASS, including the line that checks the rail is still on after 60 s.
3. Wait two minutes and run the `hexdump` again. Touch dying after ~30-40 s means `vddldo0` was switched
   off: check `cat /sys/class/regulator/*/name` against `.../state` and that the cmdline still has
   `regulator_ignore_unused`.
4. Save the numbers: `dmesg | grep "touch ready"` (the stock reports `5759x12895`, 8 x the panel's pixels;
   the compositor scales it).
5. Move on to section 2.

### 1.3 If no events appear

Find which row matches. `touch ready` is the driver's line printed after the chip has booted and its
report config is set.

| What you see | Meaning | Next |
|---|---|---|
| No `touch ready` line, firmware error (`firmware`, `-2`) | the HDL image is missing | `ls /lib/firmware/postmarketos/sprd/` in the debug shell (it must be in the initramfs) and `ls /usr/share/mkinitfs/files/`. Send both. |
| No `touch ready`, SPI errors or repeated `Incorrect header marker` | chip not answering | one such line at the first read is normal (stock prints it too). Repeated means reset or rail: send the `dmesg` lines and `cat /sys/class/regulator/*/name`. |
| `touch ready` but the interrupt count is 0 and stays 0 when touching | the interrupt line is not arriving | the stock system uses `eic_async` line 16, level-low, as `omnivision_tcm`, and so do we. Send `/proc/interrupts` in full and `dmesg \| grep -i eic`. |
| `touch ready`, interrupt count rises, but `hexdump` is empty | the driver reads reports but does not deliver them | send the full `dmesg` and `cat /proc/bus/input/devices`. The driver has no extra debug output, so this case needs a debug build from the maintainer. |
| `touch ready` appears, then touch stops after 30-40 s | the 2.8 V rail was cut | `vddldo0` must be always-on (device tree) and `regulator_ignore_unused` must be on the cmdline. Send `cat /proc/cmdline`. |

Always send, whichever row: the output of the 1.1 commands, and the first 100 lines of `dmesg`.

### 1.4 Meanwhile, without touch

The phone is fully usable from the host: serial console `minicom -D /dev/ttyACM0`, and SSH
(`ssh user@172.16.42.1`, password `x6525pmos`) after boot. Touch is only needed for the GUI.

### 1.5 The keyboard appears but does not respond

"The keyboard is on screen" and "the keyboard is running" are different things. Check first:

```sh
pgrep -a buffyboard
```

| `pgrep` | What it is | What to do |
|---|---|---|
| nothing | a dead frame. `buffyboard` drew the keyboard, then `pmos_continue_boot` ran `pkill -f buffyboard` (`postmarketos-initramfs`, `init_functions.sh:1219`); fbcon repaints only the rows something writes, so the keyboard stays on screen with nothing behind it. | the rootfs, not touch - see below |
| a `buffyboard` process | the keyboard is live and touch is not reaching it | restart it with verbose logging (the initramfs instance logs errors only) and read what it does with the input device |

If nothing is listed, the process was killed at switch_root and no service restarted it. An image
built with `ui = console` has no buffyboard service - it is shipped by `postmarketos-ui-buffyboard` -
while `rom.yml` now selects `ui = buffyboard`, which installs it and enables it (the systemd unit via
`postmarketos-base`'s preset; on an OpenRC image the UI's openrc subpackage adds the script to the
default runlevel). `rom.yml` also pins `service_manager = systemd`, because the UI package defaults
to OpenRC and the init system would otherwise change with the UI. Until that image is flashed, start
it by hand over SSH as `user`; it draws on the console and injects keys there, so an SSH session is
enough:

```sh
sudo sh -c 'r=$(cat /sys/class/graphics/fbcon/rotate 2>/dev/null || echo 0); \
  modprobe uinput 2>/dev/null; \
  nohup /usr/bin/buffyboard -r "$r" </dev/null >/tmp/buffyboard.log 2>&1 &'
```

If a process is listed, restart it with verbose logging and read what it does with the input device:

```sh
pkill -f buffyboard
buffyboard -v >/tmp/bb.log 2>&1 &
sleep 2
grep -iE 'input|fb0|libinput|error|can.t' /tmp/bb.log
```

`buffyboard` reads touches through libinput and accepts a device only after udev has tagged it
(`ID_INPUT_TOUCHSCREEN=1`). What the log says:

| Line in `/tmp/bb.log` | Meaning | Next |
|---|---|---|
| `New input device: omnivision_tcm_touch` | buffyboard took the node | if taps still do nothing, events are not arriving: 1.1's `od` test and the interrupt count in 1.3 |
| `... is not an input device` | udev has no `ID_INPUT=1` for it | `udevadm info -q property -n /dev/input/eventN`; send that with `ls -l /dev/input/` |
| `libinput can't use /dev/input/eventN` | libinput refused the node | send the line with `cat /proc/bus/input/devices` |
| `Key ... is ignored`, `Keyboard ... is ignored` | it is a key device, not touch | correct for this board; not the keyboard's problem |
| `/dev/fb0 is not available` | display, not touch | the boot lost the framebuffer early; send `dmesg` |

Tap the screen, then:

```sh
tail -20 /tmp/bb.log
pgrep -a buffyboard
```

Read it together with the `od` result from 1.1:

| `od` on the event node | `bb.log` | Meaning |
|---|---|---|
| bytes | `New input device: omnivision_tcm_touch` | touch and buffyboard are both fine; the fault is in buffyboard's hit-testing |
| bytes | no line for the device | udev/libinput did not hand it over; the log's warning says why |
| nothing, while the `ovt-tcm` IRQ count rises | - | the handler reads the controller but `tcm_report_touch()` emits nothing; that needs a debug print in the driver |
| nothing, IRQ count static | - | the IRQ is not arriving; see 1.3 |
| - | `pgrep` empty | it exited; the last log lines say why |

If no line mentions the touch device, it never reached udev: use `/proc/bus/input/devices` and the
`dmesg` output from 1.1 to find out whether the driver got to `touch ready`.

### 1.6 Copy-paste: the remaining measurements

These two reads decide between the driver and buffyboard. Run them in the debug shell.

```sh
node=$(grep -A4 -i omnivision /proc/bus/input/devices | sed -n 's/.*Handlers=\(event[0-9]*\).*/\1/p')
echo "node=$node"
timeout 10 od -An -tx1 -v "/dev/input/$node"   # touch and drag during these 10 s
```

```sh
pkill -f buffyboard
buffyboard -v >/tmp/bb.log 2>&1 &
sleep 3
grep -iE 'New input device|not an input|libinput|fb0|error|can.t' /tmp/bb.log
# tap the screen, then:
tail -20 /tmp/bb.log
pgrep -a buffyboard
```

`od` bytes + `New input device: omnivision_tcm_touch` = buffyboard's hit-testing. No `od` bytes while
the `ovt-tcm` IRQ count still rises = the driver's report path. An empty `pgrep` = buffyboard exited;
the tail of the log says why.

## 2. Wi-Fi

Built in (a Unisoc WCN with a mainline `sc23xx` driver); nothing to plug in. It needs
`/lib/firmware/sprd/wcnmodem.bin` and `/lib/firmware/sprd/wifi_board_config.bin` (the package
`firmware-infinix-x6525`; the config is converted from the stock `.ini` by `tools/wifi-ini2bin.py`).

```sh
ls -l /lib/firmware/sprd/
lsmod | grep -E "sprd_wcn|sc23xx"
dmesg | grep -iE "wcn|sc23xx|sprd_wcn|wlan|rproc|firmware"
ip link
```

| What you see | Meaning | Next |
|---|---|---|
| `wlan0` exists | firmware and config loaded | `nmcli device wifi list`, then `nmcli device wifi connect SSID password PASS`. Check `cat /sys/class/net/wlan0/address` is not all zeroes (the device package sets a random one). |
| no `sprd/wcnmodem.bin` in `ls` | the firmware package did not get installed | send `apk info -L firmware-infinix-x6525`. |
| `firmware too large` / `rproc` errors | the modem image does not fit or the region is wrong | send the `dmesg` lines. |
| remoteproc starts but no `wlan0`, `failed to download config section N` | the WLAN firmware rejected a section | note N. `CRC_ERROR` means the checksums in `wifi_board_config.bin` are not what the firmware expects; any other error with N means the section layout is off. Send the lines. |
| modules not loaded | autoload failed | `modprobe sprd_wcn; modprobe sc23xx_wlan_sipc`, then repeat, and send the output. |

The firmware layout of `wifi_board_config.bin` was reconstructed from the stock `sprd_wlan_combo.ko`
and has not been run on the hardware yet; a failure here is expected to be informative, not final.

Internet over the USB link (docs in README.md) keeps working as before and is the fallback.

## 3. GUI

Needs 1 (touch) and a stable boot. In order:

1. Touch works (section 1) and the boot is stable with the debug options as they are.
2. Remove debug options one at a time, re-testing each: first `cpuidle.off=1` and `cpufreq.off=1` (find
   which one stalls the CPUs; see FIRST_BOOT.md), then `initcall_debug`/`ignore_loglevel`.
3. Re-enable the real display driver (drop `initcall_blacklist=sprd_drm_init`). Risky: if it fails the
   screen goes black. Do it in its own build with the recovery route at hand.
4. Switch `ui = console` to `ui = phosh` in `.github/workflows/rom.yml` and build. No GPU driver is known to
   work yet, so expect software rendering (`LIBGL_ALWAYS_SOFTWARE=1`).

## What to send when asking for help

- Which step and which row of the tables above you are on.
- The exact command output (paste text; a photo is fine for the screen).
- The ROM run number you flashed, and whether `boot_a`, `cache` and `userdata` all came from it.
