#!/usr/bin/env python3
"""cov.py <module> [--real|--rand]: coverage of the traces in traces/<module>/ (programs vs generated rand_*/exh_*).

For every 1-bit field: number of records with the field = 1 (and whether 0 and 1 were both seen).
FIFO specs (refetch/rd_en/wr_en/rd_valid/full/empty): a size model gives max size, #clear on a non-empty queue,
#clear+push, #push at size-1 (reaches depth), #full cycles, pointer wraps (pushes // depth).
"""
import glob, os, struct, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'harness', 'tools'))
import iogen
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
mod = sys.argv[1]
sel = sys.argv[2] if len(sys.argv) > 2 else '--all'
m, fields, ib, ob, h = iogen.parse(os.path.join(ROOT, 'spec', mod + '.io'))
F = {f.name: f for f in fields}
files = sorted(glob.glob(os.path.join(ROOT, 'traces', mod, '*.trc')))
is_rand = lambda p: os.path.basename(p).startswith(('rand_', 'exh_'))
if sel == '--real': files = [p for p in files if not is_rand(p)]
if sel == '--rand': files = [p for p in files if is_rand(p)]
depth = {'fetch_addr_fifo': 16, 'inst_fifo': 16, 'ptab': 16, 'front2back_fifo': 32}.get(mod)
ones, zeros = {}, {}
st = dict(records=0, programs=0, clears_nonempty=0, clear_push=0, pushes=0, pops=0, full_cycles=0, max_size=0, rd_empty=0)
for path in files:
    d = open(path, 'rb').read()
    tib, tob, th, nl = struct.unpack_from('<IIQH', d, 8)
    assert th == h, path
    pos = 8 + 4 + 4 + 8 + 2 + nl; rec = 8 + 1 + ib + ob
    st['programs'] += 1
    size = 0
    for k in range((len(d) - pos) // rec):
        b = pos + k * rec
        if d[b + 8] & 1: size = 0; continue
        st['records'] += 1
        base = b + 9
        for f in fields:
            if f.width != 1: continue
            o = base + (0 if f.dir == 'in' else ib) + f.byte_off
            for e in range(f.nelem):
                v = d[o + e]
                (ones if v else zeros)[(f.name, e)] = (ones if v else zeros).get((f.name, e), 0) + 1
        if depth:
            g = lambda n, out=False: d[base + (ib if out else 0) + F[n].byte_off]
            clear, wr, rv = g('refetch'), g('wr_en'), g('rd_valid', True)
            if g('full', True): st['full_cycles'] += 1
            if g('rd_en') and not clear and size == 0: st['rd_empty'] += 1
            if clear and size: st['clears_nonempty'] += 1
            if clear and wr: st['clear_push'] += 1
            if clear: size = 0
            if wr: size += 1; st['pushes'] += 1
            if rv: size -= 1; st['pops'] += 1
            st['max_size'] = max(st['max_size'], size)
print(f'{mod} [{sel}]', st)
names = sorted({n for n, _ in list(ones) + list(zeros)})
not_both = [n for n in names if not any(((n, e) in ones and (n, e) in zeros) for e in range(F[n].nelem))]
print('1-bit fields seen as both 0 and 1 in at least one element:', len(names) - len(not_both), 'of', len(names))
if not_both: print('  NOT toggled:', not_both)
if mod in ('front_ctrl',):
    print('  #cycles with 1:', {n: ones.get((n, 0), 0) for n in names})
