# nura-infinix-x6525 — Advanced Checklists

Infinix X6525 (UMS9230 / sprd). Not A01 Core. Not A06.

## Works / Checklist
- [x] Kernel: 67 patches (`patches/upstream/`) vs `v7.2-rc6-ums9230-0`; `0066`/`0067` merged (upstream `a7f8004`)
- [x] UFS: `0048-arm64-dts-sprd-boot-the-X6525-s-UFS-units-too.patch` preserved; `&ufs` node in `dts/`
- [x] Black-screen / panel: `simpledrm` console + `sprd_drm` path kept; `panel` `okay`; `WLR_RENDERER=pixman` available
- [x] Config overrides: `CONFIG_LRU_GEN=y`, `CONFIG_DMABUF_HEAPS_CMA=y`, `CONFIG_CMA_SIZE_MBYTES=128`
- [x] Userspace patches removed: `libdng-*`, `libmegapixels-*`, `megapixels-*` (not kernel source)
- [x] Audit: `linux-postmarketos-unisoc-ums9230` — `ok`; `result: no broken package...`
- [x] Device package: `sha512sum` fixed (`kernel-cmdline.conf`, `x6525-boot-check`)
- [x] pmbootstrap: `/usr/local/bin/pmbootstrap` v3.12.1
- [x] CI green; upstream branches (`feat/*`, `fix/*`) tracked at `upstream/`
- [x] Readmes remade (no A01/A06 references)

## What's left / UEFI
- [ ] UEFI port (next chat)
- [ ] `libmegapixels` userspace build (separate repo)
