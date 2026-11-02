# X6525 bring-up checklist

This is the Infinix X6525 (UMS9230) port — not A06 core.

- [ ] 65 kernel patches applied (`patches/upstream/`)
- [ ] UFS support preserved (`0048` patch + `&ufs` in dts)
- [ ] `CONFIG_LRU_GEN=y`, `CONFIG_DMABUF_HEAPS_CMA=y`, CMA 128 MiB
- [ ] `audit-features.sh` passes (0 BROKEN for `linux-postmarketos-unisoc-ums9230`)
- [ ] `pmbootstrap` available
- [ ] CI green (`build` + `uboot`)

Keep everything that is this port. Drop anything unrelated.
