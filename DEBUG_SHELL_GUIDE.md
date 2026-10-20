# PostmarketOS Debug Shell & Touch Troubleshooting Guide

This guide covers:
1. How to connect to the debug shell from your host phone (Samsung Galaxy A01 Core).
2. What to do if touch **works**.
3. What to do if touch **does not work** (diagnostic steps & continuing boot).

---

## 1. Connecting from the Host (Galaxy A01 Core with Ubuntu Chroot)

When the Infinix X6525 reaches the debug shell, the screen displays `postmarketOS debug shell` with the `buffyboard` on-screen keyboard.

### Method A: Direct USB Serial Console (Easiest & Most Reliable)
The debug shell automatically starts a serial console getty on the USB gadget (`/dev/ttyGS0`).
On your Galaxy A01 Core (kernel has `CONFIG_USB_ACM=y` built-in), this appears as `/dev/ttyACM0`.

In your Ubuntu chroot terminal on the A01 Core:
```sh
# Make sure /dev is accessible in the chroot
# Connect directly (no network/IP setup needed):
minicom -D /dev/ttyACM0
# Or using microcom / screen / picocom:
microcom -p /dev/ttyACM0
# Or:
screen /dev/ttyACM0 115200
```
Press **Enter** and you will be immediately dropped into the root debug shell!

---

### Method B: USB Network + Telnet (Port 23)
> [!NOTE]
> In the initramfs debug shell, SSH (port 22) is **not running yet** — only **Telnet on port 23** (`172.16.42.1:23`) is listening! SSH starts after `pmos_continue_boot` into the rootfs.

Because Android's `netd` has policy routing rules that drop packets outside Android's default tables, you must bypass netd in the host chroot:

```sh
# 1. Bring up the USB network interface. On the A01 Core's NetHunter kernel it is
#    usb0 (seen with `ip link`); Android leaves it DOWN when the gadget enumerates.
#    Other kernels may name it usbN or enx*.
ip link set usb0 up 2>/dev/null || ip link set usb1 up 2>/dev/null || ip link set eth0 up

# 2. Assign the host IP:
ip addr add 172.16.42.2/24 dev usb0 2>/dev/null || ip addr add 172.16.42.2/24 dev usb1 2>/dev/null || ip addr add 172.16.42.2/24 dev eth0

# 3. Add Android routing bypass rules (CRITICAL for Android host chroots):
ip rule add from all to 172.16.42.0/24 lookup main pref 100
ip rule add from 172.16.42.0/24 lookup main pref 100

# 4. Connect to the debug shell:
telnet 172.16.42.1
```

*(You can also simply run `sh tools/host-watch.sh` in the repository, which does all of the above automatically).*

---

## 2. If Touch DID Work

If the `buffyboard` keyboard responds when you tap the screen:

1. **Verify typing**:
   Tap keys on the on-screen keyboard. You should see characters appear at the terminal prompt on the phone screen.
2. **Continue to the root filesystem**:
   Type `pmos_continue_boot` and hit **Enter** (or run `pmos_continue_boot` via USB).
3. **What happens next**:
   - The initramfs will stop `buffyboard` and `telnetd`.
   - It will mount the root partition (`pmos-root-fs.img` on userdata) to `/sysroot`.
   - It will run `exec switch_root /sysroot /sbin/init`.
   - The system will boot into Alpine/postmarketOS!
4. **Accessing the full system**:
   - Once booted into postmarketOS rootfs, **SSH on port 22** starts automatically.
   - Connect from your host:
     ```sh
     ssh user@172.16.42.1
     ```
     Default password: `x6525pmos`
5. **Making it permanent (booting directly to rootfs without debug shell)**:
   Once you're satisfied, edit `/extlinux/extlinux.conf` in the bootfs (cache partition) and remove `pmos.debug-shell` from the `append` line. Future boots will boot directly into the OS without pausing in the debug shell.

---

## 3. If Touch DID NOT Work, but USB Connected

If touch is unresponsive on the screen, but you connected via `/dev/ttyACM0` or `telnet 172.16.42.1`:

Run these diagnostic commands inside the shell to pinpoint the issue:

### Step 1: Check Driver & SPI Messages
```sh
dmesg | grep -i -E "tcm|spi|touch|ovt"
```

Look for the following common outputs:
- **`touch ready: 720x1612, 10 objects, config id ...`**:
  The kernel driver initialized and loaded firmware successfully! The driver is active. If touch isn't responding in `buffyboard`, go to Step 3 below.
- **`firmware-name is required` or `cannot load ...hdl_firmware_01.img`**:
  Firmware file is missing from `/lib/firmware/postmarketos/sprd/hdl_firmware_01.img`. Verify with:
  ```sh
  ls -l /lib/firmware/postmarketos/sprd/
  ```
- **`no identify report after reset`**:
  The touchscreen controller isn't responding to SPI or IRQ after hardware reset. Check Step 2.
- **`SPI error, spi send timeout` / `spi rx timeout`**:
  SPI controller bus communication issue. Check SPI clock/voltage rail `vddldo0`.

### Step 2: Check Hardware Interrupts & GPIOs
```sh
# Check if touch interrupts are firing:
cat /proc/interrupts | grep -i -E "eic|tcm|spi"

# Touch the screen repeatedly and check again:
cat /proc/interrupts | grep -i -E "eic|tcm|spi"
```
If the interrupt counter increases when you touch the screen, the hardware lines (reset and IRQ) are working.

```sh
# Check regulator rails:
cat /sys/kernel/debug/regulator/regulator_summary | grep -E "vddldo0|vddusb"
```
Ensure `vddldo0` (2.8V touch/panel rail) is `enabled` with `use_count >= 1`.

### Step 3: Check Input Device & Test Touch Events
```sh
# Verify input device registration:
cat /proc/bus/input/devices
ls -l /dev/input/
```
You should see:
```
N: Name="omnivision_tcm_touch"
H: Handlers=eventX
```
`evtest` is not installed in this image. Read the event node directly instead - `od` is a busybox
applet in the initramfs, and the rootfs also has `/usr/bin/hexdump`:

```sh
od -An -tx1 /dev/input/eventX   # replace X; Ctrl-C after touching the screen
```

Bytes appearing while you touch the screen means the driver and hardware are delivering events.

### Step 4: Check or Restart Buffyboard
"The keyboard is on screen" does not mean it is running - `pmos_continue_boot` kills it
(`pkill -f buffyboard`) and fbcon does not repaint the pixels it drew. Check the process first:

```sh
pgrep -a buffyboard
```

- **Nothing listed** - the keyboard is a dead frame. In the rootfs, an image built with `ui = console`
  has no `buffyboard.service`; the tree now selects `ui = buffyboard`. The full explanation and the
  manual start command are in [BRING_UP_CHECKLIST.md](BRING_UP_CHECKLIST.md), section 1.5.
- **A process is listed, but taps do nothing** - the keyboard is live and touch is not reaching it.
  Restart it with verbose logging (the initramfs instance logs errors only):

```sh
pkill -f buffyboard
buffyboard -v >/tmp/bb.log 2>&1 &
sleep 2
grep -iE 'input|fb0|libinput|error|can.t' /tmp/bb.log
```

Two things seen in the initramfs are expected and are not the fault:
`Ignoring invalid config file /usr/share/buffyboard/buffyboard.conf` (and the same for
`/etc/buffyboard.conf`) - neither file is shipped in the initramfs, so buffyboard uses its built-in
defaults - and a `[1]- Done buffyboard` line, which only means the process exited. To see why it
exited, run it in the foreground with `-v`; the log then stays on the terminal.

`New input device: omnivision_tcm_touch` means buffyboard accepted the node; if that line is absent,
the problem is between the driver and udev - the table in BRING_UP_CHECKLIST.md 1.5 says which log
line means what.

### Step 5: Save Log Dump for Investigation
```sh
# View or save the initramfs log:
cat /pmOS_init.log

# Save full dmesg:
dmesg > /pmOS_dmesg.txt

# Export all logs over USB mass storage:
pmos_logdump
```

### Step 6: Continue Boot to Rootfs Anyway
Even if touch did not work in the initramfs, you can proceed into the rootfs and full postmarketOS environment by running:
```sh
pmos_continue_boot
```
Once the rootfs mounts, you can log in over SSH (`ssh user@172.16.42.1`) to inspect the running system.
