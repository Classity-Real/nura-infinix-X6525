# Touch firmware

`hdl_firmware_01.img` is the HDL image the Omnivision TD4160 touch controller needs. The controller has
no flash, so after every reset the driver has to download it - without this file there is no
touchscreen.

## Where it came from

Copied off the phone itself, out of the stock firmware partition:

```
/vendor/firmware/hdl_firmware_01.img
```

It is the image the module the stock ROM runs actually asks for. The images shipped in the stock
*kernel tree* (`hdl_firmware_0/1.img`, `_b.img`, `_limu.img`) are a different panel project: their
driver selects by a name table of "cw" variants that does not contain `lcd_td4160_hx_*`, and the file
that matters here is the one on the device.

```
158893 bytes
sha512  7a50601faa6229a736111f6458aa30acef8c83c4cb30da5be9520996278106770cd34a16e0a7b169a58b9d78c56bfd04cd830ac79cc0a0dbf6e2531581e7c47a
```

`tools/check-hdl-image.py` verifies it against the rules the driver applies in `tcm_parse_image()`:

```
area 0: BOOT_CONFIG      len=256
area 1: ROMBOOT_APP_CODE len=102400
area 2: APP_CONFIG       len=4096
area 3: DISPLAY          len=8192      <- the panel-specific config
area 4: OPEN_SHORT       len=4096
area 5: not an area, skipped by the driver
valid: the driver will accept this image
```

Note area 3: the stock kernel tree's `hdl_firmware_1.img` has no `DISPLAY` area at all, which is
further confirmation that it is not the right image for this panel.

## The package

`../pmaports/device/testing/firmware-infinix-x6525/APKBUILD` installs this file as
`/lib/firmware/postmarketos/sprd/hdl_firmware_01.img`, which is what the board device tree's
`firmware-name` points at.

`firmware-infinix-x6525-1.tar.gz` next to this file is the upload artifact, built so that rebuilding it
gives the same bytes:

```sh
cd firmware
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='@0' -cf - hdl_firmware_01.img \
    | gzip -n -9 > firmware-infinix-x6525-1.tar.gz
sha512sum firmware-infinix-x6525-1.tar.gz
```

```
124616 bytes
sha512  a8ae389d7479ad8b3226cfb3a0d153f5306cdbe6a9b85e31584c5e6c7c34232a06562134ac9b3669fb4a0919e3335a830bd2b7b08a87e132c500d22fe70fa176
```

If a different gzip produces different bytes, upload the tarball you built and update the checksum in
the APKBUILD to match.

## Where the package fetches it from

This repository is public, so the package takes the tarball straight out of it, pinned to the commit
that added it — the URL is immutable and the port's own CI fetches it and compares it against the
APKBUILD's sha512 on every push, so a changed file cannot pass unnoticed:

```
https://raw.githubusercontent.com/Seuj09/pmos-infinix-x6525/186e3e0f21e12ffa194ca4a740053fc977b9c5ff/firmware/firmware-infinix-x6525-1.tar.gz
```

`.github/workflows/firmware-release.yml` can also put a versioned copy on this repository's releases,
for a stable link to quote; nothing depends on it.

The image is `proprietary` vendor firmware, which is why the device package depends on it: without
the touch firmware the controller cannot run at all.

# Wi-Fi, Bluetooth and GNSS firmware

`firmware-infinix-x6525-wcn-3.tar.gz` holds everything the WCN block needs. The three binaries that
are not generated here come off the stock ROM's ODM partition:

```
/odm/firmware/wcnmodem.bin          1258536 bytes  sprd/wcnmodem.bin
/odm/firmware/wifi_board_config.ini                -> sprd/wifi_board_config.bin
/odm/firmware/bt_configure_pskey.ini               -> sprd/bt_config_pskey.bin
/odm/firmware/bt_configure_rf.ini                  -> sprd/bt_config_rf.bin
```

- `wcnmodem.bin` is the WCN subsystem image: `sprd_wcn` (remoteproc) loads it, and its BT and GNSS
  cores run from it. It is also the one name the device tree's `btwf` child names.
- `wifi_board_config.bin` is `tools/wifi-ini2bin.py`'s output: `sc23xx_wlan` requests it and sends
  it to the chip as four CRC-framed sections. The converter reproduces the stock
  `sprd_wlan_combo.ko`'s `g_config_table` layout, so the bytes are the ones the stock driver would
  have sent.
- `bt_config_pskey.bin` (160 bytes) and `bt_config_rf.bin` (252 bytes) are `tools/bt-ini2bin.py`'s
  output. `btsprdsipc` sends them as the payloads of HCI 0xfca0 and 0xfca2 after downloading the
  BD address into the pskey struct at offset 20. This is not optional: `btsprdsipc_probe()` requests
  both files and **fails the probe** if either is missing, so without them there is no HCI device
  and Bluetooth never appears. The sizes are what the stock INI headers announce
  (`Total Length=160` / `=252`), and the field tables were cross-checked against the marlin3 tables
  in `device-bsp-s19mps`'s `convert_ini.py` (Jolla C2, the same WCN block); both converters produce
  identical bytes for these INIs.

The tarball rebuilds byte for byte from a staging directory `sprd/` holding exactly those four files:

```sh
cd firmware
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='@0' -cf - sprd \
    | gzip -n -9 > firmware-infinix-x6525-wcn-3.tar.gz
```

The package installs them as `/lib/firmware/sprd/...`, which is the path the drivers request
(`sprd/wcnmodem.bin`, `sprd/wifi_board_config.bin`, `sprd/bt_config_pskey.bin`,
`sprd/bt_config_rf.bin`). The touch image is separate because its driver asks for
`postmarketos/sprd/hdl_firmware_01.img` by device-tree `firmware-name`.

## The Bluetooth address

The dtsi's `bluetooth@10` node has `local-bd-address = [00 00 00 00 00 00]` with the comment
"filled in by bootloader". This port chainloads U-Boot from `boot_a`, and that U-Boot does not patch
the property, so the HCI core would skip `set_bdaddr()` - the function that sends the two config
blobs - and the controller would register but never be initialised. Patch 0013 in
`patches/upstream/` makes the driver fall back to a random, locally administered address in that
case, so Bluetooth works, but the address (and with it pairing records) changes on every boot. A
stable address needs the bootloader (or a per-device DTS) to supply one; until then this is a known
limitation, not a configuration error.
