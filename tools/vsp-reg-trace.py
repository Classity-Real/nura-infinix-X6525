#!/usr/bin/env python3
"""Trace VSP register reads and writes in a stock libomx_*_sprd.so disassembly.

  llvm-objdump -d --no-show-raw-insn libomx_avcdec_hw_sprd.so > avc.dis
  python3 -I tools/vsp-reg-trace.py avc.dis [function-substring]

The libraries keep the mapped register window as a pointer at the start of their context
structure and reach registers either through 0x6120xxxx constants (the vendor's physical
base, subtract 0x61200000) or as `ldr x, [ctx]; add x, x, #const; str w, [x, #imm]`.
tools/vsp-reg-scan.py only sees the first form. This follows both within straight-line code:

  * a register that was loaded from [x] with offset 0 is "BASE" (the window pointer)
  * BASE + constant (immediate or a register holding a constant) is a "REG" at that offset
  * ldr/str relative to a REG adds the immediate

Constants below 0x10000 or in 0x6120xxxx are taken as register offsets. The trace is a
heuristic (it resets at branches targets only loosely), so every row is a lead to confirm by
reading the disassembly, not a fact. Output: function, address, R/W, offset, constant value
being stored (when known).
"""
import re
import sys
from collections import defaultdict

want = sys.argv[2] if len(sys.argv) > 2 else None
cur = None
state = {}
rows = defaultdict(list)


def num(s):
    return int(s, 0)


def norm(r):
    return 'x' + r[1:] if r[0] in 'wx' else r


def const_off(v):
    if 0x61200000 <= v < 0x61210000:
        return v - 0x61200000
    if 0 <= v < 0x10000:
        return v
    return None


for line in open(sys.argv[1]):
    m = re.match(r'^[0-9a-f]+ <(.+)>:', line)
    if m:
        cur = m.group(1)
        state = {}
        continue
    m = re.match(r'\s*([0-9a-f]+):\s+(\w+)\s*(.*)', line)
    if not m or cur is None:
        continue
    addr, op, args = m.groups()
    args = args.split('//')[0].strip()
    a = [x.strip() for x in re.split(r',\s*(?![^\[]*\])', args)] if args else []

    if op == 'mov' and len(a) == 2 and a[1].startswith('#'):
        state[norm(a[0])] = ('const', num(a[1][1:]))
    elif op == 'movk' and len(a) >= 2 and a[1].startswith('#'):
        r = norm(a[0])
        sh = 0
        if len(a) == 3:
            sh = int(a[2].split('#')[1])
        old = state.get(r, ('const', 0))
        if old[0] == 'const':
            v = (old[1] & ~(0xffff << sh)) | (num(a[1][1:]) << sh)
            state[r] = ('const', v)
    elif op == 'ldr' and len(a) == 2:
        mm = re.match(r'\[(x\d+)\]$', a[1])
        if mm and a[0].startswith('x'):
            state[norm(a[0])] = ('base',)
        else:
            mm = re.match(r'\[(x\d+), #(-?0x[0-9a-f]+|-?\d+)\]$', a[1])
            st = state.get(norm(mm.group(1))) if mm else None
            if st and st[0] == 'reg':
                rows[cur].append((addr, 'R', st[1] + num(mm.group(2)), None, len(st) > 2 and st[2]))
            state.pop(norm(a[0]), None)
    elif op == 'add' and len(a) == 3:
        d = norm(a[0])
        s1 = state.get(norm(a[1]))
        if a[2].startswith('#'):
            s2 = ('const', num(a[2][1:]))
        else:
            s2 = state.get(norm(a[2]))
        res = None
        # BASE + const (either operand order), REG + const, const + const
        for x, y in ((s1, s2), (s2, s1)):
            if x and y and x[0] in ('base', 'reg') and y[0] == 'const':
                off = (x[1] if x[0] == 'reg' else 0) + (const_off(y[1]) if const_off(y[1]) is not None else y[1])
                res = ('reg', off, x[2] if len(x) > 2 else False)
                break
        # const + unknown index: keep the constant, mark the result as indexed
        if res is None:
            for x, y in ((s1, s2), (s2, s1)):
                if x and x[0] == 'const' and const_off(x[1]) is not None and y is None:
                    res = ('cidx', const_off(x[1]))
                    break
        # BASE/REG + cidx
        if res is None:
            for x, y in ((s1, s2), (s2, s1)):
                if x and y and x[0] in ('base', 'reg') and y[0] == 'cidx':
                    res = ('reg', (x[1] if x[0] == 'reg' else 0) + y[1], True)
                    break
        if res is None and s1 and s1[0] == 'cidx' and s2 is None:
            res = s1
        if res:
            state[d] = res
        else:
            state.pop(d, None)
    elif op in ('str', 'strb', 'strh') and len(a) == 2:
        mm = re.match(r'\[(x\d+)(?:, #(-?0x[0-9a-f]+|-?\d+))?\]$', a[1])
        mr = re.match(r'\[(x\d+), (x\d+)\]$', a[1])
        val = state.get(norm(a[0]))
        v = val[1] if val and val[0] == 'const' else None
        if mm:
            st = state.get(norm(mm.group(1)))
            if st and st[0] == 'reg':
                rows[cur].append((addr, 'W', st[1] + (num(mm.group(2)) if mm.group(2) else 0), v, len(st) > 2 and st[2]))
        elif mr:
            b, c = state.get(norm(mr.group(1))), state.get(norm(mr.group(2)))
            if b and c and b[0] == 'base' and c[0] == 'const' and const_off(c[1]) is not None:
                rows[cur].append((addr, 'W', const_off(c[1]), v, False))
    else:
        if a and op not in ('cmp', 'tst', 'b', 'cbz', 'cbnz', 'bl', 'ret', 'nop'):
            state.pop(norm(a[0]), None)
        if op == 'bl':
            for r in list(state):
                if r in ('x0', 'x1', 'x2', 'x3', 'x4', 'x5', 'x6', 'x7', 'x8', 'x9',
                         'x10', 'x11', 'x12', 'x13', 'x14', 'x15', 'x16', 'x17'):
                    state.pop(r)

for fn, lst in rows.items():
    if want and want not in fn:
        continue
    print('== %s' % fn)
    for addr, rw, off, v, idx in lst:
        print('  %s %s 0x%04x%s%s' % (addr, rw, off, '+i' if idx else '', '' if v is None else ' <- 0x%x' % v))
