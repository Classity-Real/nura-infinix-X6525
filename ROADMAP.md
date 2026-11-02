# Roadmap — X6525 port (UMS9230 / sprd)

Not A06 core. Focus items for this device:

- Kernel: stay with Seuj09 upstream series (currently 65 patches, pkgrel 56)
- UFS: keep `0048` bring-up; do not drop in favor of pure eMMC
- Camera / GPU / display: follow `patches/upstream/` (0050 LED, 0053 650 MHz GPU, 0054/64/65 sensor fixes)
- CI / audit: keep `audit-features.sh` green; rebuild `README`s when upstream changes
- pmbootstrap / build: maintain at `/usr/local/bin/pmbootstrap`
