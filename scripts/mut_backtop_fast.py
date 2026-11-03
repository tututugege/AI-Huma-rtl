#!/usr/bin/env python3
"""Fast mutation check of the back_top integration layer: ONE build holds every mutant, a runtime selector picks one.

mut_backtop.py builds the RTL once per mutant (minutes each).  Here every mutant is guarded in the source by
`(mut_sel == K) ? mutated : original`; mut_sel comes from the environment (TTG_MUT=K) through a DPI call, so the whole
check costs one Verilator build plus short simulations.  Mutants whose text is not an `assign ... = expr;` or a port
connection (localparams, if-statements) stay in mut_backtop.py.

usage: mut_backtop_fast.py [--jobs N] [--swaps K] [--seed S] [--cap N]
"""
import argparse, concurrent.futures as cf, os, re, shutil, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mut_backtop as mb

ROOT = mb.ROOT
EXTRA_DECL = []
BT_TEXT = open(os.path.join(ROOT, mb.BT + 'back_top.sv')).read()
DECL = ('  import "DPI-C" function int ttg_mut_sel();\n  int unsigned mut_sel;\n  initial mut_sel = ttg_mut_sel();\n')
STUB = 'extern "C" int ttg_mut_sel() { const char* e = getenv("TTG_MUT"); return e ? atoi(e) : 0; }\n'


def port_is_input(old):
    """`.p(n),` in back_top.sv: True when p is an input of the instantiated module (an output would need a different mutation)"""
    i = BT_TEXT.find(old)
    inst = list(re.finditer(r'^  (\w+)\s+(?:#\([^)]*\)\s*)?\w+\s*\(\s*$', BT_TEXT[:i], re.M))
    if not inst:
        return False
    mod, port = inst[-1].group(1), re.match(r'\.(\w+)', old).group(1)
    for dp, _, fs in os.walk(os.path.join(ROOT, 'rtl')):
        for fn in fs:
            if fn.endswith('.sv'):
                t = open(os.path.join(dp, fn)).read()
                if re.search(r'^module\s+' + mod + r'\b', t, re.M):
                    hdr = t[:t.find(');')]
                    return bool(re.search(r'\binput\b[^,;]*\b' + port + r'\b\s*(,|$|\n|\[)', hdr))
    return False


def guard(old, new, k):
    m1 = re.match(r'^(assign\s+[^=]+?=\s*)(.*?);$', old.strip(), re.S)
    m2 = re.match(r'^(assign\s+[^=]+?=\s*)(.*?);$', new.strip(), re.S)
    if m1 and m2 and m1.group(1).strip() == m2.group(1).strip():
        return f'{m1.group(1)}(mut_sel == {k}) ? ({m2.group(2)}) : ({m1.group(2)});'
    c1 = re.match(r'^\.(\w+)\((\w+)\),$', old)
    c2 = re.match(r'^\.(\w+)\((\w+)\),$', new)
    if c1 and c2 and port_is_input(old):   # arrays cannot go through ?: -> a mux wire per mutant, declared with the net's own type
        n1, n2 = c1.group(2), c2.group(2)
        m = re.search(r'^  logic\s*((?:\[[^\]]+\])?)\s*' + n1 + r'\s*((?:\[[^\]]+\])*)\s*;', BT_TEXT, re.M)
        EXTRA_DECL.append(f'  logic {m.group(1)} mutw_{k} {m.group(2)};\n  always_comb begin if (mut_sel == {k}) mutw_{k} = {n2}; else mutw_{k} = {n1}; end\n')
        return f'.{c1.group(1)}(mutw_{k}),'
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--jobs', type=int, default=6)
    ap.add_argument('--swaps', type=int, default=14)
    ap.add_argument('--seed', type=int, default=7)
    ap.add_argument('--cap', type=int, default=300000)
    a = ap.parse_args()
    muts = mb.TARGETED + mb.swap_mutants(a.swaps, a.seed)
    T = os.path.join(ROOT, 'build/mutall')
    shutil.rmtree(T, ignore_errors=True)
    for d in ('rtl', 'spec', 'harness', 'scripts'):
        shutil.copytree(os.path.join(ROOT, d), os.path.join(T, d))
    ids, skipped = {}, []
    texts = {}
    for name, f, old, new in muts:
        g = guard(old, new, len(ids) + 1)
        if g is None:
            skipped.append(name); continue
        s = texts.setdefault(f, open(os.path.join(T, f)).read())
        if old not in s:
            skipped.append(name + '(pattern missing)'); continue
        texts[f] = s.replace(old, g, 1)
        ids[len(ids) + 1] = name
    for f in {m[1] for m in muts}:
        s = texts.get(f) or open(os.path.join(T, f)).read()
        extra = ''.join(EXTRA_DECL) if f.endswith('back_top.sv') else ''
        s = re.sub(r'(\n\);\n)', lambda m: m.group(1) + DECL + extra, s, count=1)
        open(os.path.join(T, f), 'w').write(s)
    open(os.path.join(T, 'ttg_mut_stub.cpp'), 'w').write('#include <cstdlib>\n' + STUB)
    env = dict(os.environ, BUILD_ONLY='1', VFLAGS='-Wno-fatal', EXTRA_CPP=os.path.join(T, 'ttg_mut_stub.cpp'),
               REFSIM=os.environ.get('REFSIM', os.path.join(ROOT, 'refsim_tap')))
    r = subprocess.run(f'bash {T}/scripts/lockstep.sh back_top x', shell=True, env=env, capture_output=True, text=True)
    dylib = os.path.join(T, 'build/lock_back_top/lock_back_top.dylib')
    if not os.path.exists(dylib):
        print('BUILD FAILED', (r.stdout + r.stderr)[-600:]); sys.exit(1)
    print(f'built; {len(ids)} mutants in one build; not covered here: {skipped}', flush=True)
    progs = [p for p in mb.SCREEN if os.path.exists(p)]
    lst = os.path.join(ROOT, 'build/lockstep_multi.progs')
    rest = [l.strip() for l in open(lst)] if os.path.exists(lst) else []
    progs += [p for p in rest if p not in progs and os.path.exists(p)][:int(os.environ.get('EXTRA_PROGS', '12'))]   # short gate programs first

    def one(k):
        e = dict(env, TTG_MUT=str(k))
        for prog in progs:
            fail, mm = mb.lockstep_one(T, dylib, prog, mb.SCREEN_CAP.get(prog, 150000), e)
            if fail:
                return k, 'KILLED', f'{os.path.basename(prog)}: {mm}'
        return k, 'SURVIVED', ''
    # sanity: mutant 0 (none selected) must pass everything quickly on the first program
    fail, _ = mb.lockstep_one(T, dylib, progs[0], a.cap, dict(env, TTG_MUT='0'))
    print('baseline (TTG_MUT=0) on', os.path.basename(progs[0]), 'FAIL' if fail else 'PASS', flush=True)
    resf = os.path.join(ROOT, 'build/mut_backtop_fast.txt')
    open(resf, 'w').close()
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        for fu in cf.as_completed([ex.submit(one, k) for k in ids]):
            k, st, info = fu.result()
            line = f'{st:9s} {ids[k]}  {info}'
            print(line, flush=True); open(resf, 'a').write(line + '\n')


if __name__ == '__main__':
    main()
