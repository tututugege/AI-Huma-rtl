#!/usr/bin/env python3
"""Independent check of a recorded FIFO trace: drive a plain Python FIFO with the recorded INPUTS and compare
with the recorded OUTPUTS.  Validates the spec + recorder (expressions, packing, tap semantics) without any RTL.

  usage: check_fifo_trace.py <spec.io> <trace.trc> [--cap N] [--full-at M] [--max-fail K]

Naming convention of the spec (see ptab.io): inputs  reset refetch rd_en wr_en wr_<f>...
                                             outputs rd_valid rd_<f>... full empty
Per record:  clear = reset|refetch;  rd_valid = rd_en & !clear & !empty;  head = oldest entry;
             then  clear -> push (if wr_en) -> pop (if rd_valid).   full/empty are the flags at the START of the
             cycle (full = size >= --full-at, empty = size == 0).
"""
import argparse, collections, os, struct, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'harness', 'tools'))
import iogen

ap = argparse.ArgumentParser()
ap.add_argument('spec'); ap.add_argument('trace')
ap.add_argument('--cap', type=int, default=16)
ap.add_argument('--full-at', type=int, default=None, help='full flag threshold (default cap)')
ap.add_argument('--max-fail', type=int, default=5)
a = ap.parse_args()
full_at = a.full_at if a.full_at is not None else a.cap

mod, fields, ib, ob, h = iogen.parse(a.spec)
byname = {f.name: f for f in fields}
data = open(a.trace, 'rb').read()
assert data[:8] == b'TTGTRC01', 'bad magic'
tib, tob, thash, nlen = struct.unpack_from('<IIQH', data, 8)
assert (tib, tob) == (ib, ob), f'record size mismatch spec {ib}/{ob} vs trace {tib}/{tob}'
if thash != h:
    sys.exit(f'spec hash mismatch: spec {h:016x} trace {thash:016x}')
pos = 8 + 4 + 4 + 8 + 2 + nlen
rec = 8 + 1 + ib + ob

def raw(f, buf, base):
    s = base + f.byte_off
    return bytes(buf[s:s + f.nelem * f.ebytes])

def scalar(f, buf, base):
    return int.from_bytes(raw(f, buf, base)[:f.ebytes], 'little')

wr = [f for f in fields if f.name.startswith('wr_') and f.dir == 'in' and f.name != 'wr_en']
rd = {f.name[3:]: f for f in fields if f.name.startswith('rd_') and f.dir == 'out' and f.name != 'rd_valid'}
pairs = [(w, rd['' + w.name[3:]]) for w in wr if w.name[3:] in rd]
print(f'{mod}: {len(wr)} write fields, {len(pairs)} paired read fields, record {rec} B')
q = collections.deque()
n = fails = reads = writes = clears = maxq = fullc = 0
nrec = (len(data) - pos) // rec
for k in range(nrec):
    base = pos + k * rec
    flags = data[base + 8]
    ibase, obase = base + 9, base + 9 + ib
    if flags & 1:
        q.clear(); continue
    sc = lambda name, o=False: scalar(byname[name], data, obase if o else ibase)
    clear = bool(sc('reset') or sc('refetch'))
    exp_empty = len(q) == 0
    exp_full = len(q) >= full_at
    errs = []
    if 'full' in byname and sc('full', True) != exp_full: errs.append(f'full ref={sc("full", True)} model={int(exp_full)}')
    if 'empty' in byname and sc('empty', True) != exp_empty: errs.append(f'empty ref={sc("empty", True)} model={int(exp_empty)}')
    exp_rv = bool(sc('rd_en')) and not clear and not exp_empty
    if sc('rd_valid', True) != exp_rv: errs.append(f'rd_valid ref={sc("rd_valid", True)} model={int(exp_rv)}')
    elif exp_rv:
        head = q[0]
        for i, (w, r) in enumerate(pairs):
            if raw(r, data, obase) != head[i]:
                errs.append(f'{r.name} differs from the entry pushed {len(q)} entries ago'); break
    if errs:
        fails += 1
        if fails <= a.max_fail: print(f'MISMATCH rec={k} cycle={struct.unpack_from("<Q", data, base)[0]}: ' + '; '.join(errs))
    if clear:
        if q: clears += 1
        q.clear()
    if sc('wr_en'):
        q.append([raw(w, data, ibase) for w, _ in pairs]); writes += 1
    if exp_rv:
        q.popleft(); reads += 1
    maxq = max(maxq, len(q)); fullc += len(q) >= full_at
    n += 1
if len(q) > a.cap: print(f'MODEL OVERFLOW size {len(q)} > cap {a.cap}'); fails += 1
print(f'{"PASS" if not fails else "FAIL"}: {n} records, {writes} pushes, {reads} pops, {clears} non-empty flushes, '
      f'max size {maxq}, cycles at full-flag {fullc}, mismatching records {fails}')
sys.exit(1 if fails else 0)
