# Bring-up checklist: touch, Wi-Fi, then GUI

What to run after flashing a ROM build, and what each result means. Work in this order: each step
needs the one before it. Everything here runs in the initramfs debug shell (USB serial on the host,
`minicom -D /dev/ttyACM0`, or telnet `172.16.42.1`) or over SSH once booted.

Flash `boot_a`, `cache` and `userdata` from the **same** ROM run. Keep the stock `boot.img` backup off
the phone (see FIRST_BOOT.md, "Recovery").

## 1. Touch

### 1.1 The test

In the debug shell:

```sh
ls /dev/input
grep -A4 omnivision /proc/bus/input/devices          # note the eventN handler
dmesg | grep -iE "tcm|ovt|vddldo0|regulator"
grep -i omnivision /proc/interrupts                  # note the count
cat /dev/input/eventN | hexdump -C                   # now touch the screen; Ctrl-C to stop
grep -i omnivision /proc/interrupts                  # count again
```

`buffyboard` (the on-screen keyboard) is not the test: it can ignore a device that appeared after it
started. The `hexdump` is the test.

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
