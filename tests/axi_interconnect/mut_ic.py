#!/usr/bin/env python3
"""axi_interconnect mutation check: ONE Verilator build holds every mutant, runtime selector TTG_MUT=K picks one (DPI; same scheme as
tests/axi_llc/mut_llc.py).  Each mutant is a textual replacement old -> new in rtl/memsys/axi_interconnect/*.sv, applied to a scratch copy as
`((axi_ic_pkg::mut_sel == K) ? (new) : (old))`; a mutant is killed when the lock-step of axi_interconnect reports a mismatch.

usage: mut_ic.py build <workdir>
       mut_ic.py run   <workdir> <list-file> [cycles [mutant-ids...]]      (env REFSIM, TTG_LLC_KB / TTG_LLC_WAYS select the reference LLC geometry)
"""
import os, re, shutil, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
SRC = os.path.join(ROOT, 'rtl/memsys/axi_interconnect')

# (id, file, old, new, why)
MUTANTS = [
    (1, 'axi_ic_rd.sv', "(m == MASTER_DCACHE_R) || ready_q[m]", "1'b1", "ready-first handshake dropped (accept immediately)"),
    (2, 'axi_ic_rd.sv', "assign rp_conf = (m == 0) && (m_id[m][3] == 1'b0) && rp_v[m_id[m][MW-1:0]];", "assign rp_conf = 1'b0;", "ICache id vs in-flight LLC mem id conflict (C++ quirk) removed"),
    (3, 'axi_ic_rd.sv', "(hz_lookup_valid && hz_lookup_master == 2'(m) && hz_lookup_id == m_id[m])", "1'b0", "LLC lookup (master,id) not part of the id conflict"),
    (4, 'axi_ic_stage.sv', "(3'(p) >= rr_pre)", "1'b1", "dispatcher has fixed priority instead of round robin"),
    (5, 'axi_ic_stage.sv', "!up_rd_q[stg_pop.master].v && (|elig_w)", "1'b0", "stalled-read preemption by a write removed"),
    (6, 'axi_ic_ar.sv', "assign fresh = lo_valid && !seen_match && !latch_q.v && !wr_haz;", "assign fresh = lo_valid && !latch_q.v && !wr_haz;", "stale-request (seen) guard removed"),
    (7, 'axi_ic_ar.sv', "~used", "~16'h0", "AXI id always 0 (no allocation)"),
    (8, 'axi_ic_ar.sv', "assign wr_haz = (wp_v[0] && wp_line[0] == line64(lo_addr)) || (wp_v[1] && wp_line[1] == line64(lo_addr));", "assign wr_haz = 1'b0;", "AR not blocked by a pending DDR write of the same line"),
    (9, 'axi_ic_aw.sv', "(|hit_pr) || (fr_v && fr_line == line64(lo_addr))", "1'b0", "AW not blocked by an outstanding DDR read of the same line"),
    (10, 'axi_ic_aw.sv', "assign o_wlast  = (w_q.sent == (w_q.tot2 ? 2'd1 : 2'd0));", "assign o_wlast  = 1'b0;", "WLAST never asserted"),
    (11, 'axi_ic_resp.sv', "assign li_rd_ready[i] = !v_q && !hz_rd_fresh[i];", "assign li_rd_ready[i] = !v_q;", "fresh flag ignored when taking an LLC read response"),
    (12, 'axi_ic_resp.sv', "assign li_wr_ready[i] = !v_q && (cnt_q < 2'd2);", "assign li_wr_ready[i] = !v_q;", "write-response delay line depth limit ignored"),
    (13, 'axi_ic_stage.sv', "(m != MASTER_DCACHE_R && phase0) ? stk_rd_q[m] : nat_rd_q[m]", "nat_rd_q[m]", "CPU-cycle sticky accepted flag (non-DCache masters) removed"),
    (14, 'axi_ic_wr.sv', "assign elig[i] = m_valid[i] && !hazard[i];", "assign elig[i] = m_valid[i];", "write accepted despite a same-line read hazard"),
    (15, 'axi_ic_ar.sv', "assign li_resp_data  = pend_q[comp_idx].ext ? (pend_q[comp_idx].data >> {pend_q[comp_idx].off, 3'b000})\n                                              : pend_q[comp_idx].data;", "assign li_resp_data  = pend_q[comp_idx].data;", "small (bypass) read data not shifted back out of the aligned beat"),
    (16, 'axi_ic_haz.sv', "(|a_ms)", "1'b0", "MSHR reads not part of the write hazard"),
    (17, 'axi_ic_aw.sv', "assign sh_data = issue_small(lo_size) ? (lo_data << {lo_addr[4:0], 3'b000}) : lo_data;", "assign sh_data = lo_data;", "small DDR write data not moved to its byte lane"),
    (18, 'axi_ic_resp.sv', "assign pop = (cnt_q != 2'd0) && !v_after_clear;", "assign pop = (cnt_q != 2'd0) && !v_q;", "write response pop does not see the same-tick consume"),
]


def build(work):
    if os.path.exists(work):
        shutil.rmtree(work)
    os.makedirs(work + '/rtl/memsys')
    for d in ('spec', 'harness'):
        os.symlink(os.path.join(ROOT, d), os.path.join(work, d))
    shutil.copytree(os.path.join(ROOT, 'rtl/common'), work + '/rtl/common')   # `find` in rtl_files.sh does not follow symlinks
    shutil.copytree(SRC, work + '/rtl/memsys/axi_interconnect')
    shutil.copytree(os.path.join(ROOT, 'rtl/memsys/axi_llc'), work + '/rtl/memsys/axi_llc')   # packages are shared by the file list
    os.makedirs(work + '/scripts')
    for f in ('lockstep_ticks_axi.sh', 'rtl_files.sh'):
        shutil.copy(os.path.join(ROOT, 'scripts', f), work + '/scripts/' + f)
    for k, f, old, new, why in MUTANTS:
        p = work + '/rtl/memsys/axi_interconnect/' + f
        t = open(p).read()
        assert t.count(old) == 1, (k, f, t.count(old))
        t = t.replace(old, f'((axi_ic_pkg::mut_sel == {k}) ? ({new}) : ({old}))' if not old.lstrip().startswith('assign') else wrap_assign(k, old, new))
        open(p, 'w').write(t)
    p = work + '/rtl/memsys/axi_interconnect/axi_ic_pkg.sv'
    t = open(p).read()
    t = t.replace('package axi_ic_pkg;\n', 'package axi_ic_pkg;\n  import "DPI-C" function int ttg_mut_sel();\n  int unsigned mut_sel = ttg_mut_sel();\n', 1)
    open(p, 'w').write(t)
    open(work + '/mut_stub.cpp', 'w').write('#include <cstdlib>\nextern "C" int ttg_mut_sel() { const char* e = getenv("TTG_MUT"); return e ? atoi(e) : 0; }\n')


def wrap_assign(k, old, new):
    """`assign lhs = rhs;` -> `assign lhs = (mut_sel == k) ? (new rhs) : (old rhs);`"""
    mo = re.match(r'(\s*assign\s+[\w\[\]\.:]+\s*=\s*)(.*);\s*$', old, re.S)
    mn = re.match(r'(\s*assign\s+[\w\[\]\.:]+\s*=\s*)(.*);\s*$', new, re.S)
    return f'{mo.group(1)}(axi_ic_pkg::mut_sel == {k}) ? ({mn.group(2)}) : ({mo.group(2)});'


def run(work, lst, cycles, only):
    env = dict(os.environ)
    out = f'{work}/build'
    env.update(OUTDIR=out, VFLAGS='-Wno-fatal --assert -fno-dfg', EXTRA_CPP=f'{work}/mut_stub.cpp', JOBS='2')
    script = work + '/scripts/lockstep_ticks_axi.sh'
    progs = [l.strip() for l in open(lst) if l.strip()]
    r = subprocess.run(['bash', script, 'axi_interconnect', progs[0]], env=dict(env, BUILD_ONLY='1'), capture_output=True, text=True)
    if 'built' not in r.stdout:
        print(r.stdout[-2000:], r.stderr[-2000:]); sys.exit('build failed')
    env['NOBUILD'] = '1'
    ids = only or [m[0] for m in MUTANTS]
    for k in ids:
        killed = None
        for p in progs:   # first program that kills it
            o = subprocess.run(['bash', script, 'axi_interconnect', p, str(cycles)], env=dict(env, TTG_MUT=str(k)),
                               capture_output=True, text=True).stdout
            mm = re.search(r'MISMATCH cycle=(\d+) (\S+)', o)
            if mm:
                killed = (os.path.basename(p), mm.group(0)); break
        info = [m for m in MUTANTS if m[0] == k][0]
        print(f'M{k:2d} {"KILLED by %s %s" % killed if killed else "SURVIVED"}  [{info[4]}]', flush=True)


if __name__ == '__main__':
    if sys.argv[1] == 'build':
        build(sys.argv[2])
    else:
        run(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 150000, [int(x) for x in sys.argv[5:]])
