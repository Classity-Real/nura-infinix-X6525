# Kernel patches for the ums9230-mainline tree

Twenty-five patches, cut against `v7.2-rc6-ums9230-0` (the tag the pmaports kernel package pins) and verified
to apply **in this order** to a clean checkout of it, producing byte-identical files to `dts/`,
`drivers/` and `bindings/` — i.e. to what CI compiles.

| # | Patch | Where it belongs |
|---|---|---|
| 1 | `dt-bindings: vendor-prefixes: add Infinix Mobility` | bindings/mainline; patch 2 needs it |
| 2 | `dt-bindings: arm: sprd: add Infinix X6525 board` | bindings/mainline |
| 3 | `arm64: dts: sprd: add device tree for Infinix X6525` | the ums9230 tree |
| 4 | `drm/panel: add driver for the TD4160 HX 720x1612 panel` | the ums9230 tree, later drm-misc |
| 5 | `dt-bindings: input: add OmniVision TCM SPI touchscreen` | bindings/mainline |
| 6 | `Input: add OmniVision TCM SPI touchscreen driver (host download)` | the ums9230 tree, later input |
| 7 | `dt-bindings: power: supply: add extcon-backed USB charger detection` | bindings/mainline |
| 8 | `power: supply: add extcon-backed USB charger detection` | the ums9230 tree, later power-supply |
| 9 | `dt-bindings: gpio: sprd: allow gpio-hog nodes` | bindings/mainline; independent of this board |
| 10 | `dt-bindings: power: supply: sc27xx-fg: allow power-supplies` | bindings/mainline; independent of this board |
| 11 | `watchdog: sprd_wdt: keep a watchdog the bootloader started fed` | watchdog; independent of this board |
| 12 | `spi: sprd: fix full-duplex PIO/DMA RX length and interrupt status clear` | the ums9230 tree; needed by the touch driver's reads |
| 13 | `Bluetooth: btsprdsipc: fall back to a random BD address` | the ums9230 tree; this board's `bdaddr` env is unset, so U-Boot writes zeros |
| 14 | `media: i2c: add a Samsung S5K3L6 sensor driver` | the ums9230 tree for now; the Librem 5 RFC series is the upstream vehicle. Its mode tables are from the vendor HAL, not from upstream |
| 15 | `arm64: dts: sprd: add the rear camera to the Infinix X6525` | the ums9230 tree, with patch 3 |
| 16 | `power: supply: bq2415x: expose the OTG boost as a regulator` | power-supply, later mainline |
| 17 | `arm64: dts: sprd: give the X6525's charger an OTG boost regulator` | the ums9230 tree, with patch 3 |
| 18 | `arm64: dts: sprd: give the X6525's GPU its stock DVFS table` | the ums9230 tree, with patch 3 |
| 19 | `drm/panel: td4160-hx: add the panel's 90 Hz mode` | the ums9230 tree, later drm-misc with 4 |
| 20 | `arm64: dts: sprd: add the front camera to the Infinix X6525` | the ums9230 tree, with patch 3 |
| 21 | `arm64: dts: sprd: throttle the X6525's GPU at the SoC's thermal point` | the ums9230 tree, with patch 3 |
| 22 | `mmc: sdhci-sprd: add an opt-in override for the HS200 quirk` | **bring-up only, not for submission** - a boot-time knob for the eMMC link |
| 23 | `drm/panel: td4160-hx: keep the stock 60 Hz mode preferred` | the ums9230 tree, later drm-misc with 4 and 19 |
| 24 | `drm/panel: td4160-hx: fix post-command delays and power gpios` | the ums9230 tree, later drm-misc with 4, 19 and 23 |
| 25 | `drm/sprd: enable LP cmd tx and clean boot handoff` | the ums9230 tree, later drm-misc |

Patch 3 adds the touch node together with the rest of the board, and 5 and 6 document and drive it;
14 and 15 add the rear camera, which patch 3 does not describe, and 20 adds the front one, a
gpio-hog for its power-down pin and the two-lane camsys port; 16 adds a regulator to the charger
driver and 17 wires it into the board; 21 adds GPU devfreq cooling to the SoC's existing gpu-thermal
zone. 22 is deliberately not upstream material: the driver marks HS200 broken for every r11
controller, and the X6525's eMMC is the root filesystem, so the override is opt-in via
`sdhci_sprd.enable_hs200=1` until it has run on hardware. 23 restores the panel's stock default:
the board DT's native-mode is timing0 (60 Hz), so 19's 90 Hz mode stays available but is no longer
preferred. The series is only consistent once all twenty-three are applied, which is what the
verification below checks.
Patch 3 also carries the `dtb-y` entry in `arch/arm64/boot/dts/sprd/Makefile` — the ROM's kernel
package applies this series with `patch -p1` and then runs `dtbs_install`, so a patch 3 without that
hunk builds no DTB for this board and the image build fails in boot-deploy looking for
`sprd/ums9230-infinix-x6525.dtb`. Regenerate it with that hunk in place; CI now greps for it.
The build inputs CI applies are separate: `../0001-x6525-build-glue.patch` and
`../0002-x6525-touch-glue.patch`, `../0003-x6525-charger-glue.patch` and `../0004-x6525-gpio-hog-glue.patch` (the same hunks as 1, 2, 4, 5/6's Kconfig and Makefile entries, so a
local build and CI put the same thing in the tree).

```sh
git clone --depth 1 --branch v7.2-rc6-ums9230-0 https://codeberg.org/ums9230-mainline/linux
git -C linux am "$PWD"/patches/upstream/0*.patch
```

`tools/apply-overlay.sh` does the equivalent without `git am`, which is what CI uses.

## Sending them

- **Patches 3 and 4** go to the ums9230 tree first (Codeberg PR, or to the maintainer). That tree's own
  device tree commits carry a `WIP:` prefix; ours do not any more, since the file has no TODOs left and
  every value in it is traced to a named source.
- **Patches 1 and 2**, and ultimately the driver, go to mainline by mail: `devicetree@vger.kernel.org`
  for the bindings and `dri-devel@lists.freedesktop.org` for the panel driver, with the SoC/bindings
  maintainers copied. Keep the binding separate from the driver there, as the series already does.

## Before sending

- The `Signed-off-by:` line is `Seuj09 <jeus110310@gmail.com>`, the identity used in this repo. Amend it
  if you sign off differently (`git rebase -i` with `--signoff`).
- **Codeberg's rules restrict LLM-generated contributions.** Read every line and make the patches yours
  before you submit: the panel sequence is a mechanical conversion of your own device's DT, and the
  device-tree values are extracted from your firmware, but the review and the sign-off are yours.
- None of it has run on hardware. What the file can no longer get wrong, from the live device tree: the
  storage layout, the GPIOs, the charger, the battery profile and the pstore reservation are all read
  off the running system. What still needs the hardware: the panel **reset polarity** (vendor says
  active-high), the **brightness curve** (linear here), the eMMC and SD **phy delay tuning** (the
  vendor's own values, unverified against mainline's driver) and the touch **firmware download**.
  `../../FIRST_BOOT.md` has the list in the order it will matter.

## Not included

The camera flash controller and focus motor (no mainline drivers), the WiFi/Bluetooth/GNSS/pmsys
firmware and their extraction services (packages, not kernel changes), and the camera userspace.
The U-Boot board and the touch driver are separate series: `../upstream-uboot/` and patches 5/6
here.
