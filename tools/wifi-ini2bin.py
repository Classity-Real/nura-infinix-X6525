#!/usr/bin/env python3
"""Convert Unisoc wifi_board_config.ini into the sectioned .bin that the
mainline sc23xx driver (sc23xx_load_config) downloads.

File format (from drivers/net/wireless/unisoc/main.c): repeated
    u16le magic 0x4353 | u16le size | payload[size]
one record per ini section, in order (section index is 1-based on the wire).

UNVERIFIED PART: the per-field widths below follow the open UWE5622/Marlin3
structs (unisocwifi/rf_marlin3.h) and the key order of this phone's ini. The
ini is a newer variant than UWE5622, so exact struct padding is a best guess.
Use --pad to add the 'reserved' bytes Marlin3 had. Check dmesg after loading.

usage: wifi-ini2bin.py in.ini out.bin [--pad]
"""
import re, struct, sys

# key -> struct format char per element (B u8, b s8, H u16, I u32)
WIDTH = {}
for k in ("Major", "Minor", "Calibration_Bypass"):
    WIDTH[k] = "H"
for k in ("TPC_Goal_Chain0", "TPC_Goal_Chain1"):
    WIDTH[k] = "H"
for k in ("reg_domain1", "reg_domain2", "address", "value"):
    WIDTH[k] = "I"
SIGNED = {"LNA_Bypass_Gain"}
PAD = {5: 2, 6: 2, 9: 2}  # optional trailing reserved bytes (Marlin3)

def parse(path):
    secs, cur = [], None
    for line in open(path, errors="replace"):
        line = line.split("#")[0].strip()
        if not line:
            continue
        if line.startswith("["):
            cur = []
            secs.append(cur)
            continue
        m = re.match(r"([\w-]+)\s*=\s*(.*)$", line)
        if m and cur is not None:
            vals = [int(v, 0) for v in re.split(r"[,\s]+", m.group(2).strip()) if v]
            cur.append((m.group(1), vals))
    return secs

def pack(secs, pad):
    out = bytearray()
    for idx, items in enumerate(secs, 1):
        body = bytearray()
        for key, vals in items:
            if idx == 13:
                fmt = "I"
            else:
                fmt = WIDTH.get(key, "b" if key in SIGNED else "B")
            for v in vals:
                if fmt == "B":
                    v &= 0xFF
                elif fmt == "b":
                    v = (v + 128) % 256 - 128
                elif fmt == "H":
                    v &= 0xFFFF
                else:
                    v &= 0xFFFFFFFF
                body += struct.pack("<" + fmt, v)
        if pad:
            body += bytes(PAD.get(idx, 0))
        out += struct.pack("<HH", 0x4353, len(body)) + body
    return bytes(out)

def main():
    a = [x for x in sys.argv[1:] if x != "--pad"]
    if len(a) != 2:
        sys.exit(__doc__)
    secs = parse(a[0])
    data = pack(secs, "--pad" in sys.argv)
    open(a[1], "wb").write(data)
    print(f"{len(secs)} sections, {len(data)} bytes -> {a[1]}")

if __name__ == "__main__":
    main()
