# First boot — X6525 (UMS9230)

This is the Infinix X6525. Not A01 Core.

- Storage: eMMC (`sdio3`) or UFS (`&ufs` with `vcc-supply = <&vddemmccore>`)
- RootFS label-based; initramfs grows to partition
- `boot_a` / `boot_b` via `deviceinfo`
- Config preserved: `CONFIG_LRU_GEN=y`, `CONFIG_DMABUF_HEAPS_CMA=y`, CMA 128 MiB
