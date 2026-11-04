#!/usr/bin/env python3
"""Mutation check of the front_top ASSEMBLY layer (rtl/frontend/front_top/*) and of the core glue (rtl/core/core_top/*).

One build per spec holds every mutant: the mutated text is guarded by `mut_sel == K`, mut_sel comes from the environment
(TTG_MUT=K) through a DPI call (same idea as scripts/mut_backtop_fast.py).  Mutants are screened on a few short programs
(whole-program lock-step against the reference); survivors are re-run on the short gate programs x 150k cycles.

usage: mut_front_top.py [--jobs N] [--layer front|core|all] [--cap N] [--extra N]
Needs REFSIM (default: refsim_tap).  Results: build/mut_front_top.txt
"""
import argparse, concurrent.futures as cf, os, re, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
G = '/Users/ruyaoh/personal/AI-Huma/trace-model/build'
FT = 'rtl/frontend/front_top/'
CO = 'rtl/core/core_top/'
SCREEN = [G + '/tests/smc-div/smc-div.bin', G + '/vm/vm-sum-fetch-test/vm_sum_fetch_test.bin',
          G + '/vm/vm-pagefault-test/vm_pagefault_test.bin', G + '/tests/add-longlong/add-longlong.bin',
          G + '/tests/atomic-boundary/atomic-boundary.bin', G + '/tests/interrupt-vectored/interrupt-vectored.bin',
          '/Users/ruyaoh/personal/AI-Huma/rtl/programs/big/dhrystone.bin', G + '/vm/vm-sfence-perm-test/vm_sfence_perm_test.bin',
          G + '/vm/vm-asid-test/vm_asid_test.bin']
SCREEN_CAP = {'/Users/ruyaoh/personal/AI-Huma/rtl/programs/big/dhrystone.bin': 150000}
DECL = ('  import "DPI-C" function int ttg_mut_sel();\n  int unsigned mut_sel;\n  initial mut_sel = ttg_mut_sel();\n')
STUB = '#include <cstdlib>\nextern "C" int ttg_mut_sel() { const char* e = getenv("TTG_MUT"); return e ? atoi(e) : 0; }\n'

# (name, file, old, new, extra declaration with @K@ placeholders)   -- `new` may use @K@ (the mutant number)
def g(old, new):
    return old, f'(mut_sel == @K@) ? ({new}) : ({old})'

M = []
def add(name, f, old, new, decl='', spec='front_top'):
    M.append((name, f, old, new, decl, spec))

# ---- front_top.sv: wiring between the blocks ----
add('ctrl_fifo_read_enable_const1', FT + 'front_top.sv', '.be_fifo_read_enable   (fifo_read_enable),',
    '.be_fifo_read_enable   ((mut_sel == @K@) ? 1\'b1 : fifo_read_enable),')
add('icache_invalidate_zero', FT + 'front_top.sv', '.invalidate      (do_predecode_flush),',
    '.invalidate      ((mut_sel == @K@) ? 1\'b0 : do_predecode_flush),')
add('icache_refetch_be_only', FT + 'front_top.sv', '.refetch         (global_refetch),',
    '.refetch         ((mut_sel == @K@) ? be_refetch : global_refetch),')
add('fa_wr_address_flip', FT + 'front_top.sv', '.fa_wr_address   (bpu_fetch_address),',
    '.fa_wr_address   ((mut_sel == @K@) ? (bpu_fetch_address ^ 32\'h4) : bpu_fetch_address),')
add('out_lane_valid_ignores_out_valid', FT + 'front_top.sv',
    'out_lane_valid[i] = front_out_valid && out_inst_valid[i];',
    'out_lane_valid[i] = ((mut_sel == @K@) ? 1\'b1 : front_out_valid) && out_inst_valid[i];')
add('ctrl_icache_ready_const1', FT + 'front_top.sv', '.icache_ready, .fa_full, .fa_empty, .inst_empty,',
    '.icache_ready((mut_sel == @K@) ? 1\'b1 : icache_ready), .fa_full, .fa_empty, .inst_empty,')
add('inst_rd_en_always', FT + 'front_top.sv', '.inst_rd_en      (predecode_can_run),',
    '.inst_rd_en      ((mut_sel == @K@) ? fa_rd_en : predecode_can_run),')
# ---- front_fetch_buf.sv ----
add('inst_wr_en_ignores_refetch', FT + 'front_fetch_buf.sv', 'assign inst_wr_en = ic_read_complete && !global_refetch;',
    'assign inst_wr_en = ic_read_complete && ((mut_sel == @K@) ? 1\'b1 : !global_refetch);')
add('predecode_pc_zero', FT + 'front_fetch_buf.sv', '.fetch_pc                 (ic_fetch_pc),',
    '.fetch_pc                 ((mut_sel == @K@) ? 32\'d0 : ic_fetch_pc),')
add('seq_next_pc_from_wrong_valid', FT + 'front_fetch_buf.sv', '.inst_valid  (ic_inst_valid),',
    '.inst_valid  (mutw_@K@),',
    'logic mutw_@K@ [FETCH_WIDTH];\n  always_comb begin\n    for (int i = 0; i < FETCH_WIDTH; i++) mutw_@K@[i] = (mut_sel == @K@) ? ic_page_fault_inst[i] : ic_inst_valid[i];\n  end\n')
add('fa_fifo_refetch_missing', FT + 'front_fetch_buf.sv', '.refetch          (global_refetch),\n    .rd_en            (fa_rd_en),',
    '.refetch          ((mut_sel == @K@) ? 1\'b0 : global_refetch),\n    .rd_en            (fa_rd_en),')
# ---- front_pred_path.sv ----
add('ptab_base_pc_is_next_pc', FT + 'front_pred_path.sv', '.wr_predict_base_pc            (bpu_fetch_address),',
    '.wr_predict_base_pc            ((mut_sel == @K@) ? bpu_predict_next_fetch_address : bpu_fetch_address),')
add('f2b_refetch_global', FT + 'front_pred_path.sv', '.refetch                                 (be_refetch),',
    '.refetch                                 ((mut_sel == @K@) ? global_refetch : be_refetch),')
add('checker_seq_next_pc_wrong', FT + 'front_pred_path.sv', '.seq_next_pc                          (inst_rd_seq_next_pc),',
    '.seq_next_pc                          ((mut_sel == @K@) ? ptab_rd_predict_next_fetch_address : inst_rd_seq_next_pc),')
add('f2b_wr_dir_uncorrected', FT + 'front_pred_path.sv', '.wr_predict_dir_corrected                (checker_dir_corrected),',
    '.wr_predict_dir_corrected                (mutw_@K@),',
    'logic mutw_@K@ [FETCH_WIDTH];\n  always_comb begin\n    for (int i = 0; i < FETCH_WIDTH; i++) mutw_@K@[i] = (mut_sel == @K@) ? ptab_rd_predict_dir[i] : checker_dir_corrected[i];\n  end\n')
add('out_pc_stride', FT + 'front_pred_path.sv', 'out_pc[i] = out_base_pc + 32\'(4 * i);',
    'out_pc[i] = out_base_pc + ((mut_sel == @K@) ? 32\'(2 * i) : 32\'(4 * i));')
add('out_next_pc_bypass_uncorrected', FT + 'front_pred_path.sv', 'out_predict_next_fetch_address = f2b_use_bypass ? checker_next_corrected',
    'out_predict_next_fetch_address = f2b_use_bypass ? ((mut_sel == @K@) ? ptab_rd_predict_next_fetch_address : checker_next_corrected)')
add('out_tage_tag_bypass_idx', FT + 'front_pred_path.sv', 'out_tage_tag[i][j] = f2b_use_bypass ? ptab_rd_tage_tag[i][j] : f2b_rd_tage_tag[i][j];',
    'out_tage_tag[i][j] = f2b_use_bypass ? ((mut_sel == @K@) ? ptab_rd_tage_tag[i][(j + 1) % TN_MAX] : ptab_rd_tage_tag[i][j]) : f2b_rd_tage_tag[i][j];')
add('bpu_upd_idxs_swapped_tags', FT + 'front_pred_path.sv', '.upd_valid, .base_pc, .actual_dir, .br_type, .target, .pred_dir, .alt_pred, .pcpn, .tags, .idxs,',
    '.upd_valid, .base_pc, .actual_dir, .br_type, .target, .pred_dir, .alt_pred, .pcpn, .tags, .idxs,')   # placeholder removed below
M.pop()
add('bpu_refetch_address_wrong', FT + 'front_pred_path.sv', '.refetch_address,\n    .icache_read_ready          (bpu_icache_read_ready),',
    '.refetch_address((mut_sel == @K@) ? 32\'d0 : refetch_address),\n    .icache_read_ready          (bpu_icache_read_ready),')
# ---- core glue (core spec) ----
add('core_can_read_ignores_refetch', CO + 'core_front.sv', 'assign can_read = !b2f_stall || b2f_refetch;',
    'assign can_read = !b2f_stall || ((mut_sel == @K@) ? 1\'b0 : b2f_refetch);', spec='core_top')
add('core_mstatus_sum_bit', CO + 'core_front.sv', '.csr_status_mstatus_sum     (csr_status_mstatus[18]),',
    '.csr_status_mstatus_sum     ((mut_sel == @K@) ? csr_status_mstatus[19] : csr_status_mstatus[18]),', spec='core_top')
add('core_hold_pc_from_front', CO + 'core_front2back.sv', 'hold_pc_q[j]          <= back_pc[j];',
    'hold_pc_q[j]          <= (mut_sel == @K@) ? fe_pc[j] : back_pc[j];', spec='core_top')
add('core_stall_reg_const0', CO + 'core_back2front.sv', 'stall_q           <= out_stall;',
    'stall_q           <= (mut_sel == @K@) ? 1\'b0 : out_stall;', spec='core_top')
add('core_cut_includes_taken_lane_successors', CO + 'core_front2back.sv', 'cut_before[j] = |(taken_lane & ((FETCH_WIDTH\'(1) << j) - FETCH_WIDTH\'(1)));',
    'cut_before[j] = |(taken_lane & ((FETCH_WIDTH\'(1) << j) - ((mut_sel == @K@) ? FETCH_WIDTH\'(0) : FETCH_WIDTH\'(1))));', spec='core_top')
add('core_ret_needs_no_imm0', CO + 'core_back2front.sv', '&& (commit_imm[i] == 32\'d0);',
    '&& ((mut_sel == @K@) ? 1\'b1 : (commit_imm[i] == 32\'d0));', spec='core_top')
add('core_target_plus4_for_branch', CO + 'core_back2front.sv', 'class_target[i] = (is_br[i] || is_jal[i] || is_jalr[i]) ? commit_diag_val[i] : ftq_pc[i] + 32\'d4;',
    'class_target[i] = (is_br[i] || is_jal[i] || ((mut_sel == @K@) ? 1\'b0 : is_jalr[i])) ? commit_diag_val[i] : ftq_pc[i] + 32\'d4;', spec='core_top')
add('core_refetch_reg_uses_stall', CO + 'core_back2front.sv', 'refetch_q         <= out_mispred;',
    'refetch_q         <= (mut_sel == @K@) ? out_stall : out_mispred;', spec='core_top')
add('core_call_needs_dest_en', CO + 'core_back2front.sv', 'is_call[i] = is_jal[i] && commit_dest_en[i] && (commit_dest_areg[i] == 6\'d1);',
    'is_call[i] = is_jal[i] && ((mut_sel == @K@) ? 1\'b1 : commit_dest_en[i]) && (commit_dest_areg[i] == 6\'d1);', spec='core_top')
add('core_upd_valid_not_gated_pc', CO + 'core_back2front.sv', 'upd_pcpn_d[i]       = commit_valid[i] ? ftq_pcpn[i]        : 3\'d0;',
    'upd_pcpn_d[i]       = commit_valid[i] ? ((mut_sel == @K@) ? ftq_altpcpn[i] : ftq_pcpn[i])        : 3\'d0;', spec='core_top')
add('core_itlb_flush_is_fence_i', CO + 'core_back2front.sv', 'itlb_flush_q      <= rob_bcast_fence;',
    'itlb_flush_q      <= (mut_sel == @K@) ? rob_bcast_fence_i : rob_bcast_fence;', spec='core_top')


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)


def lockstep_one(T, dylib, prog, cap, env):
    e = dict(env, TTG_REC=dylib, TTG_MULTI='1', TTG_REC_N=str(cap))
    r = subprocess.run(['build/simulator', prog], cwd=env['REFSIM'], env=e, capture_output=True, text=True, errors='replace')
    lines = [l for l in r.stdout.splitlines() if l.startswith('LOCKSTEP') or 'MISMATCH' in l]
    fail = [l for l in lines if 'LOCKSTEP FAIL' in l]
    mm = [l.strip() for l in lines if 'MISMATCH' in l][:1]
    return (fail[0] if fail else None), (mm[0] if mm else '')


def build(spec, muts, jobs_env):
    T = os.path.join(ROOT, f'build/mutft_{spec}')
    shutil.rmtree(T, ignore_errors=True)
    for d in ('rtl', 'spec', 'harness', 'scripts'):
        shutil.copytree(os.path.join(ROOT, d), os.path.join(T, d))
    ids, texts, decls = {}, {}, {}
    for name, f, old, new, decl, _ in muts:
        k = len(ids) + 1
        s = texts.setdefault(f, open(os.path.join(T, f)).read())
        if s.count(old) != 1:
            print(f'PATTERN PROBLEM ({s.count(old)} matches): {name}'); continue
        texts[f] = s.replace(old, new.replace('@K@', str(k)), 1)
        decls[f] = decls.get(f, '') + decl.replace('@K@', str(k))
        ids[k] = name
    for f, s in texts.items():
        s = re.sub(r'(\n\);\n)', lambda m: m.group(1) + DECL + decls.get(f, ''), s, count=1)
        open(os.path.join(T, f), 'w').write(s)
    open(os.path.join(T, 'ttg_mut_stub.cpp'), 'w').write(STUB)
    env = dict(os.environ, BUILD_ONLY='1', VFLAGS='-Wno-fatal', EXTRA_CPP=os.path.join(T, 'ttg_mut_stub.cpp'), **jobs_env)
    r = subprocess.run(f'bash {T}/scripts/lockstep.sh {spec} x', shell=True, env=env, capture_output=True, text=True)
    dylib = os.path.join(T, f'build/lock_{spec}/lock_{spec}.dylib')
    if not os.path.exists(dylib):
        print('BUILD FAILED', spec, (r.stdout + r.stderr)[-800:]); sys.exit(1)
    return T, dylib, ids, env


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--jobs', type=int, default=3)
    ap.add_argument('--layer', default='all')
    ap.add_argument('--cap', type=int, default=150000)
    ap.add_argument('--extra', type=int, default=12, help='short gate programs for survivors')
    a = ap.parse_args()
    refsim = os.environ.get('REFSIM', os.path.join(ROOT, 'refsim_tap'))
    resf = os.path.join(ROOT, 'build/mut_front_top.txt'); open(resf, 'w').close()
    lst = os.path.join(ROOT, 'build/lockstep_multi.progs')
    rest = [l.strip() for l in open(lst)] if os.path.exists(lst) else []
    for spec in ('front_top', 'core_top'):
        if a.layer != 'all' and not spec.startswith(a.layer): continue
        muts = [m for m in M if m[5] == spec]
        T, dylib, ids, env = build(spec, muts, {'REFSIM': refsim})
        print(f'[{spec}] built; {len(ids)} mutants in one build', flush=True)
        progs = [p for p in SCREEN if os.path.exists(p)]
        extra = [p for p in rest if p not in progs and os.path.exists(p) and 'big' not in p][:a.extra]

        def one(k):
            e = dict(env, TTG_MUT=str(k))
            for ph, group in (('screen', progs), ('rerun', extra)):
                for prog in group:
                    fail, mm = lockstep_one(T, dylib, prog, SCREEN_CAP.get(prog, a.cap), e)
                    if fail:
                        return k, 'KILLED' if ph == 'screen' else 'KILLED(rerun)', f'{os.path.basename(prog)}: {mm}'
            return k, 'SURVIVED', ''
        fail, _ = lockstep_one(T, dylib, progs[0], a.cap, dict(env, TTG_MUT='0'))
        print(f'[{spec}] baseline (TTG_MUT=0) on {os.path.basename(progs[0])}:', 'FAIL' if fail else 'PASS', flush=True)
        with cf.ThreadPoolExecutor(a.jobs) as ex:
            for fu in cf.as_completed([ex.submit(one, k) for k in ids]):
                k, st, info = fu.result()
                line = f'{spec:9s} {st:14s} {ids[k]}  {info}'
                print(line, flush=True); open(resf, 'a').write(line + '\n')


if __name__ == '__main__':
    main()
