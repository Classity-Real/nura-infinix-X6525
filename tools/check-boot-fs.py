#!/usr/bin/env python3
"""
Check that the boot filesystem of a build holds what U-Boot's extlinux will ask for.

    python3 -I tools/check-boot-fs.py pmos-boot-fs.img [sprd/ums9230-infinix-x6525.dtb]

U-Boot (bootstd, extlinux) reads /extlinux/extlinux.conf and then loads the kernel,
initramfs and device tree it names. A mismatch - a dtb that is not where `fdtdir` and
U-Boot's default fdtfile point, a missing initramfs - ends at the prompt with a message
on a screen nobody is looking at. This reads the filesystem with debugfs (no root, no
loop device) and fails if any named file is missing. The second argument is U-Boot's
CONFIG_DEFAULT_FDT_FILE, used when the config says `fdtdir` instead of `fdt`.

It also fails if the append line pins `pmos_root_uuid=`: that makes the initramfs
accept only one rootfs filesystem UUID, so a boot filesystem flashed over an older
rootfs stops at "Waiting for root partition". The X6525 device package installs a
boot-deploy hook that rewrites / and /boot to labels, so the generated append line
has no UUID and the initramfs uses its pmOS_root label fallback. Pass
--allow-root-uuid for a build where pinning is intentional (e.g. full disk
encryption, where boot-deploy takes the UUID from /etc/crypttab).
"""
import re
import subprocess
import sys


def dbg(img, cmd):
    r = subprocess.run(["debugfs", "-R", cmd, img], capture_output=True, text=True)
    return r.stdout


def exists(img, path):
    return "Inode:" in dbg(img, f"stat {path}")


def main():
    argv = sys.argv[1:]
    allow_root_uuid = "--allow-root-uuid" in argv
    argv = [a for a in argv if a != "--allow-root-uuid"]
    if len(argv) not in (1, 2):
        sys.exit(__doc__)
    img = argv[0]
    fdtfile = argv[1] if len(argv) == 2 else "sprd/ums9230-infinix-x6525.dtb"
    conf = dbg(img, "cat /extlinux/extlinux.conf")
    if "label" not in conf.lower() and "linux" not in conf.lower() and "kernel" not in conf.lower():
        print(f"FAIL: no usable /extlinux/extlinux.conf in {img}")
        return 1
    print("extlinux.conf:")
    for line in conf.splitlines():
        if line.strip():
            print("   " + line)
    kernel = initrd = fdt = fdtdir = None
    for line in conf.splitlines():
        w = line.strip().split(None, 1)
        if len(w) != 2:
            continue
        k, v = w[0].lower(), w[1].strip()
        if k in ("kernel", "linux"):
            kernel = v
        elif k == "initrd":
            initrd = v
        elif k == "fdt":
            fdt = v
        elif k == "fdtdir":
            fdtdir = v
    bad = 0

    if "pmos_root_uuid=" in conf:
        if allow_root_uuid:
            print("WARN: pmos_root_uuid is pinned (allowed)")
        else:
            print("FAIL: the append line pins pmos_root_uuid; a cache-only flash")
            print("      over an older rootfs will stop at 'Waiting for root partition'.")
            print("      Check the device package's boot-deploy root-label hook.")
            bad += 1
    else:
        print("ok  : no pmos_root_uuid; the initramfs uses the pmOS_root label fallback")

    def need(what, path):
        nonlocal bad
        p = path if path.startswith("/") else "/" + path
        ok = exists(img, p)
        print(f"{'ok  ' if ok else 'FAIL'}: {what} {p}")
        bad += not ok

    if not kernel:
        print("FAIL: extlinux.conf names no kernel")
        return 1
    need("kernel", kernel)
    if initrd:
        need("initrd", initrd)
    else:
        print("WARN: no initrd line")
    if fdt:
        need("fdt", fdt)
    elif fdtdir:
        need("fdtdir + default fdtfile", fdtdir.rstrip("/") + "/" + fdtfile)
    else:
        print("FAIL: neither fdt nor fdtdir: U-Boot would hand the kernel its own device tree")
        bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
