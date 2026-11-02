# Debug shell — this port (X6525 / UMS9230)

Not an A01 Core guide. For the X6525 board only.

- UART: `ttyS1`
- USB gadget for SSH: `cdc_ncm` / `cdce` (host-independent)
- Kernel cmdline carries `console=ttyS1`

If you need host setup: any Linux host with USB-C/OTG adapter; no Galaxy A01-specific steps required.
