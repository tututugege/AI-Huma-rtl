#!/usr/bin/env python3
"""check_lanes.py <trace.trc>...: verify pc[i] == pc[0] + 4*i (mod 2^32) wherever the entry is valid (ptab_lanes.io)."""
import os, struct, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'harness', 'tools'))
import iogen
mod, fields, ib, ob, h = iogen.parse(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ptab_lanes.io'))
F = {f.name: f for f in fields}
bad = n = 0
for path in sys.argv[1:]:
    d = open(path, 'rb').read()
    tib, tob, th, nl = struct.unpack_from('<IIQH', d, 8)
    assert th == h, 'spec hash'
    pos = 8 + 4 + 4 + 8 + 2 + nl; rec = 8 + 1 + ib + ob
    cnt = {'ptab_w': 0, 'ptab_r': 0, 'f2b_w': 0, 'f2b_r': 0, 'out': 0}
    for k in range((len(d) - pos) // rec):
        b = pos + k * rec
        if d[b + 8] & 1: continue
        base = b + 9
        def sc(name): return d[base + F[name].byte_off]
        def pcs(name):
            o = base + F[name].byte_off
            return [struct.unpack_from('<I', d, o + 4 * i)[0] for i in range(8)]
        for we, pc, key in (('ptab_we', 'ptab_wpc', 'ptab_w'), ('ptab_rv', 'ptab_rpc', 'ptab_r'),
                            ('f2b_we', 'f2b_wpc', 'f2b_w'), ('f2b_rv', 'f2b_rpc', 'f2b_r'), ('out_valid', 'out_pc', 'out')):
            if sc(we):
                p = pcs(pc); cnt[key] += 1; n += 1
                if any(p[i] != (p[0] + 4 * i) & 0xffffffff for i in range(8)):
                    bad += 1
                    if bad < 5: print('VIOLATION', path, k, key, [hex(x) for x in p])
    print(os.path.basename(path), cnt)
print('entries checked', n, 'violations', bad)
sys.exit(1 if bad else 0)
