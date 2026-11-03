#!/usr/bin/env python3
"""Mutation check of the DCache domain with ONE build: every mutant is guarded in the RTL copy by `(mut_sel == K) ? mutated : original`
(mut_sel comes from $TTG_MUT through a DPI call), so the whole check is one Verilator build + short fast-tick lock-step runs.
Screening: each mutant runs on a few short programs (first mismatch kills it); survivors are re-run on up to 12 short programs x 150k cycles.

usage: mut_dcache.py [--jobs N] [--only K,K,..] [--cap CYC] [--extra]     env REFSIM = memsys-tap refsim tree
"""
import argparse, concurrent.futures as cf, os, re, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = 'rtl/memsys/dcache/'
G = '/Users/ruyaoh/personal/tututugege-trace/build'
# (name, file, original expression text, mutated expression text) -- the original text must occur in the file
MUTANTS = [
  ('s1.fill-bank-not-occupied',  'dcache_s1.sv', "!(fill_occupies_bank && fill_bank == req_bank[i])", "1'b1"),
  ('s1.same-bank-not-denied',    'dcache_s1.sv', "req_v[j] && req_bank[j] == req_bank[i]", "1'b0"),
  ('s1.retry-ignores-blocked',   'dcache_s1.sv', "!real_v && !blocked[i] && rty_valid_q[i]", "!real_v && rty_valid_q[i]"),
  ('s1.retry-for-route-ids',     'dcache_s1.sv', "!slot_id_q[i][31]", "1'b1"),
  ('s1.fill-hold-dropped',       'dcache_s1.sv', "same_fill && !s2_fill_valid", "1'b0"),
  ('s1.fill-snap-ignores-s2',    'dcache_s1.sv', "fr_valid && !same_fill", "fr_valid"),
  ('s1.snapshot-merge-dropped',  'dcache_s1.sv', "mrg_en[p]", "1'b0"),
  ('s2ld.no-icache-probe',       'dcache_s2_ld.sv', "icache_req_s2 == 3'(i)", "1'b0"),
  ('s2ld.bypass-returns-cache-data','dcache_s2_ld.sv', "byp_data[i]", "hit_data"),
  ('s2ld.mshr-full-off-by-one',  'dcache_s2_ld.sv', "(free_in > used[i])", "(free_in >= used[i])"),
  ('s2ld.lru-on-bypass',         'dcache_s2_ld.sv', "normal && !byp_valid[i] && hit_any", "normal && hit_any"),
  ('s2st.to-fill-off',           'dcache_s2_st.sv', "normal && fr_valid && slot_addr[i][31:OFF_W] == fr_line", "1'b0"),
  ('s2st.free-chain-off-by-one', 'dcache_s2_st.sv', "(free_rem > used[i])", "(free_rem >= used[i])"),
  ('fill.victim-always-way0',    'dcache_s2_fill.sv', "plru_victim(fs_plru)", "2'd0"),
  ('fill.no-wb-stall',           'dcache_s2_fill.sv', "(!victim_dirty || wb_has_room)", "1'b1"),
  ('fill.tag-match-ignores-valid','dcache_s2_fill.sv', "fs_valid[w] && fs_tag[w] == fill_tag", "fs_tag[w] == fill_tag"),
  ('wb.send-ignores-accept',     'dcache_wb.sv', "(ax_req_accepted ? 1'b1 : send_q)", "send_q"),
  ('wb.busy-ignored',            'dcache_wb.sv', "mrg_idx[i] == head_a && send_a", "1'b0"),
  ('wb.find-range-off-by-one',   'dcache_wb_find.sv', "CNT_W'(j) < count", "CNT_W'(j) <= count"),
  ('wb.push-ignores-room',       'dcache_wb.sv', "push_valid && count_a < CNT_W'(WB_N)", "push_valid"),
  ('mshr.alloc-ignores-existing','dcache_mshr_alloc.sv', "req_valid[j] && !has_exist", "req_valid[j]"),
  ('mshr.alloc-skips-entry0',    'dcache_mshr_alloc.sv', "free_chain[j]", "free_chain[j] & ~MSHR_N'(1)"),
  ('mshr.resp-ready-ignores-take','dcache_mshr.sv', "ax_resp_valid ? take : !hold_valid_b", "!hold_valid_b"),
  ('mshr.fill-merge-dropped',    'dcache_mshr.sv', "mstrb_q[hold_id_a][b]", "1'b0"),
  ('mshr.free-count-off',        'dcache_mshr.sv', "CNT_W'(MSHR_N) - CNT_W'(n_valid)", "CNT_W'(MSHR_N - 1) - CNT_W'(n_valid)"),
  ('mshr.release-not-reusable',  'dcache_mshr.sv', "valid_q & ~rel", "valid_q"),
  ('mshr.accept-ignores-valid',  'dcache_mshr.sv', "ax_req_accepted_id == 8'(e) && valid_q[e]", "ax_req_accepted_id == 8'(e)"),
  ('resp.forward-only-mshr-hit', 'dcache_resp.sv', "ldrp_a[i][1]", "ldrp_a[i] == RP_MSHR_HIT"),
  ('resp.store-forward-dropped', 'dcache_resp.sv', "line_merge(frd_f, staddr_a[i][WORD_W-1:0], stdata_a[i], ststrb_a[i])", "frd_f"),
  ('resp.latch-not-cleared',     'dcache_resp.sv', "ldv_a & ~{NLD{phase0}}", "ldv_a"),
  ('resp.fill-wakeup-not-cleared','dcache_resp.sv', "fill_a && !phase0", "fill_a"),
  ('s1.snapshot-dirty-forgotten','dcache_s1.sv', "fill_snap && fr_dirty", "1'b0"),
  ('resp.load-forward-word0',    'dcache_resp.sv', "line_word(fr_data, ldaddr_a[i][WORD_W-1:0])", "line_word(fr_data, WORD_W'(0))"),
  ('wb.merge-strobe-ignored',    'dcache_wb.sv', "mrg_ok[p] && mrg_strb[p][b]", "mrg_ok[p]"),
  ('mshr.hold-not-released',     'dcache_mshr.sv', "hold_valid_a && !done_ok", "hold_valid_a"),
  ('arr.plru-touch-wrong-way',   'dcache_arr.sv', "plru_touch(b_plru[b], lu_way[k])", "plru_touch(b_plru[b], lu_way[k] ^ 2'd1)"),
  ('arr.fill-plru-wrong-way',     'dcache_arr.sv', "plru_touch(b_plru[b], fw_way)", "plru_touch(b_plru[b], fw_way ^ 2'd1)"),
]
NCFG = 9   # configurations of harness/include/ttg_dcache_rand.cpp
DECL = ('  import "DPI-C" function int ttg_mut_sel();\n  int unsigned mut_sel;\n  initial mut_sel = ttg_mut_sel();\n')
STUB = '#include <cstdlib>\nextern "C" int ttg_mut_sel() { const char* e = getenv("TTG_MUT"); return e ? atoi(e) : 0; }\n'
SCREEN = [('dcache-mshr-pressure', 100000), ('dcache-conflict-writeback', 100000), ('wb-burst', 100000), ('memory-stress-small', 100000),
          ('quick-sort', 100000), ('dhrystone', 100000), ('coremark', 100000)]


def prog_path(n):
    for p in (f'{G}/tests/{n}/{n}.bin', f'{ROOT}/build/dcache_tests/{n}/{n}.bin', f'/tmp/big/{n}.bin'):
        if os.path.exists(p):
            return p
    return None


def run_one(refsim, dylib, prog, cycles, mut, rand_cycles=None, rand_cfg=None):
    env = dict(os.environ, TTG_MUT=str(mut), TTG_REC_END=dylib, TTG_REC_N=str(cycles * 16))
    if rand_cycles:
        env['TTG_RAND_CYCLES'] = str(rand_cycles)
        env['TTG_REC_N'] = str(10**15)
        if rand_cfg is not None:
            env['TTG_RAND_CFG'] = str(rand_cfg)
    r = subprocess.run([f'{refsim}/build/simulator', prog], cwd=refsim, env=env, capture_output=True, text=True)
    out = r.stdout + r.stderr
    # a failed assertion stops the simulation early (the plugin still prints PASS for the ticks it saw): that kills the mutant
    a = re.search(r'%Error[^\n]*', out)
    if a:
        return True, 'assertion: ' + a.group(0)[:110]
    if 'LOCKSTEP PASS' in out:
        return False, ''
    m = re.search(r'MISMATCH cycle=(\d+) (\S+)', out)
    if m:
        t = int(m.group(1))
        return True, f'tick {t} (cycle {t // 16}) field {m.group(2)}'
    a = re.search(r'(Assertion|assert|%Error)[^\n]*', out)
    return True, 'abort/assert: ' + (a.group(0)[:90] if a else f'exit {r.returncode}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--only', default='')
    ap.add_argument('--rand', type=int, default=30000, help='CPU cycles per random-stimulus configuration for survivors (0 = skip)')
    ap.add_argument('--extra', action='store_true', help='re-run survivors on up to 12 short programs x 150k cycles')
    a = ap.parse_args()
    refsim = os.environ['REFSIM']
    T = os.path.join(ROOT, 'build/mutdc')
    shutil.rmtree(T, ignore_errors=True)
    for d in ('rtl', 'spec', 'harness', 'scripts'):
        shutil.copytree(os.path.join(ROOT, d), os.path.join(T, d))
    texts, ids, bad = {}, {}, []
    for k, (name, f, old, new) in enumerate(MUTANTS, 1):
        path = os.path.join(T, D + f)
        s = texts.setdefault(f, open(path).read())
        if s.count(old) < 1:
            bad.append(name); continue
        texts[f] = s.replace(old, f"((mut_sel == {k}) ? ({new}) : ({old}))", 1)
        ids[k] = name
    if bad:
        print('PATTERN MISSING:', bad); sys.exit(1)
    for f, s in texts.items():
        s = re.sub(r'(\n\);\n)', lambda m: m.group(1) + DECL, s, count=1)
        open(os.path.join(T, D + f), 'w').write(s)
    open(os.path.join(T, 'ttg_mut_stub.cpp'), 'w').write(STUB)
    env = dict(os.environ, BUILD_ONLY='1', VFLAGS='--assert -Wno-fatal', EXTRA_CPP=os.path.join(T, 'ttg_mut_stub.cpp'))
    r = subprocess.run(f'bash {T}/scripts/lockstep_ticks.sh dcache x', shell=True, env=env, capture_output=True, text=True)
    dylib = os.path.join(T, 'build/lockt_dcache/lock_dcache.dylib')
    if not os.path.exists(dylib):
        print('BUILD FAILED', (r.stdout + r.stderr)[-800:]); sys.exit(1)
    shutil.copy(dylib, dylib + '.prog')
    dylib = dylib + '.prog'
    # second plugin from the same Verilated model: random-stimulus campaign hook (harness/include/ttg_dcache_rand.cpp)
    env2 = dict(env, TICKS_END=os.path.join(ROOT, 'harness/include/ttg_dcache_rand.cpp'))
    subprocess.run(f'bash {T}/scripts/lockstep_ticks.sh dcache x', shell=True, env=env2, capture_output=True, text=True)
    rdylib = os.path.join(T, 'build/lockt_dcache/lock_dcache.dylib')
    shutil.copy(rdylib, rdylib + '.rand')
    rdylib = rdylib + '.rand'
    dummy = prog_path('dummy')
    progs = [(prog_path(n), c) for n, c in SCREEN if prog_path(n)]
    print(f'built: {len(ids)} mutants in one build; screening programs: {[os.path.basename(p) for p, _ in progs]}', flush=True)
    f0, _ = run_one(refsim, dylib, progs[0][0], 20000, 0)
    print('baseline (TTG_MUT=0) on', os.path.basename(progs[0][0]), 'FAIL' if f0 else 'PASS', flush=True)
    sel = [int(x) for x in a.only.split(',')] if a.only else list(ids)
    ex = []
    if a.extra:
        allp = [l.strip() for l in open(os.path.join(ROOT, 'build/lockt_all_dcache.progs'))]
        short = [p for p in allp if 'memory-stress' not in p and 'dhrystone' not in p and 'coremark' not in p][:12]
        ex = [(p, 150000) for p in short]

    def one(k):
        for prog, cyc in progs + (ex if a.extra else []):
            fail, info = run_one(refsim, dylib, prog, cyc, k)
            if fail:
                return k, 'KILLED', f'{os.path.basename(prog)}: {info}'
        if a.rand:
            for cfg in range(NCFG):      # one fresh process per configuration (an event that needs a quiet start is not lost)
                fail, info = run_one(refsim, rdylib, dummy, 1, k, a.rand, cfg)
                if fail:
                    return k, 'KILLED', f'random campaign cfg {cfg} ({a.rand} cycles): {info}'
        return k, 'SURVIVED', ''
    res = os.path.join(ROOT, 'build/mut_dcache.txt')
    open(res, 'w').close()
    with cf.ThreadPoolExecutor(a.jobs) as pool:
        for fu in cf.as_completed([pool.submit(one, k) for k in sel]):
            k, st, info = fu.result()
            line = f'{st:9s} {k:2d} {ids[k]}  {info}'
            print(line, flush=True); open(res, 'a').write(line + '\n')


if __name__ == '__main__':
    main()
