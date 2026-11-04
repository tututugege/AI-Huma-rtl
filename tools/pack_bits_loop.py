#!/usr/bin/env python3
"""Fixed-point driver for tools/pack_bits.py: pack, lint soc_top, add the names on both sides of every port-connection mismatch to the skip
set, repeat.  The pristine tree is read from BASE (a copy of rtl/ at the commit before packing); rtl/ is rebuilt from it each round.
usage: pack_bits_loop.py BASE_DIR SKIP_FILE"""
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE, SKIPF = sys.argv[1], sys.argv[2]
os.chdir(ROOT)
skip = set(open(SKIPF).read().split()) if os.path.exists(SKIPF) else set()


def sh(c):
    return subprocess.run(c, shell=True, capture_output=True, text=True)


for it in range(80):
    shutil.rmtree('rtl')
    shutil.copytree(BASE, 'rtl')
    sh('python3 tools/pack_bits.py --apply --skip=' + ','.join(sorted(skip)))
    out = sh('bash tools/toplint.sh soc_top 600').stdout
    errs = [l for l in out.split('\n') if l.strip()]
    conn = [l for l in errs if 'Illegal' in l and 'port connection' in l]
    print(f'iter {it}: skipped {len(skip)}, errors {len(errs)} (connection {len(conn)}, other {len(errs) - len(conn)})', flush=True)
    if not errs:
        break
    new = set()
    for l in conn:
        m = re.match(r"%Error: (\S+?):(\d+):(\d+): Illegal \w+ port connection '(\w+)'", l)
        if not m:
            continue
        f, ln, _, port = m.groups()
        new.add(port)
        line = open(f).read().split('\n')[int(ln) - 1]
        for mm in re.finditer(r'\.%s\s*\(\s*([A-Za-z_]\w*)' % re.escape(port), line):
            new.add(mm.group(1))
    if not new - skip:
        print('no progress; remaining errors:')
        print('\n'.join(errs[:20]))
        break
    skip |= new
    open(SKIPF, 'w').write('\n'.join(sorted(skip)))
print('done')
