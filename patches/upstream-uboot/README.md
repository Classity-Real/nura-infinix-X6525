# U-Boot board patches

Eight patches for [codeberg.org/ums9230-mainline/u-boot](https://codeberg.org/ums9230-mainline/u-boot),
split the way that fork splits its own board commits - one device tree, one defconfig, one environment
file, a debug one that prints the last kernel log (pstore) before booting (drop that one for anything
but bring-up), the pmicwdt command the bootcmd uses, the UFS scan (patch 7), and the prodnv MAC
preboot (patch 8). The UFS scan exists because some X6525 units shipped UFS instead of the eMMC on
sdio3: the defconfig keeps the reeder's CMD_UFS/SCSI/UFS/UFS_SPRD_UMS9230, the device tree enables
`&ufs`, and the environment scans `scsi` right after `mmc`. The MAC preboot reads the unit's own
`btmac.txt` and `wifimac.txt` from the eMMC `prodnv` partition, and falls back to the UFS one
(`sspi 0 00; ufs init; scsi scan; load scsi 0#prodnv ...`) when either file was not on eMMC, so
both storage variants get their real MACs. The fork marks its
own Reeder device tree commit `WIP:`; these do not, since the board builds in CI and the values that
came from the Reeder have been checked against this phone. Verified with `git am` to apply in order
to a clean checkout and to reproduce byte-identical files to what CI builds.

```sh
git clone --depth 1 --branch ums9230 https://codeberg.org/ums9230-mainline/u-boot
git -C u-boot am "$PWD"/patches/upstream-uboot/0*.patch
```

`tools/apply-uboot-overlay.sh` does the same without `git am`, which is what CI uses (the build is
`make ARCH=arm infinix-x6525_defconfig && make ARCH=arm`, natively — the fork's mach-sprd selects
ARM64 for `TARGET_UMS9230`, which is why the pmaports package is `pmb:cross-native`).

Where it goes: the fork first (Codeberg PR), then mainline U-Boot by mail (`u-boot@lists.denx.de`) once
the SoC support itself lands there. Same rule as the kernel patches: read them and own them before
submitting — Codeberg restricts LLM-generated contributions.

## Untested on hardware

First things to check when it runs:

- whether eMMC comes up on `sdio3` — the reeder boots from UFS, so that path is less exercised. The
  microSD slot is enabled as a rescue route for exactly this reason.
- whether UFS comes up on `scsi` — no UFS unit has been flashed, and FIRST_BOOT.md, "Storage
  variants", is the first-boot check list for one.
- `CONFIG_SYS_BOOTM_LEN=0x800000` (8 MB, also copied) — worth watching if the uncompressed arm64
  `Image` on the boot partition ever exceeds it.
- whether the `prodnv` partition really holds `btmac.txt` and `wifimac.txt` (FAT), on eMMC and on
  UFS. The preboot reads both from `load mmc 0#prodnv ...` first and retries the missing one from
  `load scsi 0#prodnv ...` after bringing up UFS, and only sets `bdaddr`/`wifiaddr` when a load
  succeeds; `printenv bdaddr wifiaddr` at the U-Boot prompt is the test. If they are empty, the
  kernel keeps its random-BD-address fallback and the Wi-Fi MAC service, and the partition's
  contents are the thing to check.

Settled since this was written: the memory node is the **4 GiB** window this phone reports
(`0x0 0x80000000 0x0 0xfffff000`, from `androidboot.ddrsize=4096M`), not the Reeder's 8 GiB one, and
the DTB inside the CI-built `u-boot.bin` carries it.

## Deliberately not included

No extra `board/` directory and no Kconfig or Makefile change beyond 0006's pmicwdt command:
`SYS_BOARD` and `SYS_CONFIG_NAME` already
default to `ums9230` for `TARGET_UMS9230`.
