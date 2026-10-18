#!/usr/bin/env python3
"""Replace the U-Boot payload inside an existing boot_a image, keeping everything else.

    python3 -I tools/swap-uboot.py <old boot.img> <new u-boot.bin> <out boot.img>

The stock bootloader is picky about the boot image, so instead of building a new
one this keeps the header (version 4, os_version, cmdline) and the dummy ramdisk
of an image that is known to start, and only swaps the kernel section, which
holds u-boot.bin. Run tools/check-boot-img.py on the result before flashing.
"""
import struct
import sys

PAGE = 4096


def pad(b):
    return b + b"\0" * (-len(b) % PAGE)


def main(argv):
    if len(argv) != 4:
        print(__doc__)
        return 2
    old = open(argv[1], "rb").read()
    new_kernel = open(argv[2], "rb").read()
    if old[:8] != b"ANDROID!":
        print("not an Android boot image")
        return 1
    ksz, rsz = struct.unpack_from("<II", old, 8)
    version = struct.unpack_from("<I", old, 40)[0]
    if version != 4:
        print("header version %d, expected 4" % version)
        return 1
    if new_kernel[:2] == b"MZ" or new_kernel[:4] == b"\x7fELF" or len(new_kernel) < 100000:
        print("that does not look like u-boot.bin (size %d)" % len(new_kernel))
        return 1
    hdr = bytearray(old[:PAGE])
    struct.pack_into("<I", hdr, 8, len(new_kernel))
    ramdisk_off = PAGE + len(pad(b"\0" * ksz))
    rest = old[ramdisk_off:]  # ramdisk (+ padding) and anything after it, e.g. a signature
    out = bytes(hdr) + pad(new_kernel) + rest
    open(argv[3], "wb").write(out)
    print("old kernel section %d bytes -> new %d bytes, image %d bytes" % (ksz, len(new_kernel), len(out)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
