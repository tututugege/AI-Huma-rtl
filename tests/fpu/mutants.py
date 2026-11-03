#!/usr/bin/env python3
"""Mutation check for the fpu: each mutant is one textual change applied to a copy of rtl/; replaying the traces must FAIL.
usage: python3 tests/fpu/mutants.py [mutant-id ...]      real-program traces are tried first, then the random ones;
the report says which kind of trace caught the mutant ('real' = a program trace, 'rand-only' = only the generator)."""
import glob, os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
D = 'rtl/backend/fpu/'
M = [
 ('M01', D+'fpu_decode.sv', "latency_minus_1 = LAT_W'(LAT_FDIV - 1);", "latency_minus_1 = LAT_W'(LAT_FDIV - 2);", 'fdiv/fsqrt latency 9 instead of 10'),
 ('M02', D+'fpu_decode.sv', "if (is_mul | is_cvt_w | is_cvt_s)", "if (is_mul | is_cvt_w)", 'fcvt.s.w latency 5 instead of 3'),
 ('M03', D+'fpu_ctrl.sv', "((flush_mask == {BR_MASK_WIDTH{1'b1}}) | (|(br_mask_q & flush_mask)))", "(|(br_mask_q & flush_mask))", 'all-ones flush mask no longer kills by itself'),
 ('M04', D+'fpu_ctrl.sv', "((flush_mask == {BR_MASK_WIDTH{1'b1}}) | (|(br_mask_q & flush_mask)))", "(flush_mask == {BR_MASK_WIDTH{1'b1}})", 'only the global flush kills (no br_mask overlap kill)'),
 ('M05', D+'fpu_ctrl.sv', "assign accept        = en & ~alive;", "assign accept        = en & ~busy_q;", 'accept ignores this cycle\'s kill'),
 ('M06', D+'fpu_ctrl.sv', "assign held_br_mask  = br_mask_q & ~clear_mask;", "assign held_br_mask  = (br_mask_q & ~clear_mask) | (clear_mask & br_mask_q);", 'clear_mask not applied to the held uop'),
 ('M07', D+'fpu_ctrl.sv', "busy_d      = alive & ~(consume & complete);", "busy_d      = alive & ~consume;", 'consume frees the unit before completion'),
 ('M08', D+'fpu_ctrl.sv', "assign ready = ~busy_d;", "assign ready = ~busy_q;", 'ready ignores this cycle\'s consume/accept'),
 ('M09', D+'fpu_ctrl.sv', "br_mask_d   = in_br_mask;", "br_mask_d   = in_br_mask & ~clear_mask;", 'accepted uop gets clear_mask applied'),
 ('M10', D+'fpu_slot.sv', "rob_idx_d   = accept ? rob_idx_in : rob_idx_q;", "rob_idx_d   = accept ? (rob_idx_in & 7'd0) : rob_idx_q;", 'rob_idx never loaded'),
 ('M11', D+'fpu_addsub.sv', "assign b_eff = {b[31] ^ is_sub, b[30:0]};", "assign b_eff = {b[31] ^ (is_sub & 1'b0), b[30:0]};", 'fsub does not flip the sign of b'),
 ('M12', D+'fpu_pkg.sv', "fpu_rm_decode.rne = (rm == 3'd0) || (rm == 3'd7);", "fpu_rm_decode.rne = (rm == 3'd0);", 'rm=7 (DYN) not treated as RNE'),
 ('M13', D+'fpu_div.sv', "quotient[1] | quotient[0] | rem_nonzero}", "quotient[1] | quotient[0]}", 'fdiv sticky ignores the remainder'),
 ('M14', D+'fpu_sqrt.sv', "assign sig_adj    = e_odd ? {sig_a, 1'b0} : {1'b0, sig_a};", "assign sig_adj    = e_odd ? {1'b0, sig_a} : {sig_a, 1'b0};", 'fsqrt odd/even exponent handling swapped'),
 ('M15', D+'fpu_cvt_f2i.sv', "unsigned_result = sign_a ? 32'd0 : int_rounded[31:0];", "unsigned_result = int_rounded[31:0];", 'fcvt.wu.s of a negative value not clamped to 0'),
 ('M16', D+'fpu_cvt_i2f.sv', "{normalised[31:6], |normalised[5:0]}", "{normalised[31:6], |(normalised[5:0] & 6'd0)}", 'fcvt.s.w drops the sticky bit'),
 ('M17', D+'fpu_minmax.sv', "min_ordered = a_lt_b ? a : (b_lt_a ? b : (a | b));", "min_ordered = a_lt_b ? a : (b_lt_a ? b : (a & b));", 'fmin(-0,+0) returns +0'),
 ('M18', D+'fpu_cmp.sv', "lt_raw = signs_differ ? (sign_a & ~both_zero)", "lt_raw = signs_differ ? (sign_a)", 'flt(-0,+0) true'),
 ('M19', D+'fpu_fclass.sv', "{22'd0, is_nan & ~is_snan, is_snan,", "{22'd0, is_snan, is_nan & ~is_snan,", 'fclass sNaN/qNaN bits swapped'),
 ('M20', D+'fpu_round_pack.sv', "assign shift_amount       = 12'sd1 - exp_biased;", "assign shift_amount       = 12'sd2 - exp_biased;", 'subnormal result shifted one bit too far'),
 ('M21', D+'fpu_round_pack.sv', "rm.rne | rm.rmm | (rm.rdn & sign) | (rm.rup & ~sign)", "rm.rne | rm.rmm | (rm.rup & ~sign)", 'overflow of a negative result in RDN gives max finite instead of -inf'),
 ('M22', D+'fpu_div.sv', "result = F32_QNAN;", "result = 32'h7FC00001;", 'fdiv NaN result not canonical'),
 ('M23', D+'fpu_sgnj.sv', "assign sgnjx = {a[31] ^ b_sign, a[30:0]};", "assign sgnjx = {a[31] | b_sign, a[30:0]};", 'fsgnjx uses OR instead of XOR'),
 ('M24', D+'fpu_cvt_f2i.sv', "(int_rounded >= 33'h80000000));", "(int_rounded > 33'h80000000));", 'fcvt.w.s of +2^31 (rounded) not saturated'),
 ('M25', D+'fpu_cmp.sv', "assign eq = ~nan_either & (bits_equal | both_zero);", "assign eq = ~nan_either & bits_equal;", 'feq(-0,+0) false'),
 ('M26', D+'fpu_slot.sv', "dest_en_d   = accept ? dest_en_in : dest_en_q;", "dest_en_d   = accept ? dest_en_in : dest_en_q | dest_en_in;", 'dest_en picks up later offers while busy'),
 ('M27', D+'fpu_ctrl.sv', "remaining_d = latency_minus_1;", "remaining_d = latency_minus_1 + LAT_W'(1);", 'every operation one cycle slower'),
 ('M28', D+'fpu_div_array.sv', "assign fits  = (dividend_i >= {1'b0, sb});", "assign fits  = (dividend_i > {1'b0, sb});", 'fdiv: exact-quotient step not taken (> instead of >=)'),
 ('M29', D+'fpu_mul.sv', "(top ? 12'sd128 : 12'sd127)", "12'sd127", 'fmul exponent ignores the product carry'),
 ('M31', D+'fpu_addsub.sv', "assign a_larger = (a[30:0] >= b_eff[30:0]);", "assign a_larger = (a[30:0] > b_eff[30:0]);", 'fadd: equal magnitudes ordered the other way (sign of cancellation)'),
 ('M32', D+'fpu_addsub.sv', "{eff_sub ? rm.rdn : sign_l, 31'd0}", "{sign_l, 31'd0}", 'exact cancellation gives sign of larger operand, not +0/-0 by rounding mode'),
 ('M33', D+'fpu_addsub.sv', "(small27 >> shift_clamped) | {26'd0, lost_nonzero}", "(small27 >> shift_clamped) | {26'd0, lost_nonzero & 1'b0}", 'fadd alignment drops the sticky bit'),
 ('M34', D+'fpu_addsub.sv', "sum_left[1] | sum_left[0]}", "sum_left[1] | (sum_left[0] & 1'b0)}", 'fadd normalisation drops a sticky bit'),
 ('M35', D+'fpu_mul.sv', "{product[46:21], |product[20:0]}", "{product[46:21], 1'b0}", 'fmul drops the sticky bit (no-carry case)'),
 ('M30', D+'fpu_cvt_f2i.sv', "assign sticky_shifted = (shift_left < 12'sd0) & (|mant);", "assign sticky_shifted = 1'b0;", 'fcvt.w.s of tiny values ignores the sticky bits (RUP/RDN of |x|<0.25)'),
]

def run(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

def main():
    want = set(sys.argv[1:])
    os.chdir(ROOT)
    real = sorted(p for p in glob.glob('traces/fpu/*.trc') if not os.path.basename(p).startswith('rand'))
    rand = sorted(glob.glob('traces/fpu/rand*.trc'))
    caught = {'real': 0, 'rand-only': 0, 'SURVIVED': 0, 'ERR': 0}
    for mid, f, old, new, desc in M:
        if want and mid not in want:
            continue
        t = tempfile.mkdtemp(prefix='fpumut_', dir=os.path.join(ROOT, 'build'))
        shutil.copytree('rtl', t + '/rtl'); shutil.copytree('spec', t + '/spec')
        s = open(f'{t}/{f}').read()
        if old not in s:
            print(mid, 'PATTERN NOT FOUND'); shutil.rmtree(t); caught['ERR'] += 1; continue
        open(f'{t}/{f}', 'w').write(s.replace(old, new, 1))
        files = run(['bash', 'scripts/rtl_files.sh', t]).stdout.split()
        r = run(['bash', ROOT + '/scripts/hbuild.sh', 'spec/fpu.io', t + '/build'] + files, cwd=t)
        if 'built' not in r.stdout:
            print(mid, 'BUILD FAILED', desc, r.stdout[-300:]); shutil.rmtree(t); caught['ERR'] += 1; continue
        kind, where = 'SURVIVED', ''
        for label, group in (('real', real), ('rand-only', rand)):
            for tr in group:
                o = run([t + '/build/replay', tr, '--max-fail', '1']).stdout
                m = re.search(r'MISMATCH rec=(\d+) cycle=(\d+) (\w+): ref=(\S+) rtl=(\S+)', o)
                if m:
                    kind, where = label, f'{os.path.basename(tr)} rec {m[1]} field {m[3]}'
                    break
            if kind != 'SURVIVED':
                break
        caught[kind] += 1
        print(f'{mid} [{kind}] {desc} -- {where}', flush=True)
        shutil.rmtree(t)
    print('summary', caught)

main()
