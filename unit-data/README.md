# Stock-system data for this unit

This directory is where the phone's own data goes when it cannot be pasted into a chat: the stock
Android camera identification, the partition list, the modem dmesg and, if possible, the modem/NV
partition images. Commands and what each output decides are in
[BRING_UP_CHECKLIST.md](../BRING_UP_CHECKLIST.md) 5.1 and 5.2.

## What goes where

| file | what it is |
|---|---|
| `x6525-stock.txt` | the text outputs, one section each (template is in the file) |
| `bin/modem.img` | the modem partition (only if it can be pushed; it carries the modem images and the unit's NV/IMEI) |
| `bin/*.img` | any other partition named in the checklist (`nvdata`, `prodnv`, `persist`, `productinfo`) |

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

**If the binary is too big** (modem partitions can be 64-256 MB): either push it with git (the limit
is 100 MB per file), split it (`split -b 20m modem.img modem.part.`), or leave it out and say so in
`x6525-stock.txt` - the `find` and `ls` outputs already say where the modem images are, and a
smaller partition (or just the firmware files) may be enough to start with.

## Why it has to come from the stock system

The camera's fitted sensor is not in the OTA, the vendor kernel source or the mainline tree - the
stock camera HAL identifies it at boot and stores it in `vendor.cam.sensor.slot.info` and in the
`productinfo` OTP directory names. The modem's images and the unit's NV (IMEI) are in the `modem`
partition, not in any downloadable package. Both are per unit, so no amount of source reading
replaces them.
