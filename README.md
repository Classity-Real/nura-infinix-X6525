# nura-infinix-x6525

Infinix X6525 (UMS9230 / sprd) kernel port — postmarketOS.

- Kernel series: 65 upstream patches (`patches/upstream/`) against `v7.2-rc6-ums9230-0`
- UFS bring-up kept: `0048-arm64-dts-sprd-boot-the-X6525-s-UFS-units-too.patch` + `dts/` node
- Config: `CONFIG_LRU_GEN=y`, `CONFIG_DMABUF_HEAPS_CMA=y`, `CONFIG_CMA_SIZE_MBYTES=128`
- Package: `linux-postmarketos-unisoc-ums9230` pkgrel 56 (Seuj09 upstream, pkgrel 55 base)
- U-Boot board + MAC fix (local `0007-scan-ufs` + `0008-BT-WiFi-MAC`)
- Audit clean (`audit-features.sh` — 0 BROKEN for kernel package)
- pmbootstrap installed (`/usr/local/bin/pmbootstrap`, v3.12.1)
- CI passes (`a669ca1`); upstream branches (`feat/*`, `fix/*`) tracked at `upstream/`

Not an A06 core. This repo is the X6525 port only.
