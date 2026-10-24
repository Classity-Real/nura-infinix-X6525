# Diagnostics for the black-screen regression

These files are **test artifacts**, not a release. They were built from the same inputs as ROM run
`40100231867` and differ from it in exactly one thing each; nothing per-unit is in them.

| File | What it changes |
|---|---|
| `boot-no-preboot.img` | the final `boot.img` with the U-Boot from build run `40097639694` (before the prodnv MAC preboot). Flash it to `boot_a` only. |
| `ums9230-infinix-x6525-nohog.dtb` | the final DTB with the front camera's `ov8856-pwdn-hog` node removed. Inject it into the boot filesystem. |

Use them one at a time and put the final image back afterwards (`fastboot flash boot_a boot.img`,
`fastboot flash cache pmos-boot-fs.img`).

## First: does the kernel run?

The bootloader logo staying on screen can mean two different things: the kernel never started, or it
started but its display driver never took over. The USB link tells them apart.

On the host:

```sh
ip link                    # does a new usb0/usb1 interface appear?
ping -c2 172.16.42.1
ssh user@172.16.42.1       # password: x6525pmos
```

Also note whether the phone reboots by itself about every five minutes. `bootcmd` starts with
`pmicwdt stop`; if U-Boot hangs before that, the PMIC watchdog resets the phone.

## If SSH does not work: the kernel never started

Flash the no-preboot U-Boot:

```sh
fastboot flash boot_a diagnostics/boot-no-preboot.img
```

- If the kernel now boots and the screen works, the prodnv preboot is the cause. Tell me the U-Boot
  output and keep this image for now.
- If the screen is still the logo, the preboot is not the cause. Move to the DTB test below.

## If SSH works: the kernel runs, the display does not

Send me these first:

```sh
sudo dmesg | grep -iE 'gpio|hog|panel|td4160|dsi|dpu|drm|backlight|pmsys|sdhci'
ls -l /sys/class/drm /sys/class/backlight
systemctl status x6525-pmsys x6525-modem-nv
journalctl -u x6525-pmsys -b --no-pager
```

Then try the two firmware services first, because they run late and are the riskiest new code. Make a
copy of the boot filesystem and mask both units for this boot:

```sh
cp pmos-boot-fs.img test-bootfs-mask.img
sh tools/patch-cmdline.sh test-bootfs-mask.img \
    "systemd.mask=x6525-modem-nv.service systemd.mask=x6525-pmsys.service"
fastboot flash cache test-bootfs-mask.img
```

- If the display comes back, one of the two firmware loaders is the cause. Mask only one at a time to
  find which, and send that service's journal.
- If it does not, replace the DTB with the no-hog one:

```sh
cp pmos-boot-fs.img test-bootfs-nohog.img
debugfs -w -R "rm /ums9230-infinix-x6525.dtb" test-bootfs-nohog.img
debugfs -w -R "write diagnostics/ums9230-infinix-x6525-nohog.dtb /ums9230-infinix-x6525.dtb" \
    test-bootfs-nohog.img
debugfs -R "dump /ums9230-infinix-x6525.dtb /tmp/check.dtb" test-bootfs-nohog.img
cmp /tmp/check.dtb diagnostics/ums9230-infinix-x6525-nohog.dtb
fastboot flash cache test-bootfs-nohog.img
```

`extlinux.conf` boots the DTB at `/ums9230-infinix-x6525.dtb` (the copy under `/dtbs/` is not used).
The `cmp` must print nothing; only then flash.

- If the display returns without the hog, the front camera's power-down pin is the cause and the hog
  stays out of the default build until the sensor driver drives it itself.
- If neither test helps, send the `dmesg` lines and the DRM state; the panel/DSI side is next.
