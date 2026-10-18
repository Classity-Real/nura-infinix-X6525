#!/usr/bin/env python3
"""Self-test for wifi-ini2bin.py. Run: python3 -I tools/test-wifi-ini2bin.py [stock.ini]"""
import importlib.util, os, struct, subprocess, sys, tempfile
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("w", os.path.join(here, "wifi-ini2bin.py"))
w = importlib.util.module_from_spec(spec); spec.loader.exec_module(w)

# CRC-16/MODBUS check value
assert w.crc16(b"123456789") == 0x4B37, hex(w.crc16(b"123456789"))

ini = """[Section 1: Version]
Major = 3
Minor = 0
Calibration_Bypass = 0x0dee
TPC_Goal_Chain0 = 1,2,3
Chain1_1 = 9,9
LNA_Bypass_Gain = -5
reg_domain1 = 0x00000001
rf_config = 0xAA,0x55,0x00
bogus_key = 1
"""
with tempfile.TemporaryDirectory() as d:
    p = os.path.join(d, "a.ini"); open(p, "w").write(ini)
    buf, rf_len, unknown = w.parse(p)
assert unknown == ["bogus_key"] and rf_len == 3
assert buf[0:4] == bytes([3, 0, 0, 0])
assert buf[4:6] == struct.pack("<H", 0x0dee)
assert buf[16:22] == struct.pack("<HHH", 1, 2, 3)              # u16 values at offset 16
assert buf[980:982] == bytes([9, 9])                           # Chain1_1 is NOT next to Chain0_1
assert buf[1612] == 0xFB                                       # s8 -5
assert buf[280:284] == struct.pack("<I", 1)                    # u32 at 280
assert buf[1828:1832] == struct.pack("<I", 3)                  # rf length
data = w.build(buf, rf_len)
off, sizes = 0, []
while off < len(data):
    magic, size = struct.unpack_from("<HH", data, off)
    assert magic == 0x4353
    payload = data[off + 4: off + 4 + size]
    body, crc = payload[:-2], struct.unpack("<H", payload[-2:])[0]
    assert crc == w.crc16(body), "crc"
    sizes.append(len(body)); off += 4 + size
assert off == len(data) and sizes == [356, 1472, 3, 3], sizes

if len(sys.argv) > 1:   # the real stock file: every key must be known
    _, n, unk = w.parse(sys.argv[1])
    assert not unk, unk
    print("stock ini: all keys known, rf_config", n, "values")
print("ok")
