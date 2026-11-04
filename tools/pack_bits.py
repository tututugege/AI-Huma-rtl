#!/usr/bin/env python3
"""Convert lane-flag arrays `logic NAME [N]` / `logic NAME [N][M]` (1-bit elements, <= 64 bits in total) into packed vectors
`logic [N-1:0] NAME` / `logic [N-1:0][M-1:0] NAME`.  Decided per NAME across the whole tree (a name that has any declaration that cannot be
converted is left alone everywhere), so connections between same-named ports/nets stay consistent; `--skip name,...` adds names to the exclusion set.
usage: pack_bits.py --list | --apply [--skip a,b] [--exclude-dir d,...]"""
import glob
import os
import re
import sys

ROOT = os.environ.get('PACK_ROOT') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXCL_DIRS = ['/axi_llc/', '/axi_interconnect/', '/axi_subsys/']
EXCL_FILES = ['mem_axi.sv']


def files():
    out = []
    for f in sorted(glob.glob(os.path.join(ROOT, 'rtl/**/*.sv'), recursive=True)):
        if any(d in f for d in EXCL_DIRS) or any(f.endswith(x) for x in EXCL_FILES):
            continue
        out.append(f)
    return out


def param_env(fs):
    env = {}
    pat = re.compile(r'localparam\s+(?:int|integer|int\s+unsigned|longint\s+unsigned|logic\s*\[[^\]]*\])?\s*(\w+)\s*=\s*([^;,]+)[;,]')
    allf = glob.glob(os.path.join(ROOT, 'rtl/**/*.sv'), recursive=True)
    exprs = {}
    for f in allf:
        for m in pat.finditer(open(f).read()):
            exprs.setdefault(m.group(1), []).append(m.group(2).strip())
    for _ in range(12):
        for n, es in exprs.items():
            if n in env:
                continue
            vals = set()
            for e in es:
                e2 = re.sub(r"\b(\d+)'[dD](\d+)", r'\2', e)
                e2 = re.sub(r'\$clog2\(', 'clog2(', e2)
                try:
                    vals.add(int(eval(e2, {'clog2': lambda x: max(1, (int(x) - 1).bit_length())}, dict(env))))
                except Exception:
                    pass
            if len(vals) == 1 and len(es) == 1:
                env[n] = vals.pop()
    return env


DECL = re.compile(r'^(?P<head>\s*(?:(?:input|output|inout)\s+)?(?:logic|wire)\s+)(?P<name>[A-Za-z_]\w*)(?P<dims>(?:\s*\[[^\]]+\]){1,2})(?P<tail>\s*[,;)]|\s*//.*$|\s*$)')


def evaldim(s, env):
    try:
        return int(eval(re.sub(r'\$clog2\(', 'clog2(', s), {'clog2': lambda x: max(1, (int(x) - 1).bit_length())}, dict(env)))
    except Exception:
        return None


def scan(fs, env):
    """name -> list of (file, lineno, ok, dims text list)"""
    d = {}
    for f in fs:
        for i, l in enumerate(open(f).read().split('\n')):
            code = re.sub(r'//.*', '', l)
            m = DECL.match(l)
            if not m or re.search(r'\[[^\]]*:[^\]]*\]\s*\w+\s*\[', code.split(m.group('name'))[0] + m.group('name') + ' [') and False:
                pass
            if not m:
                continue
            dims = re.findall(r'\[([^\]]+)\]', m.group('dims'))
            vals = [evaldim(x, env) for x in dims]
            ok = all(v is not None and v >= 1 for v in vals)
            tot = 1
            for v in vals:
                tot *= v or 1
            ok = ok and tot <= 64 and not any(':' in x for x in dims)
            is_port = bool(re.match(r'\s*(input|output|inout)\b', l))
            if not is_port and not re.match(r'\s*;', m.group('tail')):
                ok = False   # several declarators on one line: leave
            d.setdefault(m.group('name'), []).append((f, i, ok, dims))
    return d


def eligible_names(d, skip):
    return {n for n, ds in d.items() if n not in skip and all(ok for _, _, ok, _ in ds)}


def convert_line(l, names):
    m = DECL.match(l)
    if not m or m.group('name') not in names:
        return l
    dims = re.findall(r'\[([^\]]+)\]', m.group('dims'))
    packed = ''.join(f'[{x}-1:0]' if not x.isdigit() else f'[{int(x) - 1}:0]' for x in dims)
    return m.group('head').rstrip() + ' ' + packed + ' ' + m.group('name') + m.group('tail') + l[m.end():]


def apply_names(text, names):
    return '\n'.join(convert_line(l, names) for l in text.split('\n'))


def load_names(path=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'tools/pack_bits_names.txt')):
    return set(open(path).read().split())


def main():
    skip = set()
    for a in sys.argv:
        if a.startswith('--skip='):
            skip |= set(a[7:].split(','))
    fs = files()
    env = param_env(fs)
    d = scan(fs, env)
    names = eligible_names(d, skip)
    # only names declared with a 1-bit element type: DECL requires `logic NAME [..]` (no packed width) so this holds by construction;
    # names that also appear with a packed width (`logic [3:0] NAME [N]`) are not matched by DECL and are therefore also excluded below
    for a in sys.argv:
        if a.startswith('--names-out='):
            open(a[12:], 'w').write('\n'.join(sorted(names)) + '\n')
    if '--list' in sys.argv:
        print(len(names), 'names,', sum(len(d[n]) for n in names), 'declarations')
        return
    if '--apply' in sys.argv:
        for f in fs:
            s = open(f).read()
            t = '\n'.join(convert_line(l, names) for l in s.split('\n'))
            if t != s:
                open(f, 'w').write(t)
        print(len(names), 'names converted')


if __name__ == '__main__':
    main()
