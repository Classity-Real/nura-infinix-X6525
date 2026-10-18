#!/usr/bin/env python3
"""Self-test for wifi-ini2bin.py: framing the mainline loader requires, and the
section sizes implied by the Marlin3 field widths. Run: python3 -I tools/test-wifi-ini2bin.py"""
import os, struct, subprocess, sys, tempfile
here = os.path.dirname(os.path.abspath(__file__))
ini = """[Section 1: Version]
Major = 3
Minor = 0
[Section 2: x]
a = 0xDE, -5
[Section 8: Reg Domain]
reg_domain1 = 0x00000001
reg_domain2 = 0x00000002
[Section 11: misc]
LNA_Bypass_Gain = -5
[Section 12: debug reg]
address = 0x1,0x2
"""
with tempfile.TemporaryDirectory() as d:
    i, o = os.path.join(d, "a.ini"), os.path.join(d, "a.bin")
    open(i, "w").write(ini)
    subprocess.run([sys.executable, "-I", os.path.join(here, "wifi-ini2bin.py"), i, o], check=True, capture_output=True)
    data = open(o, "rb").read()
off, secs = 0, []
while off < len(data):
    magic, size = struct.unpack_from("<HH", data, off)
    assert magic == 0x4353, "bad magic"
    secs.append(data[off + 4: off + 4 + size]); off += 4 + size
assert off == len(data), "trailing bytes"
assert len(secs) == 5
assert secs[0] == bytes([3, 0, 0, 0]), secs[0]            # u16 Major, u16 Minor
assert secs[1] == bytes([0xDE, 0xFB]), secs[1]            # u8 values, -5 wraps
assert secs[2] == struct.pack("<II", 1, 2)                # u32 reg domains
assert secs[3] == bytes([0xFB])                           # s8 -5
assert secs[4] == struct.pack("<II", 1, 2)                # u32 debug addresses
print("ok")
