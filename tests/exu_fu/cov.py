#!/usr/bin/env python3
"""Arm coverage of recorded exu_fu traces: counts how often every C++ decision arm of the unit was exercised by a uop
(en = 1).  usage: cov.py <alu|bru|sdu|mul|div> <spec.io> <trace.trc>...   (arms are a direct port of the C++ chains)"""
import collections, os, struct, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'harness', 'tools'))
import iogen

def alu_arm(g):
    op, f3, f7, imm, lo = g('op'), g('func3'), g('func7'), g('src2_is_imm'), g('imm') & 31
    if op == 16: return 'wfi'
    if op != 1: return 'other-op(add)'
    if f3 == 0: return 'sub' if (f7 >> 5) & 1 and not imm else 'add'
    if f3 == 1:
        if f7 == 0: return 'sll'
        if f7 == 0x30 and not imm: return 'rol' + ('0' if g('src2_rdata') & 31 == 0 else '')
        if f7 == 0x24: return 'bclr'
        if f7 == 0x14: return 'bset'
        if f7 == 0x34: return 'binv'
        if f7 == 5: return 'clmul'
        if f7 == 0x30 and imm: return {0: 'clz', 1: 'ctz', 2: 'cpop', 4: 'sext.b', 5: 'sext.h'}.get(lo, 'unary-none')
        return 'sll-none'
    if f3 == 2:
        if f7 == 0: return 'slt'
        if f7 == 0x10 and not imm: return 'sh1add'
        if f7 == 5 and not imm: return 'clmulr'
        return 'slt-fallthrough'
    if f3 == 3:
        if f7 == 0: return 'sltu'
        if f7 == 5 and not imm: return 'clmulh'
        return 'sltu-fallthrough'
    if f3 == 4:
        if f7 == 0: return 'xor'
        if f7 == 0x20 and not imm: return 'xnor'
        if f7 == 0x10 and not imm: return 'sh2add'
        if f7 == 5 and not imm: return 'min'
        if f7 == 4 and not imm: return 'pack'
        return 'xor-fallthrough'
    if f3 == 5:
        if f7 == 0: return 'srl'
        if f7 == 0x20 and not imm: return 'sra'
        if (f7 >> 5) & 1 and imm and f7 not in (0x30, 0x24, 0x34, 0x14): return 'srai'
        if f7 == 0x30: return 'ror' + ('0' if g('imm' if imm else 'src2_rdata') & 31 == 0 else '')
        if f7 == 0x24: return 'bext'
        if f7 == 0x34 and imm: return 'rev8' if lo == 24 else 'rev8-badshamt'
        if f7 == 0x14 and imm: return 'orc.b' if lo == 7 else 'orcb-badshamt'
        if f7 == 5 and not imm: return 'minu'
        return 'srl-fallthrough'
    if f3 == 6:
        if f7 == 0: return 'or'
        if f7 == 0x20 and not imm: return 'orn'
        if f7 == 5 and not imm: return 'max'
        if f7 == 0x10 and not imm: return 'sh3add'
        return 'or-fallthrough'
    if f7 == 0: return 'and'
    if f7 == 0x20 and not imm: return 'andn'
    if f7 == 5 and not imm: return 'maxu'
    if f7 == 4 and not imm: return 'packh'
    return 'and-fallthrough'

def bru_arm(g):
    op, f3 = g('op'), g('func3')
    if op == 0: return 'jalr' if g('src1_en') else 'jal'
    name = {0: 'beq', 1: 'bne', 4: 'blt', 5: 'bge', 6: 'bltu', 7: 'bgeu'}.get(f3, 'br-f3=%d' % f3)
    return name + ('/mispred' if g('mispred') else '/ok')

def sdu_arm(g):
    if not g('is_atomic'): return 'store'
    return {0: 'amoadd', 1: 'amoswap', 4: 'amoxor', 8: 'amoor', 12: 'amoand', 16: 'amomin', 20: 'amomax', 24: 'amominu',
            28: 'amomaxu'}.get(g('amo_op'), 'amo-other')

def mul_arm(g): return 'func3=%d' % g('func3')
def div_arm(g): return ['div', 'divu', 'rem', 'remu'][g('func3')] + ('/by0' if g('src2_rdata') == 0 else '') + (
    '/min,-1' if g('src1_rdata') == 0x80000000 and g('src2_rdata') == 0xffffffff else '')

ARM = {'alu': alu_arm, 'bru': bru_arm, 'sdu': sdu_arm, 'mul': mul_arm, 'div': div_arm}
kind, spec, *traces = sys.argv[1:]
mod, fields, ib, ob, h = iogen.parse(spec); F = {f.name: f for f in fields}
H = collections.Counter()
for t in traces:
    d = open(t, 'rb').read(); nlen = struct.unpack_from('<H', d, 24)[0]; pos = 26 + nlen; rec = 9 + ib + ob
    for r in range((len(d) - pos) // rec):
        b = pos + r * rec
        if d[b + 8] & 1: continue
        for k in range(F['en'].dims[0]):
            def el(f, base): s = base + f.byte_off + k * f.ebytes; return int.from_bytes(d[s:s + f.ebytes], 'little')
            if not el(F['en'], b + 9): continue
            def g(n): f = F[n]; return el(f, b + 9 if f.dir == 'in' else b + 9 + ib)
            H[ARM[kind](g)] += 1
for k, v in sorted(H.items()): print('%-18s %d' % (k, v))
