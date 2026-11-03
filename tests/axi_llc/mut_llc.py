#!/usr/bin/env python3
"""axi_llc mutation check: ONE Verilator build holds every mutant, the runtime selector TTG_MUT=K picks one (DPI, like mut_backtop_fast.py).

Each mutant is a textual replacement  old -> new  of an expression in rtl/memsys/axi_llc/*.sv, applied to a scratch copy as
`((axi_llc_pkg::mut_sel == K) ? (new) : (old))`.  The scratch tree is built by the normal lock-step script (geometry via SETS/WAYS),
then every mutant is run on a program list; a mutant is "killed" when the lock-step reports a mismatch.

usage: mut_llc.py build  <workdir> [SETS WAYS]        # build the all-mutants model
       mut_llc.py run    <workdir> <list-file> [cycles [mutant-ids...]]   # run mutants over programs (REFSIM and TTG_LLC_* env as for run_all.sh)
"""
import os, re, shutil, subprocess, sys, concurrent.futures as cf

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
SRC = os.path.join(ROOT, 'rtl/memsys/axi_llc')

# (id, file, old, new, why)
MUTANTS = [
    (1, 'axi_llc_pkg.sv', "(WB'(w) == WB'(WAYS - 1)) ? '0 : w + WB'(1)", "w", "replacement pointer never advances"),
    (2, 'axi_llc_s3_lookup.sv', "      c.tdirty = 1'b1;\n      c.trepl = next_way(hw);", "      c.tdirty = 1'b0;\n      c.trepl = next_way(hw);", "write hit does not set dirty"),
    (3, 'axi_llc_s4_mem.sv', "          c.tdirty = 1'b0;\n          c.trepl", "          c.tdirty = 1'b1;\n          c.trepl", "refill installed dirty"),
    (4, 'axi_llc_s3_lookup.sv', "      c.n.ms[fi].vdirty = vd;\n      c.n.ms[fi].vdone", "      c.n.ms[fi].vdirty = 1'b0;\n      c.n.ms[fi].vdone", "read-miss victim dirtiness dropped"),
    (5, 'axi_llc_qry_pkg.sv', "s.vwb.valid && s.vwb.addr == line", "1'b0", "global victim slot ignored by victim_line_pending"),
    (6, 'axi_llc_s2_wpath.sv', "!c.n.vwb.valid && rr.rvq.cnt != 3'd0", "!c.n.vwb.valid && c.n.rvq.cnt != 3'd0", "queue reload uses new count (removes the duplicate-issue quirk)"),
    (7, 'axi_llc_s1_rresp.sv', "rr.rr[m].valid && rr.rr[m].fresh", "rr.rr[m].valid && 1'b0", "fresh flag ignored (response consumed in the tick it appears)"),
    (8, 'axi_llc_tables.sv', "pv_q[2]", "pv_q[1]", "table delivery after 2 ticks instead of 3"),
    (9, 'axi_llc_s3_lookup.sv', "miss_write(rr, ii, c, inv, iw)", "miss_write(rr, ii, c, 1'b0, iw)", "write miss never prefers an invalid way"),
    (10, 'axi_llc_qry_pkg.sv', "!s.ms[i].rcomm && set_of(s.ms[i].addr) == set", "set_of(s.ms[i].addr) == set", "refill reservation also keeps committed refills"),
    (11, 'axi_llc_s4_mem.sv', "!rr.ms[s].valid", "1'b1", "bypass direct-issue ignores old-slot occupancy"),
    (12, 'axi_llc_s3_lookup.sv', "rr.ms[s].way == hw", "1'b1", "write hit marks every same-set MSHR victim"),
    (13, 'axi_llc_pkg.sv', "7'(b) < limit && strb[b]", "7'(b) < limit", "write merge ignores the byte strobe"),
    (14, 'axi_llc_s2_wpath.sv', "c.n.rr_write = ~widx;", "c.n.rr_write = widx;", "write master round-robin not advanced"),
    (15, 'axi_llc_s5_accept.sv', "!(!ii.rd_byp[idx] && idx != 2'd1 && has_mshr_for_master(c.n, idx))", "1'b1", "per-master MSHR limit of non-DCache masters removed"),
    (16, 'axi_llc_s3_lookup.sv', "resp_of(rr.laddr, ii.lk_line[hw])", "ii.lk_line[hw]", "read hit ignores the word offset"),
]


def build(work, sets, ways):
    if os.path.exists(work):
        shutil.rmtree(work)
    os.makedirs(work + '/rtl/memsys')
    for d in ('rtl/common', 'spec', 'harness', 'scripts'):
        os.symlink(os.path.join(ROOT, d), os.path.join(work, d))
    shutil.copytree(SRC, work + '/rtl/memsys/axi_llc')
    # real scripts dir is symlinked; scripts compute ROOT from their own (resolved) path -> use a copy of the two scripts
    os.unlink(work + '/scripts')
    os.makedirs(work + '/scripts')
    for f in ('lockstep_ticks_axi.sh', 'rtl_files.sh'):
        shutil.copy(os.path.join(ROOT, 'scripts', f), work + '/scripts/' + f)
    for k, f, old, new, why in MUTANTS:
        p = work + '/rtl/memsys/axi_llc/' + f
        t = open(p).read()
        assert t.count(old) == 1, (k, f, t.count(old))
        t = t.replace(old, guard(k, old, new))
        open(p, 'w').write(t)
    p = work + '/rtl/memsys/axi_llc/axi_llc_pkg.sv'
    t = open(p).read()
    t = t.replace('package axi_llc_pkg;\n', 'package axi_llc_pkg;\n  import "DPI-C" function int ttg_mut_sel();\n  int unsigned mut_sel = ttg_mut_sel();\n', 1)
    open(p, 'w').write(t)
    open(work + '/mut_stub.cpp', 'w').write('#include <cstdlib>\nextern "C" int ttg_mut_sel() { const char* e = getenv("TTG_MUT"); return e ? atoi(e) : 0; }\n')


ASSIGN = re.compile(r'^(\s*[\w.\[\]]+\s*=\s*)(.*);$')


def guard(k, old, new):
    """assignment lines -> `lhs = (mut_sel == k) ? (new rhs) : (old rhs);` per differing line, otherwise an expression wrapper"""
    ol, nl = old.split('\n'), new.split('\n')
    if all(ASSIGN.match(a) and ASSIGN.match(b) for a, b in zip(ol, nl) if a != b) and any(a != b for a, b in zip(ol, nl)) \
            and all(ASSIGN.match(a) or True for a in ol):
        out = []
        for a, b in zip(ol, nl):
            if a == b:
                out.append(a)
            else:
                m, m2 = ASSIGN.match(a), ASSIGN.match(b)
                out.append(f'{m.group(1)}(mut_sel == {k}) ? ({m2.group(2)}) : ({m.group(2)});')
        return '\n'.join(out)
    return f'((mut_sel == {k}) ? ({new}) : ({old}))'


def run(work, lst, cycles, only):
    env = dict(os.environ)
    sets, ways = env.get('SETS', '4096'), env.get('WAYS', '16')
    out = f'{work}/build'
    env.update(OUTDIR=out, VFLAGS=f'-Wno-fatal --assert -fno-dfg -DAXI_LLC_SETS={sets} -DAXI_LLC_WAYS={ways}',
               EXTRA_CPP=f'{work}/mut_stub.cpp', JOBS='2')
    script = work + '/scripts/lockstep_ticks_axi.sh'
    progs = [l.strip() for l in open(lst) if l.strip()]
    r = subprocess.run(['bash', script, 'axi_llc', progs[0]], env=dict(env, BUILD_ONLY='1'), capture_output=True, text=True)
    if 'built' not in r.stdout:
        print(r.stdout[-2000:], r.stderr[-2000:]); sys.exit('build failed')
    env['NOBUILD'] = '1'
    ids = only or [m[0] for m in MUTANTS]

    def one(job):
        k, p = job
        e = dict(env, TTG_MUT=str(k))
        o = subprocess.run(['bash', script, 'axi_llc', p, str(cycles)], env=e, capture_output=True, text=True).stdout
        m = re.search(r'LOCKSTEP FAIL.*|MISMATCH.*', o)
        return k, p, ('KILL ' + (re.search(r'MISMATCH cycle=(\d+) (\S+)', o).group(0) if re.search(r'MISMATCH cycle=(\d+) (\S+)', o) else m.group(0))) if m else ('pass' if 'LOCKSTEP PASS' in o else 'ERR ' + o[:80])
    res = {k: [] for k in ids}
    for k in ids:  # baseline sanity: mutant 0 must pass is checked by the normal runs
        pass
    with cf.ThreadPoolExecutor(int(env.get('MJOBS', '2'))) as ex:
        for k in ids:
            killed = None
            for p in progs:  # first program that kills it
                _, _, r = one((k, p))
                if r.startswith('KILL'):
                    killed = (os.path.basename(p), r)
                    break
            info = [m for m in MUTANTS if m[0] == k][0]
            print(f'M{k:2d} {"KILLED by " + killed[0] + " " + killed[1] if killed else "SURVIVED"}  [{info[4]}]', flush=True)


if __name__ == '__main__':
    if sys.argv[1] == 'build':
        build(sys.argv[2], *(sys.argv[3:5] if len(sys.argv) > 4 else ('4096', '16')))
    else:
        run(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 150000, [int(x) for x in sys.argv[5:]])
