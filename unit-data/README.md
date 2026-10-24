# Stock-system data for this unit

This directory is where the phone's own data goes when it cannot be pasted into a chat: the stock
Android camera identification, the partition list, the modem dmesg and, if possible, the modem/NV
partition images. Commands and what each output decides are in
[BRING_UP_CHECKLIST.md](../BRING_UP_CHECKLIST.md) 5.1 and 5.2.

## What goes where

| file | what it is |
|---|---|
| `x6525-stock.txt` | the text outputs, one section each (template is in the file) |
| `bin/l_modem_a.img` | the modem image (`l_modem_a`, mmcblk0p20 on this unit) |
| `bin/l_fixnv*.img`, `bin/l_deltanv_a.img`, `bin/l_runtimenv*.img` | the unit's modem NV/IMEI |
| `bin/l_gdsp_a.img`, `bin/l_ldsp_a.img`, `bin/l_agdsp_a.img` | the modem DSP images |
| `bin/*.img` | any other partition named in the checklist (`prodnv`, `persist`, `productinfo`) |

Keep this directory to this unit's data; the files are text except `bin/`. Nothing here is used by
the build - it is input for the camera and modem work.

## How to add it

**From the GitHub web UI** (works from the phone, no clone):

1. Open `unit-data/x6525-stock.txt` in the repository.
2. Pencil icon -> paste the output under the right `##` heading -> *Commit changes* (to `main` is
   fine).
3. For a binary, *Add file -> Upload files* into `unit-data/bin/`. The web upload takes files up to
   25 MB; a modem partition is usually larger, so use one of the other routes below.

**From a clone** (phone or host):

```sh
git add unit-data/x6525-stock.txt unit-data/bin/modem.img
git -c user.name=... -c user.email=... commit -m "unit-data: stock Android outputs"
git push
```

**If a binary is too big** (the modem partitions are tens of MB): either push it with git (the limit
is 100 MB per file), split it (`split -b 20m l_modem_a.img l_modem_a.part.`), or leave it out and say
so in `x6525-stock.txt` - the partition list already says where everything is, and one or two of the
small NV partitions may be enough to start with.

## Why it has to come from the stock system

The camera's fitted sensor is not in the OTA, the vendor kernel source or the mainline tree - the
stock camera HAL identifies it at boot and stores it in `vendor.cam.sensor.slot.info` and in the
`productinfo` OTP directory names. The modem's images and the unit's NV (IMEI) are the `l_*` partitions
(`l_modem_a`, `l_fixnv1_a`, ...), not in any downloadable package. Both are per unit, so no amount of source reading
replaces them.
