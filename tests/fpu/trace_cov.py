#!/usr/bin/env python3
"""Coverage statistics of fpu traces (traces/fpu/*.trc or the given files): which instruction kinds were accepted, how many
completions, kills, delayed consumes ... Uses spec/fpu.io for the record layout; the accept/kill bookkeeping is a
re-implementation of the FU control used only for these counts (the pass/fail check is the RTL replay)."""
import struct, sys, glob, re, collections

def layout(spec):
    ins, outs = [], []
    for line in open(spec):
        m = re.match(r'^(in|out)\s+(\w+)\s+(\d+)(?:\s+when\s+\w+)?\s+@', line)
        if m:
            w = int(m[3]); eb = (w + 7) // 8
            (ins if m[1] == 'in' else outs).append((m[2], w, eb))
    return ins, outs

def offsets(fields):
    o, d = 0, {}
    for n, w, eb in fields:
        d[n] = (o, eb); o += eb
    return d, o

def main():
    files = sys.argv[1:] or sorted(glob.glob('traces/fpu/*.trc'))
    ins, outs = layout('spec/fpu.io')
    io, isz = offsets(ins); oo, osz = offsets(outs)
    cnt = collections.Counter(); kinds = collections.Counter(); rms = collections.Counter()
    for fn in files:
        data = open(fn, 'rb').read()
        nl = struct.unpack_from('<H', data, 8 + 4 + 4 + 8)[0]
        pos = 8 + 4 + 4 + 8 + 2 + nl
        rs = 9 + isz + osz
        busy = False; rem = 0; mask = 0; n = (len(data) - pos) // rs
        for k in range(n):
            base = pos + k * rs
            flags = data[base + 8]
            if flags & 1:
                busy = False; continue
            def gi(nm):
                o, eb = io[nm]; return int.from_bytes(data[base + 9 + o: base + 9 + o + eb], 'little')
            def go(nm):
                o, eb = oo[nm]; return int.from_bytes(data[base + 9 + isz + o: base + 9 + isz + o + eb], 'little')
            cnt['records'] += 1
            en, cons, fl = gi('in_en'), gi('in_consume'), gi('in_flush')
            fm, cm = gi('in_flush_mask'), gi('in_clear_mask')
            killed = busy and fl and (fm == (1 << 64) - 1 or (mask & fm) != 0)
            alive = busy and not killed
            if en: cnt['en'] += 1
            if en and alive: cnt['en_while_busy'] += 1
            if killed: cnt['killed'] += 1
            if busy and fl and not killed: cnt['flush_busy_survived'] += 1
            if alive and cm and (mask & cm): cnt['clear_hit_busy'] += 1
            complete = alive and rem == 0
            assert complete == bool(go('out_complete')), (fn, k)
            if complete:
                cnt['complete'] += 1
                if not cons: cnt['complete_not_consumed'] += 1
            if go('out_complete') and (go('out_inst_br_mask') != 0): cnt['complete_with_br_mask'] += 1
            if en and not alive:
                cnt['accept'] += 1
                f7, f3, imm = gi('in_inst_func7'), gi('in_inst_func3'), gi('in_inst_imm_rs2_bit0')
                key = (f7, f3 if f7 in (0x10, 0x14, 0x50, 0x70) else -1, imm if f7 in (0x60, 0x68) else -1)
                kinds[key] += 1
                if f7 < 0x10 or f7 in (0x60, 0x68, 0x2c): rms[f3] += 1
                a = gi('in_inst_src1_rdata'); b = gi('in_inst_src2_rdata')
                for nm, v in (('a', a), ('b', b)):
                    e, fr = (v >> 23) & 0xff, v & 0x7fffff
                    cls = 'zero' if e == 0 and fr == 0 else 'sub' if e == 0 else 'inf' if e == 255 and fr == 0 else \
                          ('snan' if not fr >> 22 else 'qnan') if e == 255 else 'norm'
                    cnt['op_' + cls] += 1
                lat = 5; 
                if f7 >> 2 == 2 or f7 in (0x60, 0x68): lat = 3
                if f7 >> 2 == 3 or f7 == 0x2c: lat = 10
                rem = lat - 1; mask = gi('in_inst_br_mask')
            elif alive:
                mask &= ~cm
                if rem: rem -= 1
            busy = (en and not alive) or (alive and not (cons and complete))
            if not (en and not alive) and busy: pass
    print('records', cnt['records'], 'files', len(files))
    for k, v in sorted(cnt.items()): print(f'  {k:24s} {v}')
    names = {0x00: 'fadd', 0x04: 'fsub', 0x08: 'fmul', 0x0c: 'fdiv', 0x2c: 'fsqrt', 0x60: 'fcvt.w[u].s', 0x68: 'fcvt.s.w[u]',
             0x10: 'fsgnj*', 0x14: 'fmin/max', 0x50: 'fcmp', 0x70: 'fclass'}
    print('accepted instructions (func7,func3,imm0):')
    for (f7, f3, im), v in sorted(kinds.items()): print(f'  {names.get(f7, hex(f7)):12s} f3={f3:2d} rs2b0={im:2d} {v}')
    print('rounding modes (func3) of rm-using instructions:', dict(sorted(rms.items())))

main()
