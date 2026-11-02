# nura-infinix-x6525 — pmos env checklist + commands + credits

Infinix X6525 (UMS9230 / sprd). Not A01 / A06.

## What works on pmos env
- [x] Kernel builds (`linux-postmarketos-unisoc-ums9230`) — audit `ok`
- [x] Device package builds (`device-infinix-x6525`) — `sha512sum` fixed
- [x] `pmbootstrap` installed (`/usr/local/bin/pmbootstrap` v3.12.1)
- [x] 67 kernel patches (`patches/upstream/`) — `0048` UFS preserved
- [x] Black-screen / panel path preserved (`sprd_drm` + `simpledrm`)
- [ ] Wifi drops (`fix/wifi-drops` upstream branch tracked — not merged)
- [ ] GPU accel (`feat/gpu-accel` tracked — not merged)
- [x] `dts/` UFS node (`&ufs`) intact
- [x] CI green on `main`

## Console commands
```bash
# build kernel package
pmbootstrap build linux-postmarketos-unisoc-ums9230

# audit
bash tools/audit-features.sh

# check patches
ls patches/upstream/0*.patch | wc -l

# verify dts UFS node
grep '&ufs' dts/ums9230-infinix-x6525.dts

# push (force-with-lease safe)
git push --force-with-lease origin main
```

## Credits
- Seuj09 upstream (`a7f8004`) — kernel patches `0066`/`0067`, megapixels fixes
- Port maintainer — UFS `0048`, black-screen fix (`sprd_drm`/`simpledrm`), device fixes
- `pmbootstrap` v3.12.1 install
