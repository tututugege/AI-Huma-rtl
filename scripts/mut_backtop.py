#!/usr/bin/env python3
"""Mutation check of the INTEGRATION layer (rtl/backend/back_top): wiring, glue and exu assembly.

Each mutant is one textual change (a connection to a wrong net of the same type, a glue/exu expression, a tie-off constant).
For every mutant: copy the tree, apply it, build the back_top lock-step plugin (warnings non-fatal), screen it on a few short
programs and, if it survives, on the full program set.  A mutant is KILLED when the whole-program lock-step reports a mismatch.

usage: mut_backtop.py [--dry] [--jobs N] [--only name,name] [--swaps K] [--seed S]
Needs REFSIM (default: refsim_tap).  Results: build/mut_backtop/results.txt
"""
import argparse
import concurrent.futures as cf
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BT = 'rtl/backend/back_top/'
G = '/Users/ruyaoh/personal/tututugege-trace/build'
SCREEN = [G + '/tests/smc-div/smc-div.bin', G + '/vm/vm-sum-fetch-test/vm_sum_fetch_test.bin',
          G + '/vm/vm-pagefault-test/vm_pagefault_test.bin', G + '/tests/add-longlong/add-longlong.bin',
          G + '/tests/atomic-boundary/atomic-boundary.bin', G + '/tests/interrupt-vectored/interrupt-vectored.bin',
          '/tmp/big/dhrystone.bin']
SCREEN_CAP = {'/tmp/big/dhrystone.bin': 300000}

# (name, file, old, new)  -- every `old` must occur in the file
TARGETED = [
    ('glue_epc_trap', BT + 'back_top_glue.sv',
     'if (rob_bcast_mret || rob_bcast_sret) flush_redirect_pc = csr2front_epc;',
     'if (rob_bcast_mret || rob_bcast_sret) flush_redirect_pc = csr2front_trap_pc;'),
    ('glue_pc_plus4', BT + 'back_top_glue.sv', 'flush_redirect_pc = rob_bcast_pc + 32\'d4;', 'flush_redirect_pc = rob_bcast_pc;'),
    ('glue_mispred_only_flush', BT + 'back_top_glue.sv', 'assign out_mispred     = rob_bcast_flush | dec_bcast_mispred;',
     'assign out_mispred     = rob_bcast_flush;'),
    ('glue_stall_polarity', BT + 'back_top_glue.sv', 'assign out_stall       = ~pre2front_ready;', 'assign out_stall       = pre2front_ready;'),
    ('glue_redirect_sel', BT + 'back_top_glue.sv', 'rob_bcast_flush ? flush_redirect_pc : br_latch_redirect_pc;',
     'rob_bcast_flush ? br_latch_redirect_pc : flush_redirect_pc;'),
    ('glue_diag_override_off', BT + 'back_top_glue.sv', 'rob_bcast_flush ? out_redirect_pc : rob_commit_commit_entry_uop_diag_val[i];',
     'rob_commit_commit_entry_uop_diag_val[i];'),
    ('glue_amo_op_slice', BT + 'back_top_glue.sv', 'assign rob_commit_commit_entry_uop_amo_op[i] = rob_commit_commit_entry_uop_func7[i][6:2];',
     'assign rob_commit_commit_entry_uop_amo_op[i] = rob_commit_commit_entry_uop_func7[i][5:1];'),
    ('glue_mxr_sum_swap', BT + 'back_top_glue.sv', 'assign csr_status_mstatus_mxr  = csr_status_mstatus[19];',
     'assign csr_status_mstatus_mxr  = csr_status_mstatus[18];'),
    ('glue_mpp_bits', BT + 'back_top_glue.sv', 'assign csr_status_mstatus_mpp  = csr_status_mstatus[12:11];',
     'assign csr_status_mstatus_mpp  = csr_status_mstatus[13:12];'),
    ('exu_mul_map', BT + 'exu.sv', "localparam int MC_MUL [MUL_NUM] = '{0, 3};", "localparam int MC_MUL [MUL_NUM] = '{3, 0};"),
    ('exu_div_map', BT + 'exu.sv', "localparam int MC_DIV [DIV_NUM] = '{1, 4};", "localparam int MC_DIV [DIV_NUM] = '{4, 1};"),
    ('exu_fpu_map', BT + 'exu.sv', 'localparam int MC_FPU = 2;', 'localparam int MC_FPU = 1;'),
    ('exu_mul_func3', BT + 'exu.sv', 'assign mul_func3[i] = exu2fu_mc_func3[MC_MUL[i]][1:0];',
     'assign mul_func3[i] = exu2fu_mc_func3[MC_MUL[i]][2:1];'),
    ('exu_flush_mask_mul', BT + 'exu.sv', 'assign mul_flush_mask[i] = exu2fu_flush_mask;', "assign mul_flush_mask[i] = '0;"),
    ('const_src1_busy', BT + 'back_top.sv', "assign ren2dis_uop_src1_busy = '{default: '0};", "assign ren2dis_uop_src1_busy = '{default: '1};"),
    ('const_br_taken', BT + 'back_top.sv', "assign dis2rob_uop_br_taken = '{default: '0};", "assign dis2rob_uop_br_taken = '{default: '1};"),
    ('const_pf_inst', BT + 'back_top.sv', "assign exu2rob_entry_uop_page_fault_inst = '{default: '0};",
     "assign exu2rob_entry_uop_page_fault_inst = '{default: '1};"),
    ('const_dis2rob_mispred', BT + 'back_top.sv', "assign dis2rob_uop_mispred = '{default: '0};", "assign dis2rob_uop_mispred = '{default: '1};"),
]


def parse_nets(text):
    """net name -> declaration type string (everything before the name), from the header declarations of back_top.sv"""
    nets = {}
    for m in re.finditer(r'^  logic\s*((?:\[[^\]]+\])?)\s*(\w+)\s*((?:\[[^\]]+\])*)\s*;', text, re.M):
        nets[m.group(2)] = (m.group(1) + ' ' + m.group(3)).strip()
    return nets


def swap_mutants(k, seed):
    text = open(os.path.join(ROOT, BT + 'back_top.sv')).read()
    nets = parse_nets(text)
    by_type = {}
    for n, t in nets.items():
        by_type.setdefault(t, []).append(n)
    conns = [(m.group(1), m.group(2)) for m in re.finditer(r'^\s+\.(\w+)\((\w+)\)', text, re.M) if m.group(2) in nets]
    # keep only connections whose net has a same-typed alternative that is not trivially a clone of itself
    cand = [(p, n) for p, n in conns if len(by_type[nets[n]]) > 1 and not n.startswith(('clk', 'rst'))]
    rnd = random.Random(seed)
    rnd.shuffle(cand)
    out = []
    used = set()
    for p, n in cand:
        if len(out) >= k:
            break
        alts = [a for a in by_type[nets[n]] if a != n]
        a = rnd.choice(alts)
        old = f'.{p}({n}),'
        if text.count(old) != 1 or old in used:
            continue
        used.add(old)
        out.append((f'swap_{len(out):02d}_{p}', BT + 'back_top.sv', old, f'.{p}({a}),'))
    return out


def run(cmd, **kw):
    return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, **kw)


def lockstep_one(T, dylib, prog, cap, env):
    e = dict(env, TTG_REC=dylib, TTG_MULTI='1', TTG_REC_N=str(cap))
    r = subprocess.run(['build/simulator', prog], cwd=env['REFSIM'], env=e, capture_output=True, text=True, errors='replace')
    lines = [l for l in r.stdout.splitlines() if l.startswith('LOCKSTEP') or 'MISMATCH' in l]
    fail = [l for l in lines if 'LOCKSTEP FAIL' in l]
    mm = [l.strip() for l in lines if 'MISMATCH' in l][:1]
    return (fail[0] if fail else None), (mm[0] if mm else '')


def do_mutant(m, env, workdir, full):
    name, f, old, new = m
    T = tempfile.mkdtemp(prefix='mut_', dir=workdir)
    try:
        for d in ('rtl', 'spec', 'harness', 'scripts'):
            shutil.copytree(os.path.join(ROOT, d), os.path.join(T, d))
        p = os.path.join(T, f)
        s = open(p).read()
        if old not in s:
            return name, 'PATTERN-MISSING', ''
        open(p, 'w').write(s.replace(old, new, 1))
        e = dict(env, BUILD_ONLY='1', VFLAGS='-Wno-fatal')
        r = run(f'bash {T}/scripts/lockstep.sh back_top x', env=e)
        dylib = os.path.join(T, 'build/lock_back_top/lock_back_top.dylib')
        if not os.path.exists(dylib):
            return name, 'BUILD-FAILED', (r.stdout + r.stderr)[-300:]
        keep = os.path.join(workdir, f'{name}.dylib')
        shutil.copy(dylib, keep)
        for prog in SCREEN:
            if not os.path.exists(prog):
                continue
            fail, mm = lockstep_one(T, keep, prog, SCREEN_CAP.get(prog, 4000000), env)
            if fail:
                return name, 'KILLED', f'{os.path.basename(prog)}: {fail.split("LOCKSTEP FAIL back_top: ")[-1]} | {mm}'
        if not full:
            return name, 'SURVIVED-SCREEN', ''
        progs = [l.strip() for l in open(os.path.join(ROOT, 'build/lockstep_multi.progs'))] if os.path.exists(
            os.path.join(ROOT, 'build/lockstep_multi.progs')) else []
        for prog in progs:
            if prog in SCREEN or not os.path.exists(prog):
                continue
            fail, mm = lockstep_one(T, keep, prog, 4000000, env)
            if fail:
                return name, 'KILLED(full)', f'{os.path.basename(prog)}: {fail.split("LOCKSTEP FAIL back_top: ")[-1]} | {mm}'
        return name, 'SURVIVED', ''
    finally:
        shutil.rmtree(T, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry', action='store_true')
    ap.add_argument('--jobs', type=int, default=3)
    ap.add_argument('--only', default='')
    ap.add_argument('--swaps', type=int, default=14)
    ap.add_argument('--seed', type=int, default=7)
    ap.add_argument('--no-full', action='store_true', help='do not run survivors on the whole program set')
    a = ap.parse_args()
    muts = TARGETED + swap_mutants(a.swaps, a.seed)
    if a.only:
        keep = set(a.only.split(','))
        muts = [m for m in muts if m[0] in keep]
    if a.dry:
        for name, f, old, new in muts:
            s = open(os.path.join(ROOT, f)).read()
            print(('ok      ' if s.count(old) >= 1 else 'MISSING ') + name + '  ' + old[:70] + '  ->  ' + new[:50])
        return
    env = dict(os.environ)
    env.setdefault('REFSIM', os.path.join(ROOT, 'refsim_tap'))
    workdir = os.path.join(ROOT, 'build/mut_backtop')
    os.makedirs(workdir, exist_ok=True)
    resf = os.path.join(workdir, 'results.txt')
    open(resf, 'w').close()
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        futs = [ex.submit(do_mutant, m, env, workdir, not a.no_full) for m in muts]
        for fu in cf.as_completed(futs):
            name, st, info = fu.result()
            line = f'{st:16s} {name}  {info}'
            print(line, flush=True)
            open(resf, 'a').write(line + '\n')


if __name__ == '__main__':
    main()
