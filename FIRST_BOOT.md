# First boot of the mainline port

This is the checklist for the **mainline route** (U-Boot chainloaded from `boot_a`, then the
`linux-postmarketos-unisoc-ums9230` kernel with `dts/ums9230-infinix-x6525.dts`; the boot filesystem
goes in the UFS `cache` partition and the root filesystem in `userdata`, or both on a microSD card
instead). The 5.4 route has its own steps at the end of `NOTES.md`. **Where the bring-up is:** the
boot chain, the rootfs, SSH over the USB link, the touchscreen and Wi-Fi all work (Wi-Fi verified
2026-10-21 by pinging, running `apk update`/`upgrade` and installing a package), and a GUI image
boots (Phosh, 2026-10-24; the workflow's `ui` input now picks the interface
phosh/plasma-mobile/buffyboard, see BRING_UP_CHECKLIST 3). Bluetooth is fixed in the tree - the transport's two
configuration blobs are now packaged, and kernel patch 0013 supplies a BD address where U-Boot's
`bdaddr` environment variable is unset and it writes zeros - but has not been exercised on the phone
yet; BRING_UP_CHECKLIST.md 2.1 has the checks. Stages
below that have not been exercised describe what the sources say should happen, so a deviation there
is information, not necessarily a bug in this list.

The order matters. Each stage is only worth looking at once the one before it passes, and every stage
ends with where to look if it fails.

## Building the ROM

Everything the ROM needs is in this repository, and none of it waits on a merge:

```sh
cp -r pmaports/device/testing/{device-infinix-x6525,linux-postmarketos-unisoc-ums9230,u-boot-infinix-x6525,firmware-infinix-x6525} \
    <pmaports>/device/testing/
pmbootstrap init          # the device is offered under "infinix" once it is in the tree
pmbootstrap install
pmbootstrap export        # writes /tmp/postmarketOS-export/
```

`linux-postmarketos-unisoc-ums9230/` here is the kernel package with this port's twenty-seven patches in
`source=` and its five config symbols added (the reasoning is in `pmaports/README.md`), and the
u-boot package builds from the port's fork, so the `boot.img` in the export is already this board's.

`firmware-infinix-x6525` is the touch firmware, and it belongs in that copy too: the package fetches
its tarball out of this repository, which is public, so `install` gets it and the controller has what
it needs. If it ever fails to fetch, the same file sits in `firmware/` and can be dropped into
`/lib/firmware/postmarketos/sprd/` by hand.

The rest of this file is the flash procedure and then the boot, stage by stage. Only one write goes
into the phone's own storage - U-Boot, into `boot_a`; the rootfs is written to a microSD card.

## Building it on GitHub instead

`.github/workflows/ci.yml` runs the same build on an arm64 runner — Actions → **Build PMOS** → *Run
workflow*, with `run_firmware` left unchecked — and leaves an artifact called `x6525-rom` with the
kernel, U-Boot and the rootfs image in it. It clones pmbootstrap and pmaports itself and copies these
four packages over them, so there is nothing to prepare and nothing to install locally. The image's
user password is `x6525pmos`.

The run's **ui** input picks the interface the image boots into: `phosh` (the default mobile UI),
`plasma-mobile` (KDE) or `buffyboard` (a console with an on-screen keyboard). `rom.yml` is a disabled
stub that only records the defaults (`ui = phosh`, `service_manager = systemd`) for the audit tool.

Arm64 on purpose: on x86_64 every kernel build goes through qemu-user, which turns twenty minutes
into hours. `pmbootstrap init` asks its questions on stdin and cannot run unattended, so the workflow
writes the config file init would have written and points pmbootstrap at it with `--config`.

## 0. Before flashing anything

- Back up `boot_a` and, to be safe, `boot_b`, `vendor_boot_a`, `dtbo_a` and `vbmeta_a`. Only `boot_a` is
  overwritten by this port, but a known-good set makes every later step reversible. Keep a copy *off*
  the phone as well: `boot.img.xz` in Downloads is the same image at 16 MB, and the only other copy
  lives on the device being flashed. Note that a plain reboot does **not** go back to Android once
  `boot_a` holds U-Boot - restoring the image is what does that.
- `fastboot getvar current-slot` - the port flashes the *current* slot. The only eMMC write is the
  boot image, to `boot_a`; the rootfs goes to a microSD card (see [Flashing](#flashing)), so Android
  and its data are left alone.
- **How to take that backup** - the stock fastboot cannot read partitions, so use one of: a rooted Android
  (`adb shell su -c 'dd if=/dev/block/by-name/boot_a of=/sdcard/boot_a.img'`, same for the others), or
  `spd_dump` in download mode (`read_part boot_a 0 <size> boot_a.img`). Check the file is the partition's
  full size and starts with `ANDROID!`. Without any backup, the stock firmware package's `boot.img` for this
  exact build is the only way back, so have one of the two before the first flash.
- **Do not count on slot B as a spare.** `boot_b` is untouched, but on virtual A/B the system lives in
  `super` for the active slot only, so `fastboot set_active b` may not give a bootable Android. If the stock
  bootloader gives up on a slot that keeps failing and flips to B, run `fastboot set_active a` again after
  restoring `boot_a`.
- **U-Boot's environment is the board's own.** The fork's shared `ums9230.env` is the Reeder's: a `preboot`
  that reads MAC addresses from a UFS partition this phone lacks, and `stdout=vidconsole` only. The X6525
  now has `board/unisoc/ums9230/infinix-x6525.env` (no preboot, `bootcmd=bootflow scan -lb mmc`, and
  `stdout`/`stderr` = `serial,vidconsole`), so a UART on `serial1` shows U-Boot's own log as well as the
  kernel's. An older `boot.img` still has the Reeder one: a few "Unknown command" lines at the top of its
  log are that preboot failing, and boot goes on regardless.
- Know the way back **before** you need it: `fastboot flash boot_a <backup boot.img>` restores Android.
  If the phone no longer reaches fastboot at all, the Spreadtrum download mode with `spd_dump` is the
  fallback (your Termux setup).
- U-Boot gets the screen as a console (`CONFIG_VIDEO` with the simple framebuffer at `0x9e000000`)
  and a UART one (`CONFIG_SPRD_SERIAL`, `serial1`, 115200 8N1), so a USB cable is enough for the
  first stages and a UART is optional - and now also works in the kernel: `CONFIG_SERIAL_SPRD` is on
  in the ROM's kernel config, where it used to be off and left `stdout-path` inert.
- U-Boot enumerates as a **USB fastboot device** (`CONFIG_USB_FUNCTION_FASTBOOT`), but it cannot
  flash: `CONFIG_FASTBOOT_FLASH` is off in the board defconfig (checked in the built `.config`), so
  it answers `getvar`/`reboot` and not `fastboot flash`. The way back from a U-Boot that will not
  boot is the stock bootloader's own fastboot (volume keys at power-on) or, if the phone reaches
  neither, the Spreadtrum download mode with `spd_dump`.

## Flashing

The microSD route first (see the eMMC route after it for why it may not work). Two writes: U-Boot
into the phone, the disk image onto a microSD card (2 GB or more; the image is 1.3 GB). pmbootstrap
does both natively - `--sdcard` is an alias of `--disk`, which writes to the block device instead of
producing an image file, and `flasher flash_kernel` resolves to
`fastboot flash $deviceinfo_flash_fastboot_partition_kernel`, which this port sets to `boot_a`:

```sh
pmbootstrap install --sdcard=/dev/sdX    # /dev/sdX = the card, not a partition
pmbootstrap flasher flash_kernel         # with the phone in fastboot mode
```

This route needs a local, *unsplit* install, and does the two writes by hand. The `rom` workflow
builds a split install instead (two filesystem images for the eMMC partitions, see below), so its
artifact holds no whole-disk image to copy. Here `<out>` is `/tmp/postmarketOS-export/` after a local
`pmbootstrap export`; with the phone in fastboot mode (`fastboot devices` lists it):

```sh
fastboot flash boot_a <out>/boot.img
dd if=<out>/infinix-x6525.img of=/dev/sdX bs=4M conv=fsync    # /dev/sdX = the card, not a partition
```

- The card is written **whole**, because the image carries its own partition table: an extended-boot
  partition holding `/extlinux/extlinux.conf`, `/vmlinuz`, `/initramfs` and the DTB, and the root
  filesystem. The initramfs finds both by the `pmOS_boot`/`pmOS_root` labels: the device package's
  boot-deploy hook rewrites `/etc/fstab` so boot-deploy puts no `pmos_*_uuid` on the extlinux command
  line, and the initramfs falls back to the labels. Labels travel with a copied image, so it boots the
  same way from the card as it would from anything else.
- Both routes write the same bytes: `--sdcard` puts on the card exactly what `dd`-ing the exported
  image would, and `flasher flash_kernel` is the same `fastboot flash boot_a boot.img`.
- Do **not** run `pmbootstrap flasher flash_rootfs`. It would write the whole 1.36 GB disk image into
  the phone's `super` partition, and U-Boot cannot see a partition table nested inside a partition
  (`drivers/block/blk-uclass.c`: `part_create_block_devices()` returns early unless the device is
  `UCLASS_BLK`, and a partition is `UCLASS_PARTITION`). It would find no bootflow and sit at the
  U-Boot prompt - that is what the earlier procedure did.
- Nothing else on the eMMC is written: Android and its data stay where they are, and
  `fastboot flash boot_a <backup boot.img>` is the way back.
- The image is smaller than any current card, so the copy leaves the backup GPT 1 MB from the image's
  end rather than the card's. That is harmless - the kernel tolerates a smaller disk's protective MBR
  on a larger one on purpose, "to support dd'ing an image from a smaller disk to a larger disk"
  (`block/partitions/efi.c`) - and `sgdisk -e /dev/sdX` afterwards only tidies the backup copy.
- Insert the card, then plug in the USB cable **before** powering on: the initramfs brings the USB
  gadget up once, about two seconds in, and never retries (see 4).

### Flashing to the eMMC instead (recommended for a first boot)

The microSD route has an assumption nothing has tested: that U-Boot can see the card at all. The slot's
supply rails (`vddsdcore`, `vddsdio`) are LDOs of the SC2730 PMIC, and U-Boot has no PMIC or regulator
driver (`configs/infinix-x6525_defconfig` has no `DM_REGULATOR`/`DM_PMIC`; `sdhci-sprd.c` handles no
supplies). In the stock dump both rails are *disabled* while no card is in use, so unless the stock
bootloader leaves them on, the slot is unpowered when U-Boot looks and the boot ends at the prompt. The
eMMC has no such problem: its rail is on from power-up, and it is what U-Boot already reads.

### Storage variants: eMMC and UFS

The X6525 shipped with either eMMC or UFS, and the image boots both; the unit's storage type
changes nothing a user does:

- U-Boot scans both media: `uboot/configs/infinix-x6525_defconfig` keeps the reeder's
  `CMD_UFS`/`SCSI`/`UFS`/`UFS_SPRD_UMS9230`, the board U-Boot DTS enables `&ufs` (the dtsi's
  node has no status line of its own), and `bootcmd` says
  `bootflow scan -lb mmc; bootflow scan -lb scsi` - the first bootable entry wins, wherever it
  lives. The kernel side was already there (`CONFIG_SCSI_UFS_SPRD=y`); the kernel DTS now
  enables `&ufs` with the eMMC's core rail.
- **The boot filesystem needs 4096-byte blocks.** A UFS LUN has 4096-byte logical blocks, and
  U-Boot's ext4 driver (like Linux) cannot read a filesystem whose blocks are smaller than the
  device's. pmbootstrap makes the small boot filesystem with 1024-byte blocks; on a UFS unit
  U-Boot then finds the `cache` partition but prints `Read outside partition 92233720368547758xx`
  and boots nothing. The `rom` job rebuilds `pmos-boot-fs.img` with 4096-byte blocks
  (`tools/reblock-boot-fs.sh`: label and UUID kept, contents compared) and fails the build if either
  image has smaller blocks. 4096-byte blocks read fine on eMMC too. To check an image you already
  have: `dumpe2fs -h pmos-boot-fs.img | grep 'Block size'`.
- On an eMMC unit the UFS controller probes, finds nothing and drops out; on a UFS unit the
  eMMC scan sees just the microSD slot. `bootflow scan` continues past a medium whose storage
  it cannot read, so neither path blocks the other.
- Flashing is identical on both: the split images go into the `cache` and `userdata`
  partitions fastboot is given, which exist whatever the storage is. Only the medium U-Boot
  reads them back from differs (`mmc` vs `scsi`).
- Check the unit before flashing: in the stock bootloader or Android, `cat /proc/cmdline`
  names the boot device - the unit this port was developed on says `sprdboot.flash=emmc`, and a
  UFS unit names its UFS controller there (and in `androidboot.boot_devices`).
- **No UFS unit has been flashed yet.** The UFS pieces are the reeder's own (same reference
  design, internal UFS), but everything above is untested on real UFS hardware - watch the
  first boot on one before calling it done.

U-Boot cannot read a partition table nested inside an eMMC partition, so a whole-disk image cannot go
there. The `rom` workflow therefore builds a *split* install (`pmbootstrap install --split`): the boot
and root filesystems are formatted as images of their own, with no partition table, and those are
flashed into two eMMC partitions. That is also why the build needs no loop partition devices, only
whole ones:

```sh
fastboot getvar partition-size:cache          # this phone: p47, 64 MiB (65536 KiB); pmos-boot-fs.img must be no bigger
fastboot getvar partition-size:userdata       # must be >= the size of pmos-root-fs.img
fastboot flash boot_a  <out>/boot.img         # as before
fastboot flash cache    <out>/pmos-boot-fs.img    # pmOS_boot: extlinux.conf, kernel, initramfs, DTB
fastboot flash userdata <out>/pmos-root-fs.img    # pmOS_root
```

- This overwrites `cache` and `userdata`. Android's *system* (`super`) is untouched, but its data is gone:
  after restoring `boot_a` Android will find an unrecognised `userdata` and have to format it, so it
  starts like a fresh install (`fastboot -w` from the stock bootloader does the same explicitly). Back up
  what you need first. Do not use `persist`, `metadata`, `misc`, `tkv_*` or any of the `*_a`/`*_b` pairs for
  this - `persist` holds the device's calibration.
- **Recovering Android afterwards.** The route is: stock fastboot (via `spd_dump` reboot-to-fastboot; no key combo needed), `fastboot flash boot_a <backup>`,
  `fastboot -w` (confirmed on this phone by its owner) - note that `-w` wipes `cache` as well as `userdata`, and `cache` holds the pmOS boot filesystem, so after any `-w` re-flash `cache` and `userdata` before booting pmOS again (a flash that is interrupted should be repeated, not wiped), `fastboot reboot`. `-w` is the ordinary factory-reset
  path: it leaves `/metadata` alone, which is where the encryption keys live, so Android formats `userdata`
  afresh. Evidence from the stock `vendor_boot` ramdisk (`recovery.fstab`, `fstab.X6525`): `/data` is f2fs with
  `fileencryption`, `keydirectory=/metadata/vold/metadata_encryption` and `formattable`, and `cache` has no
  entry. **Those lines are the recovery and first-stage tables;** the runtime table is `/vendor/etc/fstab.*` in
  `super` and has not been read, so do not rely on Android auto-formatting `/data` alone - run `-w`. To check,
  in Android: `grep -h userdata /vendor/etc/fstab.* /proc/mounts`. Recovery mode is the `vendor_boot`
  ramdisk started by `boot_a`'s kernel, so it exists only after `boot_a` is restored (`-w` works before that).
  **Copy the `boot_a` backup (and anything you need from `/data`) off the phone first: it lives on `userdata`
  otherwise and the flash destroys it.** If even fastboot is unreachable, the bootloader chain (`spl`,
  `uboot_a`, `sml`, `trustos`) is never written, so Spreadtrum download mode with `spd_dump` still works.
- fastboot splits a large raw image into chunks by itself, so the 1.3 GB root image needs no `sparse`
  conversion on your side.
- The filesystems keep their labels, which is what the extlinux command line uses (`pmOS_boot`,
  `pmOS_root`), so a cache-only flash finds the rootfs already on the phone. The older UUID-based
  command line needed both images from one run; the initramfs hooks-cleanup script also migrates an
  older rootfs's `/etc/fstab` to labels at boot. Check with `file -s` on the two images: they must
  be ext2/4 filesystems, not a disk with a table.
- **Measured on this phone** (`/proc/partitions` + `/dev/block/by-name`): `cache` is `mmcblk0p47`, **64 MiB**;
  `userdata` is `mmcblk0p73`, about 110 GiB. The workflow shrinks the boot filesystem to its minimum plus
  8 MiB (about 60 MiB) and warns if the result is over 64 MiB. That fits, but leaves almost no room: a
  later kernel upgrade through `apk` needs space for the new kernel and initramfs next to the old ones, so
  move `pmOS_boot` to a larger partition once the system runs. `blackbox` (`p48`, 500 MiB, crash-log
  storage) is the roomy candidate, but nobody has confirmed it is safe to overwrite; do not use it, or
  `tranfs` (`p70`), on a guess - back it up first (`dd`) so it can be put back.
- If `cache` is smaller than the boot image, use another expendable partition for `pmOS_boot` rather than
  shrinking anything: U-Boot scans every partition of the eMMC for a bootflow, so the name does not
  matter.

## 1. U-Boot starts

Expect: after the bootloader hands over, the screen shows U-Boot's text console (white on black) and
the board model; a USB host sees a fastboot device if you interrupt autoboot.

If nothing at all appears (stays on the vendor logo, or reboots into Android):
- the `boot_a` image is not accepted - header version 4 and the payload are set in `deviceinfo`
  (`--header_version 4`, `u-boot.bin` as payload); compare with what `unpackbootimg` says about the
  stock image;
- **the memory node.** It must be the 4 GiB window (`0x0 0x80000000 0x0 0xfffff000`); the earlier 8 GiB
  value would relocate U-Boot above the end of DRAM. That is fixed in `uboot/dts` and confirmed in the
  built artifact: `u-boot.bin` from CI carries the DTB (FDT magic at `0x6ae38`) and that DTB's memory
  node is the 4 GiB one, so this is only worth re-checking if you build U-Boot yourself.

## 2. Storage

In the U-Boot console:

```
mmc list
mmc dev 0        # the board device tree aliases the eMMC (sdio3) as mmc0, so it is device 0
part list mmc 0  # if mmc list shows something else first, use the number it prints
```

Expect two devices. The eMMC still carries Android's stock partition table - this route does not
touch it - while the microSD is the pmOS one: an extended-boot partition holding `/extlinux`, and
the Linux root. `bootcmd` is `bootflow scan -lb mmc` (from `board/unisoc/ums9230/infinix-x6525.env`), so
U-Boot looks on both and boots the card.
- **The eMMC is slow (DDR52, tens of MB/s):** expected, not a fault. `sdhci-sprd` keeps
  `SDHCI_QUIRK2_BROKEN_HS200` set for `sprd,sdhci-r11`, and the core clears `MMC_CAP2_HS200` for it -
  HS400 is gated behind HS200, so the HS200/HS400 flags the DTS declares never take effect.
- **eMMC not found or I/O errors:** the DTS now carries the device's own values (8-bit, the speed
  flags, all five `sprd,phy-delay-*` sets, and no `vqmmc-supply` - `vddsdio`, which the port used to
  name here, is the microSD slot's IO rail), so the remaining suspect is the delay *tuning*: drop
  `sprd,phy-delay-mmc-ddr52` to fall back to the driver's defaults, or force `bus-width = <4>`, and
  see if the errors move.
- **SD card not seen:** card-detect. The DTS uses `eic_sync 35` (confirmed on the stock system; the empty slot
  reads high, so the flag is ACTIVE_LOW - check with a card in). `CONFIG_MMC_BROKEN_CD` is set in U-Boot, so U-Boot itself does not care; the
  kernel does. Test with a card in and out and read `cat /sys/kernel/debug/gpio`.
  If *U-Boot* does not list the card at all in `mmc list`, the slot's rails are the suspect: U-Boot has no
  driver for this PMIC's regulators and `sdhci-sprd.c` touches no supplies, so it can only use what the stock
  bootloader left powered - the reeder's board is in exactly the same position, so this is the design, not a
  fault in the board files. The kernel powers the slot itself, but a bootflow cannot start from a card U-Boot
  cannot read: report it. The eMMC does not share this risk (Android boots from it; its rails are already on).

## 3. Kernel starts, and how to see it

Expect extlinux to boot the kernel, and the framebuffer to show kernel messages. The kernel command
line carries `loglevel=7` (the device package's `kernel-cmdline.conf`; the distro config ships
`quiet`, and the later `loglevel=` is the one that counts), so the console is not filtered.
- The `simple-framebuffer` node in the DTS is **enabled** for the first boot: the bootloader leaves the
  panel scanning out `0x9e000000`, and `DRM_SIMPLEDRM` + fbcon turn that into a text console, so kernel
  messages are visible even if the DPU/DSI/panel stack never probes. If the real display stack works,
  the two coexist (the picture may go stale when the DPU takes over); then set the node to `disabled`.
  To rule the display driver out entirely, also disable `&dpu` and `&dsi`.
- Console: the device package's `kernel-cmdline.conf` names `console=tty0 console=ttyS1,115200n8` (without a
  `console=tty0` the kernel prints only to the UART when `stdout-path` is set, so the screen would stay silent;
  naming a console also turns `stdout-path` off, hence the UART is named too), `plymouth.enable=0` and `nosplash`. The UART is in `stdout-path`, and `CONFIG_SERIAL_SPRD=y` in the ROM's
  kernel config (it was off before, which left the property inert) makes it a real console.
- **Crash or reboot with nothing on screen: read `ramoops`.** The DTS reserves `ramoops@fff80000`, and
  `CONFIG_PSTORE_RAM=y` is set, so the last kernel log survives in `/sys/fs/pstore/` for the next boot
  to read - including a boot that only gets as far as the initramfs, whose debug shell mounts pstore
  first (see 9). This is the best tool this phone gives you for a kernel that dies before the display
  works.

- **Reboots about 12 seconds after the kernel starts: the watchdog.** The stock command line carries
  `androidboot.wdten=e551`, and `sprd_wdt` (DT `timeout-sec = <12>`) used not to notice a counter the
  bootloader had already started, so nothing fed it until userspace opened `/dev/watchdog`. Patch 11 marks
  it running when the enable bit is set at probe, so the core feeds it. If the reboot loop persists with
  that patch in, it is a different watchdog (the PMIC's has no mainline driver).

## 4. USB networking (how you will actually reach it)

Expect a USB network interface on the host (`ip link`, look for `usb0`/an `enx...` name) and SSH to
`172.16.42.1` (the postmarketOS default). This is the mainline USB gadget stack, not the vendor
`sprd_f_rndis` of the 5.4 route; check that the kernel config has the configfs gadget with a network
function enabled.
- No interface: the MUSB controller is in the wrong role. The DTS sets peripheral mode with
  `usb-role-switch` and the PHY supply `vddusb33`; check `dmesg | grep -i -E 'musb|hsphy|usb'`.
- Interface but no IP: look at the initramfs log (`pmos.debug-shell` on the kernel command line gives a
  shell on the network console).

### Using a second Android phone as the host (Galaxy A01 Core, Ubuntu chroot)

**This is the host this port is being brought up from**: a Samsung Galaxy A01 Core running Android
with an armhf Ubuntu chroot, OTG-wired to the X6525 - so the steps below are the working procedure,
not an alternative. It works for flashing and for SSH, with some checks. The A01 Core's kernel
(`github.com/Takumi123w/kernel-a01c`, 4.14.141, MT6739, `a01core_defconfig`) has `cdc_ncm`, `cdc_ether`,
`cdc_eem`, `usbnet`, `USB_ACM`, FTDI and PL2303 serial built in and `USB_NET_RNDIS_HOST` **off**. That suits this
image: its USB network function is NCM (`deviceinfo_usb_network_function="ncm.usb0"`, also what the initramfs
falls back to), not RNDIS. Stock Android tethering on the X6525 is RNDIS, which that phone cannot host; the pmOS
link is NCM, which it can. Use `rndis.usb0` only for a Windows 10 host.

- **Cable:** the A01 Core has a micro-USB port: micro-USB OTG adapter -> USB-A cable -> the X6525's USB-C.
  First test OTG with a USB stick, because nothing here confirms that port supplies VBUS to a peripheral.
  The A01 Core is a 32-bit userland, so the chroot must be `armhf` Ubuntu.
- **Flashing (stock fastboot):** in the chroot, `apt install fastboot`, then expose USB to it from the
  Android side as root: `mount --bind /dev/bus/usb <chroot>/dev/bus/usb` and `setenforce 0` if SELinux
  blocks it. `fastboot devices` must list the X6525 before any flash. Keep about 2 GB free for the images.
- **Connecting after boot:**
  - **In the initramfs debug shell:** SSH (`sshd`, port 22) is **not running yet** in the debug shell; only `telnet 172.16.42.1 23` and a USB CDC-ACM serial console (`/dev/ttyACM0` on the host) are listening!
  - **Android host routing bypass:** Android's `netd` policy routing blocks non-default routing tables. In the host chroot as root, run:
    ```sh
    ip rule add from all to 172.16.42.0/24 lookup main pref 100
    ip rule add from 172.16.42.0/24 lookup main pref 100
    ```
    (or run `tools/host-watch.sh`, which configures this automatically).
  - **CDC-ACM USB Serial Console:** The initramfs debug shell spawns a getty on `/dev/ttyGS0`, which the Galaxy A01 Core host sees as `/dev/ttyACM0` (its kernel has `CONFIG_USB_ACM=y`). You can connect directly without IP networking:
    ```sh
    minicom -D /dev/ttyACM0
    # or: microcom -p /dev/ttyACM0
    ```
  - **Network shell:** On the host phone as root, `ip link` shows the NCM interface as **`usb0`** on the
    A01 Core's NetHunter kernel (`usbN`/`enx*` on other kernels), **DOWN** with no address - the gadget
    enumerates fine (`lsusb`: `18d1:d001 Infinix X6525`) but Android does not configure it. Bring it up
    and address it yourself, and re-do this after every reboot (the gadget rebinds when the initramfs
    hands over to the rootfs):
    ```sh
    ip link set usb0 up
    ip addr add 172.16.42.2/24 dev usb0
    ip rule add from all to 172.16.42.0/24 lookup main pref 100
    ip rule add from 172.16.42.0/24 lookup main pref 100
    telnet 172.16.42.1        # in the initramfs debug shell (telnetd stops when it ends)
    ssh user@172.16.42.1       # once booted into the rootfs (password: x6525pmos)
    ```
    The name is **not stable**: each re-enumeration (a re-plug, or the gadget rebind when the
    initramfs hands over) takes the next free name - `usb0`, then `usb1`, and so on. Find it with
    `ip -br link` or `dmesg`'s `cdc_ncm ... -> usbN` line, and treat `RTNETLINK answers: File exists`
    from the two `ip rule` lines as success: those rules are global and only need adding once.
- **Watch instead of guessing:** `tools/host-watch.sh` (run as root on the host phone, in the chroot with
  `/sys` bind-mounted) logs every USB device that appears or disappears with a timestamp, relays the host
  kernel's USB lines, adds the Android routing rules, and when the pmOS gadget (`18d1:d001`) appears it finds the interface, sets
  `172.16.42.2/24` and tests the debug shell (23) and SSH (22), and checks for `/dev/ttyACM0`. It separates three cases that all look like
  "lsusb shows nothing": no device ever attached; a device attached under another id (stock fastboot
  `18d1:4ee0`, Spreadtrum download `1782:4d00`); and an attach that fails (`error -71`, over-current). Until
  the pmOS kernel has brought its USB up there is nothing to see: U-Boot has no USB gadget. The logic is
  tested against a fake `/sys` (`sh tools/test-host-watch.sh`).
- **Camera:** the host phone can also film the X6525's screen. Record video and step through it frame by
  frame; the debug build's 15 s pause in U-Boot is long enough to read the previous boot's log from a
  still frame.
- **UART alternative:** an FTDI or PL2303 USB-serial adapter shows up as `/dev/ttyUSB0` on that kernel (CH341
  and CP210x are not built in). Wire it to the X6525's `serial1` and `screen /dev/ttyUSB0 115200`.

## 5. Display

Expect `dmesg | grep -i -E 'dpu|dsi|td4160|panel'` to show the panel probing and the framebuffer
switching over, and a picture (unl0kr in the initramfs).

If the panel stays dark, in this order (both are written down in `drivers/panel-td4160-hx.c`):
1. **Reset polarity.** The driver drives the raw levels from the vendor sequence (`<1 5>, <0 5>, <1 20>`)
   on `ap_gpio 50` with the DT flag `GPIO_ACTIVE_HIGH`, so logical equals physical. If the panel never
   starts, invert the physical levels with **one** change: either flip the flag to `GPIO_ACTIVE_LOW`
   and leave the driver alone, or swap 0 and 1 in the three driver calls and leave the flag. Doing both
   cancels out.
2. **Brightness.** The init sequence ends with brightness 0 (`0x51 0x00 0x00`). If the panel is
   initialised (you may see a faint image at an angle) but looks black, write a brightness:
   `echo 1500 > /sys/class/backlight/*/brightness` (maximum is 4095). If that fixes it, the curve is the
   open point, not the panel.
3. Supplies `avdd`/`avee` (`ap_gpio 54`, `55`): a missing rail also shows as a dark but initialised panel.

## 6. Touch

Expect, in `dmesg | grep -i -E 'tcm|touch'`, a firmware load of `postmarketos/sprd/hdl_firmware_01.img`
and then `touch ready: <w>x<h>, <n> objects`. Check `/proc/bus/input/devices` for
`omnivision_tcm_touch` and `evtest` for events.

- **"cannot load postmarketos/sprd/hdl_firmware_01.img":** the `firmware-infinix-x6525` package is not
  installed. Put `firmware/hdl_firmware_01.img` from this repository under
  `/lib/firmware/postmarketos/sprd/` by hand to test.
- **"no identify report after reset":** the reset line or the interrupt. The reset is active-low
  (`ap_gpio 145`); the interrupt is level-low on `eic_async` 16, which is what the running system's
  own tree carries - the vendor overlay's `ap_gpio 16` is a different line, and on it the controller
  never sees the first IDENTIFY report. Probe with `cat /proc/interrupts` - the count should move
  when you touch the panel, and also right after the reset.
- **Timeouts on `CMD_ROMBOOT_DOWNLOAD`:** the download is one large SPI transfer (about 100 KB).
  Check the SPI controller's limits first (`spi-sprd-adi`/the `spi3` driver's maximum transfer size) and
  the clock (`spi-max-frequency = <8000000>`); try 4 MHz.
- **Works, then stops after the screen blanks:** a panel reset also resets the touch IC. The driver
  re-downloads when it sees the new ROM-boot IDENTIFY; if it does not, send me the `dmesg` around it.

## 7. Charging

Expect `dmesg | grep -i bq2415x` to say `chip bq24158, revision 1.0, vender code 010` and
`automode supported, waiting for events`. Then:

```
ls /sys/class/power_supply/           # bq24158-*, usb-charger-detect, sc27xx-fgu / battery
cat /sys/class/power_supply/usb-charger-detect/online          # 1 with a cable in
cat /sys/class/power_supply/usb-charger-detect/current_max     # 500000 (conservative)
cat /sys/class/power_supply/bq24158-*/status
```

- **No bq24158 message:** wrong bus or address (it must be `i2c3` at `0x6a`), or `CHARGER_BQ2415X` is
  not enabled in the kernel config.
- **`online` never becomes 1:** the VBUS pin (`pmic_eic 0`), its polarity, or `extcon-usb-gpio`
  not liking a VBUS-only configuration.
- **Detected but the battery does not charge:** `ap_gpio 115` (`charger_en`) is hogged low in the DTS,
  the level the stock system shows while charging. Check `grep 115 /sys/kernel/debug/gpio` reads `out lo`.
- The 500 mA ceiling is deliberate; raise `default-microamp` in the `usb_detect` node only after this
  works.

## 8. Sensors

Expect only the proximity sensor: `dmesg | grep -i vl53` and an IIO device under `/sys/bus/iio/devices/`
(`cat in_distance_raw` with a hand over the top of the phone). It is the VL53L0X the vendor overlay
names as `0x52` on `i2c4` (the 8-bit form; the node uses the 7-bit `0x29`). XSHUT and the interrupt are
`ap_gpio` 168 and 169, taken from the overlay's bare numbers (its `interrupts` property uses 169 with `ap_gpio`
as parent, which is chip-local) - not confirmed on hardware. If it does not probe, suspect XSHUT first. The
Smart 8 may not even carry the part - the overlay is shared - so a probe failure here is not a bug in the port.

The accelerometer and ambient-light sensor are not here: the vendor kernel reaches them through
`sprd,sensor-hub`, a coprocessor with no mainline driver. Auto-rotate and auto-brightness will not work.

## 9. When it does not boot

The initramfs has two levers on keys you already have. Both are checked *after* USB networking is up,
and both work here because `evdev` is in the initramfs (pmOS ships it in `00-default.modules`) and
`CONFIG_KEYBOARD_GPIO=y`, so the volume keys are readable that early:

- **Hold volume-down while booting** - the debug shell. It runs over the USB network that is already
  configured and mounts `/sys/fs/pstore` before it starts, so a panic `ramoops` captured is readable
  there even when the rootfs never mounted. In images built after this change the initramfs also
  carries the vibrator (`modules-initfs`), so the shell announces itself by buzzing; before that it
  hides the splash instead.
- **Hold volume-up while booting** - refuse to continue and dump the logs.

If neither key does anything, the keys themselves are the suspect, not the lever.

If **U-Boot** finds no bootflow (card missing or unreadable), the phone stops there, and what you
can do about it depends on whether a UART is attached. The board environment sets
`stdin=serial` and `stdout`/`stderr` = `serial,vidconsole`, so U-Boot's output goes to the screen
*and* the UART, and its only input is the serial port (a display with no keyboard driver is not an
input device). **With a UART attached you get a full U-Boot prompt**, enough to run `bootflow scan`
by hand or to reach the stock fastboot. (A `boot.img` built before `39bf351` still has the Reeder
environment: screen-only output, so you would type blind.)

Without one: hold the power key to turn the phone off, insert the card, and try again - or leave
the card out and go to the stock fastboot (`spd_dump` reboot-to-fastboot), where `fastboot flash boot_a`
still works.

The lever that does not depend on the keys is `pmos.debug-shell` in the card's
`/extlinux/extlinux.conf`: mount the card on any PC, add it to the `append` line, put the card back.
The initramfs then opens a shell unconditionally - and stops there until `pmos_continue_boot` is run
in it, which is why it is not on the default command line: if USB never comes up, a boot carrying it
would wait forever at a shell nobody can reach.

## What to send back

The smallest set that lets me find a problem without another round trip:

1. the screen or serial output of U-Boot (the first screenful is enough);
2. `dmesg` after the kernel starts (or `/sys/fs/pstore/*` if it died);
3. for each stage above that failed, the commands listed under it.


## Debug build: first boot reached "Starting kernel", then a blank screen

The first flash got as far as U-Boot loading the kernel, then showed a black screen and reset itself
after a few minutes, and the host phone saw no USB device. The debug build changes three things (all
marked DEBUG, remove them once the boot works):

- kernel cmdline `initcall_blacklist=sprd_drm_init`: the DPU/DSI driver does not load, so the
  framebuffer the bootloader left running (simpledrm) stays the only display and nothing can blank it;
- `ignore_loglevel initcall_debug`: every message and every initcall is printed, so a hang shows the
  last initcall that started;
- U-Boot prints the previous boot's kernel log (`pstore display console` and `dump`, from the ramoops region at
  `0xfff80000`) and waits 15 s before booting. It needs the RAM to survive the reset, so it may show
  nothing - that is itself a result.

How to read it: flash all three again from the same build (`boot_a`, `cache`, and `userdata` - Android has since
replaced the pmOS root filesystem there, and the U-Boot with the log reader is in `boot.img`), boot, and photograph the
screen (1) at the first U-Boot screen after the phone resets itself and (2) the last lines of the
kernel output before it stops. If the kernel text appears and then stops, the last initcall line is
the culprit. If the screen stays black with the display driver off, the kernel died before
simpledrm.

If U-Boot stops at the `=>` prompt with `(0 bootflows, 0 valid)`, it found no extlinux on any eMMC partition.
The debug U-Boot then prints which partition `cache` is and lists its `/` and `/extlinux`: an error there means
the boot filesystem was not written to `cache` (flash it again and watch for a fastboot or `spd_dump` error), an
empty listing means the wrong image went there.

## Debug build: PMIC watchdog (U-Boot `pmicwdt`)

The reset at a fixed ~5 minutes with a live kernel looks like a watchdog nothing feeds. The AP watchdog
(12 s) does not fit; the PMIC one has no mainline driver. U-Boot now runs `pmicwdt stop` first thing: it prints
the last reset status, the PMIC watchdog registers at 0x40 and 0x80 (before/after) and disarms a block that is
running. **Photograph that screen** (the boot waits 5 s on it).

No rebuild needed, only `boot_a`:

    python3 -I tools/swap-uboot.py <your boot.img> u-boot.bin boot-new.img
    python3 -I tools/check-boot-img.py boot-new.img 64
    fastboot flash boot_a boot-new.img      # cache and userdata stay as they are

Recovery is unchanged (stock boot.img to `boot_a`; `fastboot -w` also wipes `cache`).

## Putting a command-line option straight into the boot fs image

`tools/patch-cmdline.sh` does the `debugfs` edit from the debug-build notes in one step and proves it:
it changes only the `append` line, skips options that are already there, checks the result by reading it
back from the image, runs `e2fsck`, confirms `/vmlinuz` and `/initramfs` are still present, and keeps the
first original as `<img>.orig`. Run it on every freshly downloaded `pmos-boot-fs.img` before flashing `cache`:

    sh tools/patch-cmdline.sh pmos-boot-fs.img                 # adds cpuidle.off=1 cpufreq.off=1
    sh tools/patch-cmdline.sh pmos-boot-fs.img "maxcpus=6"     # or any other option

A reflash of `cache` from an unpatched image removes the option again, so the script is the check.

## What the current debug build contains (and what each part fixed)

Reached the `x6525 login:` prompt on 2026-10-18 with these, all in `main`:

| Piece | Where | Fixes |
|---|---|---|
| `pmicwdt stop` in the U-Boot bootcmd | u-boot fork 434a9c96, `u-boot-infinix-x6525` pkgrel 3 | the fixed ~5-minute reset (PMIC watchdog nothing fed) |
| `cpuidle.off=1 cpufreq.off=1` | `kernel-cmdline.conf` | RCU stalls (a CPU stopped taking timer interrupts); which of the two is the cause is not known yet |
| `console=tty0` last, `pmos.debug-shell` | `kernel-cmdline.conf` | init output on the screen; debug shell on USB (telnet 23, serial `ttyACM0`) |
| `regulator_ignore_unused` + `&vddldo0` always-on | cmdline + DT | touch controller rail cut after 30 s |
| touch firmware in initramfs/rootfs, `ovt-tcm-spi` in initramfs, SPI full-duplex fix | pmaports (b0e8b31) | touch bring-up (not yet delivering input on hardware) |
| `ui = buffyboard` (was `console`), `service_manager = systemd` | `rom.yml` | `ui = console` installs the `buffyboard` binary but not the service that starts it (that comes with `postmarketos-ui-buffyboard`). The UI package carries `pmb:default-openrc`, so without the pin selecting it would also switch the image from systemd to OpenRC |
| 16-bit X/Y in the touch report layout | `drivers/ovt-tcm-spi.c` (patch 0006) | the 12-bit fields truncated raw Y modulo 4096, so the keyboard strip (raw Y >= ~8600) could never be reported; buffyboard saw every tap above its keyboard |

When the boot is stable, remove the debug options one at a time and re-test (cpuidle and cpufreq first,
to find which one stalls), and re-enable the display driver (`initcall_blacklist=sprd_drm_init`).

## Auditing the running phone, and getting the Wi-Fi firmware

`tools/phone-audit.sh` (run on the phone, root for the kernel log) prints PASS / FAIL / WARN / INFO / SKIP per
feature - stability, watchdog, CPUs, storage, USB, touch (device, interrupt count, firmware, rail), buttons,
display, battery, thermal, Wi-Fi, audio, network - names the usual fix next to every FAIL and saves the table to
`/tmp/phone-audit.txt`. `sh tools/test-phone-audit.sh` runs it against fake trees (no phone needed). It reports
what the kernel exposes and logs; it cannot see whether the picture or the sound is right.

The mainline fork already has the Unisoc Wi-Fi/Bluetooth stack (`sprd_wcn` remoteproc, `sc23xx_wlan_sipc`; the
nodes are in `ums9230.dtsi`, the modules in the config). What is missing is firmware from the stock system:
`sprd/wcnmodem.bin` and `sprd/wifi_board_config.bin`. `tools/extract-wcn-firmware.sh` collects every candidate
(wcn partitions, matching files, a report) so the right files are chosen from facts.
