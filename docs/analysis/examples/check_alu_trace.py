#!/usr/bin/env python3
"""Sanity check of a recorded alu_bank trace against an independent Python ALU (base RV32I ops + the Zba shifts-add
that dhrystone uses; other ops are counted as 'skipped').  Demonstrates that the FuInput/FuOutput recording is
meaningful.  usage: check_alu_trace.py spec/alu_bank.io traces/alu_bank/<prog>.trc"""
import os, struct, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'harness', 'tools'))
import iogen
UOP_ADD = 1
mod, fields, ib, ob, h = iogen.parse(sys.argv[1]); F = {f.name: f for f in fields}
d = open(sys.argv[2], 'rb').read(); nlen = struct.unpack_from('<H', d, 24)[0]; pos = 26 + nlen; rec = 9 + ib + ob
def el(f, base, k): s = base + f.byte_off + k * f.ebytes; return int.from_bytes(d[s:s + f.ebytes], 'little')
M = 0xffffffff; sg = lambda x: x - (1 << 32) if x >> 31 else x
ok = bad = skipped = 0
for r in range((len(d) - pos) // rec):
    b = pos + r * rec
    if d[b + 8] & 1: continue
    ib_, ob_ = b + 9, b + 9 + ib
    for k in range(6):
        if not el(F['en'], ib_, k): continue
        g = lambda n: el(F[n], ib_, k)
        if g('op') != UOP_ADD: skipped += 1; continue
        a = g('pc') if g('src1_is_pc') else g('src1_rdata'); imm = g('src2_is_imm')
        bb = g('imm') if imm else g('src2_rdata'); f3, f7 = g('func3'), g('func7'); exp = None
        if f3 == 0: exp = (a - bb) & M if ((f7 >> 5) & 1) and not imm else (a + bb) & M
        elif f3 == 1 and f7 == 0: exp = (a << (bb & 31)) & M
        elif f3 == 2 and f7 == 0: exp = int(sg(a) < sg(bb))
        elif f3 == 3 and f7 == 0: exp = int(a < bb)
        elif f3 == 4 and f7 == 0: exp = a ^ bb
        elif f3 == 5 and f7 == 0: exp = a >> (bb & 31)
        elif f3 == 5 and f7 == 0x20: exp = (sg(a) >> (bb & 31)) & M
        elif f3 == 6 and f7 == 0: exp = a | bb
        elif f3 == 7 and f7 == 0: exp = a & bb
        elif f3 == 2 and f7 == 0x10 and not imm: exp = (bb + (a << 1)) & M
        elif f3 == 4 and f7 == 0x10 and not imm: exp = (bb + (a << 2)) & M
        elif f3 == 6 and f7 == 0x10 and not imm: exp = (bb + (a << 3)) & M
        if exp is None: skipped += 1; continue
        if not el(F['complete'], ob_, k) or el(F['result'], ob_, k) != exp:
            bad += 1
            if bad < 5: print('MISMATCH rec', r, 'alu', k, hex(exp), hex(el(F['result'], ob_, k)))
        else: ok += 1
print(f'{"PASS" if not bad else "FAIL"}: checked {ok + bad} ALU ops, mismatches {bad}, skipped {skipped} (other ops/ecall-like)')
sys.exit(1 if bad else 0)
