# Per-unit data (do not commit it)

This directory started as a place to drop the stock system's per-unit data. It is a **public**
repository, and it turned out that the useful files carry identifiers: the live device tree has the
serial number, and the modem's NV partition has the IMEI. They are not kept here any more, and
nothing here should be committed except this README and the fill-in template.

Use `x6525-stock.txt` to record what the phone reports (it is text and, as long as identifiers are
redacted, safe to commit). Hand over anything binary - device trees, partition images - privately,
or keep it out of git.

## What each piece is for

Commands and what each output decides are in [BRING_UP_CHECKLIST.md](../BRING_UP_CHECKLIST.md) 5.1
(camera) and 5.2 (modem).

| data | what it is for | keep it out of git |
|---|---|---|
| `x6525-stock.txt` | text outputs, one section each (template in the file) | redact serial/IMEI |
| live device tree (`/sys/firmware/fdt`) | the board's real sensor/modem nodes | yes - carries the serial |
| modem partitions (`l_*`) | firmware the modem remoteproc loads | yes - NV carries the IMEI |

The port no longer ships the modem images: `x6525-modem-nv.service` copies them out of the unit's
own partitions at boot, so every phone uses its own. The sizes and trims are in the checklist.

## Why it has to come from the stock system

The camera's fitted sensor is not in the OTA, the vendor kernel source or the mainline tree - the
stock camera HAL identifies it at boot and stores it in `vendor.cam.sensor.slot.info`. The modem's
images and the unit's NV are in its `l_*` partitions. Both are per unit, so no amount of source
reading replaces them, and both are why this directory exists at all.
