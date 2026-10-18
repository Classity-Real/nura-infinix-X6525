# pmos-infinix-x6525

Draft postmarketOS port for the Infinix X6525 (Unisoc UMS9230 / T606): the **mainline** kernel
(`ums9230-mainline`), with a U-Boot board chainloaded from `boot_a`. **Untested** - nothing in this
repository has run on the hardware yet.

[FIRST_BOOT.md](FIRST_BOOT.md) is the port stage by stage, with what to send back at each one, and
how to build the image either here or on GitHub. The rootfs boots from a microSD card, not from an
eMMC partition: `pmbootstrap install` builds a whole disk image and the flash procedure writes it to
a card, so the only write into the phone is U-Boot, into `boot_a` (`pmbootstrap flasher flash_rootfs`
must not be run - it would put that disk image into `super`, where U-Boot cannot see it). `NOTES.md`
is the record behind it: every value taken from the stock system or from the running device's own
device tree, with its source.

An earlier attempt used the stock 5.4 "Helix" kernel instead. Its files (`linux-infinix-x6525/`,
`device-infinix-x6525/`, `build-kernel.sh`, `repack.sh`) are kept for reference; nothing in the
mainline port uses them, and the workflow that built that kernel has been removed.

`tools/audit-features.sh` reports which features the tree completes, is partial on, or is missing by
design; with `--image <artifact>` it also checks a downloaded image (packaging, the built config, the
modules in the initramfs, and the documented login).

## Logging in

The image has one account: `user`, with the password `rom.yml` passes to `pmbootstrap install`
(`x6525pmos` today). `root` is locked and there is no SSH key. The password cannot be recovered from
the image - only its hash is in `/etc/shadow` - so change it in the workflow and rebuild;
`tools/audit-features.sh --image <artifact>` checks that a built image really carries it.

**USB network: the normal way, and the one that gives you SSH.** Plug the cable in *before* powering
on - the initramfs creates the USB gadget once, about two seconds in, and never retries. The phone is
`172.16.42.1` and serves DHCP to the host (`172.16.42.2`); the gadget function is NCM
(`deviceinfo_usb_network_function`).

The host used for this bring-up is a **Samsung Galaxy A01 Core** running Android with an armhf Ubuntu
chroot. [FIRST_BOOT.md](FIRST_BOOT.md) section *"Using a second Android phone as the host"* has the
details: the micro-USB OTG adapter to USB-C, the armhf chroot, and why NCM matters (that kernel has
`cdc_ncm` but not `USB_NET_RNDIS_HOST`, so it cannot host Android's stock RNDIS tethering). On that
host, in the chroot as root:

```sh
ip link                          # the NCM interface: usb0 on this NetHunter kernel (usbN/enx* elsewhere)
ip link set usb0 up              # Android leaves it DOWN when it enumerates
ip addr add 172.16.42.2/24 dev usb0
ip rule add from all to 172.16.42.0/24 lookup main pref 100   # bypass Android netd routing
ip rule add from 172.16.42.0/24 lookup main pref 100
telnet 172.16.42.1               # initramfs debug shell, while pmos.debug-shell holds the boot
ssh user@172.16.42.1             # after pmos_continue_boot, once the rootfs has booted
```

`tools/host-watch.sh` runs that sequence as the device appears (it also recognises the stock-fastboot
and Spreadtrum download-mode ids). The debug shell additionally exposes a CDC-ACM serial console,
`/dev/ttyACM0` on the A01 Core: `minicom -D /dev/ttyACM0`. On a normal Linux host instead, the
interface takes its address from the phone's DHCP server (`sudo dhcpcd usb0`, or NetworkManager), and
the same `telnet`/`ssh` follow.

Two traps when doing it by hand. The interface **name changes between enumerations** - every re-plug
or gadget rebind takes the next free name (`usb0`, then `usb1`, ...), so find it with
`ip -br link` (or `dmesg`'s "cdc_ncm ... -> usbN" line) instead of assuming `usb0`. And the two
`ip rule` entries are global, so `RTNETLINK answers: File exists` from them is harmless. A loop that
configures whichever interface appears is more reliable than doing it once:

```sh
while :; do
  for d in usb0 usb1 usb2 usb3 usb4 usb5; do
    if [ -e /sys/class/net/$d ] && ! ip -br addr show $d 2>/dev/null | grep -q 172.16.42.2; then
      ip link set $d up; ip addr add 172.16.42.2/24 dev $d
      echo "$(date +%T) configured $d"
    fi
  done
  sleep 1
done
```

Two things about the transition out of the debug shell are easy to trip over. The debug shell's
console is a **root shell, not a login**; and `pmos_continue_boot` stops telnetd and removes the
ACM/storage functions, which rebinds the gadget - **after it, telnet is gone by design and SSH is the
only IP way in**, and the host sees the interface disappear and return. Re-check `ip link`/`ip addr`
on the host at that moment, or let `tools/host-watch.sh` do it: it waits for the gadget, sets
`172.16.42.2/24`, and tests ports 23 and 22 as each stage appears.

**Serial UART.** `serial1` (ttyS1), 115200 8N1, on the pads. The kernel console is named on the
command line (`console=ttyS1` in `kernel-cmdline.conf`), and systemd's getty generator starts a serial
getty for consoles named there, so a UART adapter gives a login prompt without the USB network or the
screen. It is also where kernel messages go before the display is up. On the A01 Core host an FTDI or
PL2303 adapter appears as `/dev/ttyUSB0` (CH341 and CP210x are not built into that kernel); wire it to
`serial1` and `screen /dev/ttyUSB0 115200`.

**The screen.** `getty@tty1.service` is enabled, which is the `x6525 login:` prompt on the display -
but touch cannot type, and `buffyboard`/`unl0kr` are installed without being wired to a getty, so the
screen is read-only for login today.

If USB networking does not come up - no interface, or no DHCP address - the usual cause is the cable
going in after the gadget was created; power-cycle with it connected. Otherwise the SC27xx role switch
did not report "device": `dmesg | grep -i -E 'musb|gadget'` on the phone (over the UART) and the
host's `dmesg` say which. `FIRST_BOOT.md` section 4 has the rest.

## Internet on the phone

The X6525 has no WiFi or Bluetooth driver in this kernel - the wcn block is powered, but there is no
mainline stack (`tools/audit-features.sh` lists it as known-missing) - so its uplink is the USB link to
the host, NATed out through the host's own connection. It runs over the same link SSH does.

On the host, as root (`<if>` is the current `usbN`; on the A01 Core's Android userland these are
iptables rules, and netd may flush them when WiFi reconnects - re-add them if the counters stop
moving):

```sh
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
iptables -A FORWARD -i <if> -o wlan0 -j ACCEPT
iptables -A FORWARD -i wlan0 -o <if> -m state --state RELATED,ESTABLISHED -j ACCEPT
```

On the phone, over SSH:

```sh
sudo ip route add default via 172.16.42.2 dev usb0
echo 'nameserver 1.1.1.1' | sudo tee /etc/resolv.conf
ping -c2 1.1.1.1
sudo apk update
```

Neither the route nor the resolver survives a reboot; the image ships `nmcli`, so the durable form is
a profile on the interface the initramfs already addresses (`172.16.42.1/24`):

```sh
sudo nmcli con add type ethernet ifname usb0 ipv4.method manual \
    ipv4.addresses 172.16.42.1/24 ipv4.gateway 172.16.42.2 ipv4.dns 1.1.1.1
```

`unudhcpd@usb0` is the DHCP *server* for the host, not a client on the phone, which is why the phone's
side has to be set by hand (or by that profile). If names do not resolve from the phone but `ping
172.16.42.2` works, watch the host's counters with `iptables -t nat -L -n -v`: a MASQUERADE rule that
never counts means Android dropped the forwarded traffic.

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
