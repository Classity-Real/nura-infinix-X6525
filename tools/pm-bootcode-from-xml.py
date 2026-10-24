#!/usr/bin/env python3
"""Turn the vendor modem_sp_info.xml into pm_bootcode.bin.

The pmsys co-processor's 4 KB boot window at 0x62010000 is filled from a
bootcode word list that the vendor's partition table carries as an XML
attribute, not from a partition.  sprd_pmsys requests the result as
sprd/pm_bootcode.bin and copies it verbatim.

Usage: pm-bootcode-from-xml.py <modem_sp_info.xml> <pm_bootcode.bin>

The words are hex (0x...) or decimal, separated by spaces, and written
little-endian.  This is the same conversion as convert_bootcode.py in the
Jolla C2's device-bsp-s19mps tree, which is where the file name and the
mechanism were found.

The X6525's XML is proprietary/vendor/etc/modem_sp_info.xml in the public
Bocchi-The-Dev/vendor_X6525 tree.  Its pm_sys_bootcode entry has 31 words.
"""

import sys
import xml.etree.ElementTree as etree


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)

    doc = etree.parse(sys.argv[1])
    for part in doc.find("partion_item"):
        bootcode = part.get("bootcode")
        if bootcode is None:
            continue
        words = [int(word, 0) for word in bootcode.split()]
        with open(sys.argv[2], "wb") as out:
            for word in words:
                out.write(word.to_bytes(4, "little"))
        print(
            "%s: %d words (%d bytes) from %s"
            % (sys.argv[2], len(words), len(words) * 4, part.get("name")),
            file=sys.stderr,
        )
        return

    sys.exit("no partition with a bootcode attribute in %s" % sys.argv[1])


if __name__ == "__main__":
    main()
