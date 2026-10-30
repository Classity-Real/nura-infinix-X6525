#!/usr/bin/env python3
"""List the VSP register offsets that a stock libomx_*_sprd.so builds as 0x6120xxxx
constants (mov + movk), per function. Usage:
  llvm-objdump -d --no-show-raw-insn libomx_avcdec_hw_sprd.so > avc.dis
  python3 -I tools/vsp-reg-scan.py avc.dis
Offsets are relative to 0x61200000, the vendor's VSP register base; add them to the
mapped 0x32000000 window. Only registers addressed through such constants show up: the
rest go through base+immediate and need real disassembly reading."""
import re, sys, collections
cur, val, regs = '?', {}, {}
for l in open(sys.argv[1]):
    m = re.match(r'^[0-9a-f]+ <(.+)>:', l)
    if m:
        cur, val = m.group(1), {}
        continue
    m = re.search(r'\bmov\s+(w\d+), #(0x[0-9a-f]+)', l)
    if m:
        val[m.group(1)] = int(m.group(2), 16)
        continue
    m = re.search(r'\bmovk\s+(w\d+), #(0x[0-9a-f]+), lsl #16', l)
    if m and m.group(1) in val:
        v = val[m.group(1)] | (int(m.group(2), 16) << 16)
        if 0x61200000 <= v < 0x61210000:
            regs.setdefault(v - 0x61200000, collections.Counter())[cur] += 1
for o in sorted(regs):
    print('%04x  %s' % (o, ', '.join('%s x%d' % kv for kv in regs[o].items())))
