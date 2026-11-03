#!/usr/bin/env python3
"""Byte ranges ignored by the idle-tick fixed-point compare: Verilator scratch temporaries (__Vdfg*, __Vtemp*, __Vdly*) and >=1 MiB arrays in Vsoc_top___024root, from a clang layout dump.
usage: gen_skipmask.py layout.txt out.txt   (out: 'offset size' per line).  The idle-tick skip compares everything else."""
import re, sys
lines = open(sys.argv[1]).read().split('\n')
start = next(i for i, l in enumerate(lines) if re.search(r'\| class Vsoc_top___024root$', l))
mem = []
total = None
for l in lines[start + 1:]:
    m = re.match(r'\s*(\d+)(?::\d+-\d+)?\s*\|\s+(.*)$', l)
    if m:
        if m.group(2).startswith('['):
            break
        mem.append((int(m.group(1)), m.group(2)))
        continue
    m = re.match(r'\s*\|\s+\[sizeof=(\d+)', l)
    if m:
        total = int(m.group(1)); break
out = []
for i, (off, txt) in enumerate(mem):
    name = txt.split()[-1]
    size = (mem[i + 1][0] if i + 1 < len(mem) else total) - off
    if re.match(r'__V(dfg|temp|dly)', name) or size >= (1 << 20):   # scratch temporaries; RAM-style arrays >= 1 MiB (LLC data)
        end = mem[i + 1][0] if i + 1 < len(mem) else total
        out.append((off, end - off))
merged = []
for o, s in out:
    if merged and merged[-1][0] + merged[-1][1] == o: merged[-1][1] += s
    else: merged.append([o, s])
open(sys.argv[2], 'w').write(''.join(f'{o} {s}\n' for o, s in merged))
print(len(merged), 'ranges', sum(s for _, s in merged), 'bytes masked of', total)
