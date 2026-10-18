# pmos-infinix-x6525

Draft postmarketOS port for the Infinix X6525 (Unisoc UMS9230 / T606): the **mainline** kernel
(`ums9230-mainline`), with a U-Boot board chainloaded from `boot_a`.

**Status: it boots.** U-Boot loads the kernel from the eMMC, the root filesystem comes up, and SSH
over the USB link works (Quick start below). The touchscreen is the next thing being brought up.

[FIRST_BOOT.md](FIRST_BOOT.md) is the port stage by stage, with what to send back at each one, and
how to build the image either here or on GitHub. `pmbootstrap install` builds a whole MBR+GPT disk
image; U-Boot cannot read a partition table nested inside a partition, so the flash procedure writes
the image's two filesystems into real eMMC partitions (`cache` and `userdata` - the route in
FIRST_BOOT.md) or the whole image onto a microSD card. `pmbootstrap flasher flash_rootfs` must not be
run: it would put that disk image into `super`, where U-Boot cannot see it. `NOTES.md` is the record
behind it: every value taken from the stock system or from the running device's own device tree, with
its source.

An earlier attempt used the stock 5.4 "Helix" kernel instead. Its files (`linux-infinix-x6525/`,
`device-infinix-x6525/`, `build-kernel.sh`, `repack.sh`) are kept for reference; nothing in the
mainline port uses them, and the workflow that built that kernel has been removed.

`tools/audit-features.sh` reports which features the tree completes, is partial on, or is missing by
design; with `--image <artifact>` it also checks a downloaded image (packaging, the built config, the
modules in the initramfs, and the documented login).

## Quick start

You need: the X6525, the Galaxy A01 Core host with its OTG adapter, and the `x6525-rom` artifact from
the latest green **rom** run (Actions → rom → Run workflow).

**1. Flash.** Three writes: U-Boot into `boot_a`, the boot filesystem (kernel, initramfs, DTB,
extlinux) into `cache`, the root filesystem into `userdata`. This overwrites Android's data; `super`
and `boot_b` are left alone. The other route (a microSD card) is in [FIRST_BOOT.md](FIRST_BOOT.md)'s
*Flashing* section.

```sh
# in the extracted x6525-rom directory, with the phone in fastboot mode
fastboot flash boot_a   boot.img
fastboot flash cache    pmos-boot-fs.img
fastboot flash userdata pmos-root-fs.img
```

**2. Power on with the USB cable connected.** The phone sets up the USB connection once, about two
seconds into boot; if the cable goes in later, power-cycle.

**3. On the A01 Core, configure the USB link.** Run as root. `ip link` shows the interface name -
`usb0` here; after a re-plug it becomes `usb1`, and so on, so use the name it printed.

```sh
ip link set usb0 up
ip addr add 172.16.42.2/24 dev usb0
ip rule add from all to 172.16.42.0/24 lookup main pref 100   # Android netd bypass
ip rule add from 172.16.42.0/24 lookup main pref 100
```

**4. SSH into the phone.**

```sh
ssh user@172.16.42.1        # password: x6525pmos
```

**5. Give the phone internet.** It has no WiFi driver, so it uses the host's connection.

```sh
# A01 Core, as root. usb0 = the name from step 3. First check the host is online
# itself (ping 1.1.1.1 / 8.8.8.8) and which interface carries its default route:
#   DEF=$(ip route | awk '/^default/{print $5; exit}'); echo "$DEF"
# It is wlan0 on WiFi, but Android may prefer rmnet* (cellular) - NAT the one the
# default route actually uses, or the phone's packets leave un-NATed.
DEF=wlan0
echo 1 > /proc/sys/net/ipv4/ip_forward
# Insert at the top (-I), do not append (-A): Android's FORWARD chain contains
# netd's DROP rules, and an appended ACCEPT would sit behind them.
iptables -t nat -I POSTROUTING 1 -o "$DEF" -j MASQUERADE
iptables -I FORWARD 1 -i usb0 -o "$DEF" -j ACCEPT
iptables -I FORWARD 2 -i "$DEF" -o usb0 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

```sh
# X6525, in the SSH session.
sudo ip route replace default via 172.16.42.2 dev usb0   # replace: a default route may already exist
# any public resolver will do (8.8.8.8 too); the router's own, from the host's WiFi, is often best
sudo sh -c "echo nameserver 1.1.1.1 > /etc/resolv.conf"  # a plain file here; resolved is not enabled
ping -c2 1.1.1.1          # by IP, so this tests routing/NAT
ping -c2 google.com       # and this adds DNS
```

That is the whole path: flash, power on, address the link, SSH, internet. The rest of this file is
reference.

### If a step fails

| What you see | What it means | Fix |
|---|---|---|
| `Cannot find device usb0` | the name moved (every re-plug takes the next free name) | `ip -br link`, use the name it shows |
| `RTNETLINK answers: File exists` from `ip rule` | harmless - those rules are global and already added | ignore |
| no USB interface at all | the cable went in after boot, or the phone did not come up | power-cycle with it connected; `lsusb` should show `18d1:d001 Infinix X6525` |
| SSH refused, but you have a console | you are still in the initramfs debug shell | run `pmos_continue_boot` there; telnet works in that shell, SSH only after it |
| `ping 1.1.1.1` fails | the host is not forwarding, or the default route is wrong | `sudo ip route replace default via 172.16.42.2 dev usb0`; re-run the step-5 host lines *with `-I`*; `iptables -t nat -L POSTROUTING -n -v` must count up |
| names fail but IPs work | the resolver line did not take | redo the `nameserver 1.1.1.1` line; `/etc/resolv.conf` is a plain file in this image (systemd-resolved is not enabled), and NetworkManager can rewrite it - the `nmcli` profile in *Details* carries `ipv4.dns` and survives that |

## Details

### Logging in

The image has one account: `user`, password `x6525pmos` (set by `rom.yml`'s `--password`). `root` is
locked and there is no SSH key. The password cannot be recovered from the image - only its hash is in
`/etc/shadow` - so change it in the workflow and rebuild.

Three ways in:

- **USB network** (steps 3-4) - the normal one, and the only IP path once booted.
- **Serial UART** - `serial1` (ttyS1), 115200 8N1, on the pads. `console=ttyS1` is on the kernel
  command line, so kernel logs and a login getty both appear there. On the A01 Core an FTDI or PL2303
  adapter is `/dev/ttyUSB0` (CH341/CP210x are not in that kernel): `screen /dev/ttyUSB0 115200`.
- **The screen** - the `x6525 login:` prompt is real (`getty@tty1`), but touch cannot type and no
  on-screen keyboard is wired to a getty, so it is read-only for login today.

The debug cmdline carries `pmos.debug-shell`, so every boot stops in the initramfs first: a root shell
on the USB serial port (`/dev/ttyACM0` on the host, `minicom -D /dev/ttyACM0`) and `telnet
172.16.42.1:23`. `pmos_continue_boot` enters the rootfs; that also stops telnet (SSH only from then
on) and rebinds the gadget, so the host has to re-check the interface name and address.

Host-side details - the OTG cable, the armhf chroot, Android's routing: [FIRST_BOOT.md](FIRST_BOOT.md),
*Using a second Android phone as the host*, and [DEBUG_SHELL_GUIDE.md](DEBUG_SHELL_GUIDE.md).
`tools/host-watch.sh` performs the step-3 host part by itself as the device appears.

### Internet, permanently

The route and resolver from step 5 do not survive a reboot. The image ships NetworkManager, so turn
them into a profile:

```sh
sudo nmcli con add type ethernet ifname usb0 ipv4.method manual \
    ipv4.addresses 172.16.42.1/24 ipv4.gateway 172.16.42.2 ipv4.dns 1.1.1.1
```

`unudhcpd@usb0` is the DHCP server for the *host*, so the phone's own address, route and resolver are
set by hand (or by that profile). Android's netd can flush the host's iptables rules when WiFi
reconnects - if the internet stops working, re-run the step-5 host lines.

## What runs by itself

| Workflow | When | What it does |
|---|---|---|
| `build.yml` | every push touching `dts/`, `drivers/`, `bindings/`, `patches/`, `uboot/`, `tools/` or `pmaports/` | the gate: the submission series applies to the pinned kernel tag and reproduces `dts/`, `drivers/` and `bindings/`; the DTB and the three bindings validate; the drivers compile; the U-Boot and firmware URLs still hash to their APKBUILDs; and the ROM's own kernel config keeps this port's symbols |
| `rom.yml` | Actions → **rom** → *Run workflow* | builds the kernel, U-Boot and rootfs on an arm64 runner and uploads what to flash |
| `firmware-release.yml` | Actions → **firmware release** → *Run workflow* | publishes a versioned copy of the touch firmware to this repository's releases; nothing depends on it |

## vendor_boot and the DTB (corrected)

An earlier version of these notes claimed that `deviceinfo_header_version="4"` makes pmbootstrap write a
vendor_boot without the DTB, so boot had to be flashed alone with `repack.sh`. That is wrong:

- boot-deploy (run by mkinitfs) builds **both** boot.img and vendor_boot.img for header v3/v4, and passes
  `--dtb` from `deviceinfo_dtb` to mkbootimg. A generated vendor_boot therefore does carry a DTB — the one
  from the kernel package. `deviceinfo_flash_offset_*` are not used at v4.
- `device-jolla-c2`, which runs on the same SoC, takes the other route: `--header_version 4` is passed only
  through `deviceinfo_bootimg_custom_args`, with `deviceinfo_header_version` left unset, so pmbootstrap never
  generates or flashes a vendor_boot at all — U-Boot, chainloaded from boot.img, supplies the DTB via its
  extlinux config.

`repack.sh` is a manual fallback, not a requirement.

## Building the mainline port

The device tree, the three drivers and the binding glue live here and are applied to a checkout of the
ums9230-mainline kernel with one script:

```sh
git clone --depth 1 --branch v7.2-rc6-ums9230-0 \
    https://codeberg.org/ums9230-mainline/linux kernel
./tools/apply-overlay.sh kernel
```

That installs `dts/`, the three drivers (`panel-td4160-hx.c`, `ovt-tcm-spi.c`,
`extcon-charger-detect.c`) and the three bindings, then applies `patches/*.patch`: the dtb-y entry, the
board compatible and vendor prefix, and the panel, touchscreen and charger Kconfig/Makefile glue. The
script is idempotent and refuses to half-apply a patch that no longer fits — refresh `patches/` when
you bump the pinned tag.

`.github/workflows/build.yml` does the same on every push that touches those directories, and then
some: it clones the pinned tag, checks that the submission series applies to it and reproduces `dts/`,
`drivers/` and `bindings/`, applies the overlay, builds `ums9230-infinix-x6525.dtb`, validates the
bindings and this board's nodes, enables `DRM_SPRD`, `DRM_PANEL_TD4160_HX`, `TOUCHSCREEN_OVT_TCM_SPI`,
`CHARGER_BQ2415X`, `CHARGER_EXTCON_DETECT` and the PMIC chain the thermistors need behind an
`olddefconfig` gate, compiles the three drivers, refetches the U-Boot archive and the firmware tarball
and compares them against the sha512s in their APKBUILDs, and checks this port's six symbols survive
in the **pmaports** kernel config — the one the ROM is actually built with. The `build` job uploads
`x6525-build`; the `uboot` job builds the board and uploads `x6525-uboot`.

## What is where

| Path | What |
|---|---|
| `dts/`, `drivers/` | the device tree and the three drivers (panel, touch, charger) to send upstream |
| `bindings/` | new DT bindings (the board/vendor entries are in `patches/`) |
| `patches/` | build glue for the pinned kernel tag: kernel tree entries, the panel/touchscreen/charger Kconfig and Makefile entries, and the gpio binding fix |
| `patches/upstream/` | the eleven `git am`-able patches for submission, plus notes on where each goes |
| `uboot/` | the X6525 U-Boot board: a defconfig and a device tree, no board directory |
| `patches/upstream-uboot/` | the three U-Boot board patches for submission (device tree, defconfig, environment) |
| `pmaports/` | the four packages to copy into pmaports: the device, the kernel (this port's eleven patches and its config), U-Boot, and the touch firmware |
| `firmware/` | the touch HDL image off the device, the upload tarball and its hashes |
| `tools/` | dtbo/dtb extraction, the live device-tree dumper, the HDL image checker, the vendor-sequence converter, the boot-image and boot-fs checks, and `audit-features.sh` |
| `linux-infinix-x6525/`, `device-infinix-x6525/`, `build-kernel.sh`, `repack.sh` | the earlier downstream 5.4 approach, kept for reference |

First boot of the mainline port, stage by stage with what to send back: [FIRST_BOOT.md](FIRST_BOOT.md).

To collect the remaining hardware facts from the stock system in one go: `sh tools/collect-live.sh` (see `NOTES.md`, "Next steps").
