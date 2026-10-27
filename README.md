# Nura — postmarketOS on Infinix X6525

Unisoc UMS9230 (T606). Mainline kernel + U-Boot on `boot_a`.

## Status

| Piece | State |
|-------|--------|
| Boot / SSH | works |
| Touch | works |
| GPU (Panfrost) | works |
| Wi‑Fi | associated; use NM powersave off (device package) if sites hang after DNS |
| Bluetooth | BlueZ + btsprdsipc; short pskey configs are rejected (kernel patch) |
| Cameras | DT + sensor modules present; ISP/userspace still incomplete |
| Modem / GNSS | partial / unit firmware on device |

Password for `user` is whatever the image was built with (`1234` or `x6525pmos` — check the workflow).

## Flash

```sh
fastboot flash boot_a   boot.img
fastboot flash cache    pmos-boot-fs.img
fastboot flash userdata pmos-root-fs.img
fastboot reboot
```

Same-build `cache` + `userdata` when both change. `fastboot -w` wipes both.

## USB SSH (first minutes)

Phone: `172.16.42.1` — host: `172.16.42.2`

```sh
# host
ip link set usb0 up
ip addr add 172.16.42.2/24 dev usb0
ssh user@172.16.42.1
```

If Wi‑Fi is up and websites fail but DNS works, USB is probably still the default route:

```sh
# on phone
ip route
sudo nmcli connection modify usb0 ipv4.never-default yes 2>/dev/null || true
sudo ip route del default dev usb0 2>/dev/null || true
```

## Docs

- [FIRST_BOOT.md](FIRST_BOOT.md) — flash + first boot
- [BRING_UP_CHECKLIST.md](BRING_UP_CHECKLIST.md) — touch, Wi‑Fi, UI, GPU
- [NOTES.md](NOTES.md) — hardware notes
- [ROADMAP.md](ROADMAP.md) — what’s left

## Build

GitHub Actions: **Build PMOS** (`ci.yml`). Artifact: `x6525-rom`.

Upstream reference for display/Wi‑Fi patches: [Seuj09/pmos-infinix-x6525](https://github.com/Seuj09/pmos-infinix-x6525).

Old 5.4 Helix tree under `linux-infinix-x6525/` is reference only.
