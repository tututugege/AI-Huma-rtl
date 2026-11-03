#!/usr/bin/env python3
"""Mutation check of one CPU-phase memory block: ONE Verilator build holds every mutant, a runtime selector (TTG_MUT=k) picks one.

Every mutant of tests/memcpu/<mod>_mutants.py is `(name, file, ctx, old, new)`: `ctx` is a source snippet that occurs exactly once in
`file` and contains the expression `old`; inside the copy of the tree `old` is replaced by `(mut_sel == k) ? (new) : (old)` and the
module gets `mut_sel` from a DPI call (same idea as scripts/mut_backtop_fast.py).  Two stimuli kill a mutant:
  RANDOM : replay of traces/<mod>/rand*.trc (tb/memcpu/build_gen.sh <mod> run) on a replay binary built from the mutated tree
  REAL   : whole-program lock-step (reference simulator + plugin) over a few short programs
usage: mut_memcpu.py <mod> [--jobs N] [--cap CYCLES] [--progs N]        env REFSIM (memcpu-patched refsim, required)
Results: build/mutmc_<mod>/results.txt
"""
import argparse, concurrent.futures as cf, glob, os, re, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
G = '/Users/ruyaoh/personal/tututugege-trace/build'
SHORT = [G + '/tests/' + n + '/' + n + '.bin' for n in
         ('atomic-boundary', 'add-longlong', 'smc-div', 'interrupt-vectored', 'memory-stress-small', 'dcache-conflict-writeback')]
SHORT += [G + '/vm/vm-pagefault-test/vm_pagefault_test.bin', G + '/vm/vm-sum-fetch-test/vm_sum_fetch_test.bin',
          G + '/vm/vm-sfence-perm-test/vm_sfence_perm_test.bin', G + '/vm/vm-asid-test/vm_asid_test.bin', '/tmp/big/dhrystone.bin']
DECL = '  import "DPI-C" function int ttg_mut_sel();\n  int unsigned mut_sel;\n  initial mut_sel = ttg_mut_sel();\n'
STUB = '#include <cstdlib>\nextern "C" int ttg_mut_sel() { const char* e = getenv("TTG_MUT"); return e ? atoi(e) : 0; }\n'


def sh(cmd, env=None, cwd=None):
    return subprocess.run(cmd, shell=True, env=env, cwd=cwd, capture_output=True, text=True, errors='replace')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mod'); ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--cap', type=int, default=150000); ap.add_argument('--progs', type=int, default=12)
    a = ap.parse_args()
    ref = os.environ['REFSIM']
    mod = a.mod
    ns = {}
    exec(open(os.path.join(ROOT, 'tests/memcpu', mod + '_mutants.py')).read(), ns)
    muts = ns['MUTANTS']
    T = os.path.join(ROOT, 'build/mutmc_' + mod)
    shutil.rmtree(T, ignore_errors=True)
    for d in ('rtl', 'spec', 'harness', 'scripts', 'tb'):
        shutil.copytree(os.path.join(ROOT, d), os.path.join(T, d))
    orig, spans = {}, {}
    for k, (name, f, ctx, old, new) in enumerate(muts, 1):
        s = orig.setdefault(f, open(os.path.join(T, f)).read())
        if s.count(ctx) != 1 or ctx.count(old) < 1:
            print(f'PATTERN PROBLEM in mutant {k} {name}: ctx occurs {s.count(ctx)}x'); sys.exit(1)
        i = s.index(ctx) + ctx.index(old)
        spans.setdefault(f, []).append((i, i + len(old), k, new))
    texts = {}
    for f, sp in spans.items():
        s = orig[f]
        sp.sort(reverse=True)
        groups = []                           # identical spans chain into one nested selector
        for i, j, k, nw in sp:
            if groups and groups[-1][0] == (i, j):
                groups[-1][1].append((k, nw))
            else:
                groups.append(((i, j), [(k, nw)]))
        for n in range(len(groups) - 1):      # sorted descending: groups[n] starts after groups[n+1]
            if groups[n + 1][0][1] > groups[n][0][0]:
                print(f'OVERLAPPING mutants in {f}: {groups[n][1]} / {groups[n + 1][1]}'); sys.exit(1)
        for (i, j), ms in groups:
            expr = s[i:j]
            for k, nw in ms:
                expr = f'(mut_sel == {k}) ? ({nw}) : ({expr})'
            s = s[:i] + '(' + expr + ')' + s[j:]
        texts[f] = s
    for f in texts:
        s = re.sub(r'(\n\);\n)', lambda m: m.group(1) + DECL, texts[f], count=1)
        open(os.path.join(T, f), 'w').write(s)
    stub = os.path.join(T, 'ttg_mut_stub.cpp'); open(stub, 'w').write(STUB)
    env = dict(os.environ, BUILD_ONLY='1', VFLAGS='-Wno-fatal', REFSIM=ref)
    extra = stub
    if mod == 'axi_cpu_port_adapter':
        extra = '-Dttg_rec_cycle=ttg_rec_cycle_gen ' + os.path.join(T, 'tb/memcpu/axi_shell.cpp') + ' ' + stub
    env['EXTRA_CPP'] = extra
    r = sh(f'bash {T}/scripts/lockstep.sh {mod} x', env=env)
    dylib = os.path.join(T, f'build/lock_{mod}/lock_{mod}.dylib')
    if not os.path.exists(dylib):
        print('PLUGIN BUILD FAILED', (r.stdout + r.stderr)[-800:]); sys.exit(1)
    # replay binary with the same mutated RTL
    files = [l.strip() for l in sh(f'bash {T}/scripts/rtl_files.sh {T}').stdout.splitlines()]
    ob = os.path.join(T, 'build/replay_' + mod); os.makedirs(ob, exist_ok=True)
    sh(f'python3 {T}/harness/tools/iogen.py {T}/spec/{mod}.io {ob}')
    top = mod + '_tbwrap'
    cflags = (f'-std=c++17 -O1 -DTOP_HDR=\\"V{top}.h\\" -DTOP_T=V{top} -DFIELDS_HDR=\\"{mod}_fields.h\\" '
              f'-I{T}/harness/include -I{ob}')
    cmd = (['verilator', '--cc', '--exe', '--build', '-j', '4', '--trace', '-Wno-fatal', '-Wall', '--x-assign', '0', '--x-initial', '0',
            '--top-module', top, '-Mdir', ob + '/obj', '-o', 'replay', '-CFLAGS', cflags, f'{ob}/{top}.sv']
           + [os.path.join(T, x) for x in files] + [f'{T}/harness/src/replay_main.cpp', stub])
    r = subprocess.run(cmd, cwd=T, capture_output=True, text=True, errors='replace')
    replay = os.path.join(ob, 'obj/replay')
    if not os.path.exists(replay):
        print('REPLAY BUILD FAILED', '\n'.join(l for l in (r.stdout + r.stderr).splitlines() if 'rror' in l)[:1500]); sys.exit(1)
    traces = sorted(glob.glob(os.path.join(ROOT, 'traces', mod, 'rand*.trc')))
    progs = [p for p in SHORT if os.path.exists(p)][:a.progs]

    def run_random(k):
        for t in traces:
            r = sh(f'{replay} {t} --max-fail 1', env=dict(os.environ, TTG_MUT=str(k)))
            if 'FAIL' in r.stdout:
                m = re.search(r'MISMATCH rec=(\d+).*?(\S+): ref', r.stdout)
                return f'{os.path.basename(t)} rec {m.group(1) if m else "?"} {m.group(2) if m else ""}'
        return None

    def run_real(k):
        for p in progs:
            e = dict(os.environ, TTG_REC=dylib, TTG_MULTI='1', TTG_REC_N=str(a.cap), TTG_MUT=str(k))
            r = subprocess.run(['build/simulator', p], cwd=ref, env=e, capture_output=True, text=True, errors='replace')
            if any('LOCKSTEP FAIL' in l for l in r.stdout.splitlines()):
                mm = [l.strip() for l in r.stdout.splitlines() if 'MISMATCH' in l][:1]
                return os.path.basename(p) + ' ' + (mm[0] if mm else '')
        return None

    # baseline sanity (mutant 0 = original)
    b1 = run_random(0); b2 = run_real(0)
    print('baseline random:', 'FAIL ' + b1 if b1 else 'PASS', '| real:', 'FAIL ' + b2 if b2 else 'PASS', flush=True)
    if b1 or b2:
        sys.exit(1)
    res = {}

    def one(k):
        rr = run_random(k)
        rl = run_real(k)
        return k, rr, rl
    out = open(os.path.join(T, 'results.txt'), 'w')
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        for fu in cf.as_completed([ex.submit(one, k) for k in range(1, len(muts) + 1)]):
            k, rr, rl = fu.result()
            st = 'KILLED(real+random)' if rr and rl else 'KILLED(real only)' if rl else 'KILLED(random only)' if rr else 'SURVIVED'
            line = f'{st:20s} #{k:<2d} {muts[k-1][0]:28s} real: {rl or "-"} | random: {rr or "-"}'
            print(line, flush=True); out.write(line + '\n'); out.flush()
    out.close()


if __name__ == '__main__':
    main()
