#!/usr/bin/env python3
"""First divergence between trace-model and the RTL core: both print one line per committed instruction (cycle, pc).
usage: first_diff.py <tm.log> <rtl.log> [context=5]
  tm.log  : stderr of  TB_TRACE_COMMIT=1 trace-model/build/simulator <prog.bin>      ("[COMMIT] cyc=.. pc=0x..")
  rtl.log : stderr of  SOC_TB_COMMIT=1 build/soc/obj/soc_tb <prog.bin> <cycles>      ("[cyc N] commit[i] type=.. pc=..")
The two cycle counters differ by a constant (printed); the instruction stream (pc order) must be identical, and so must the cycle
of every commit once the offset is removed.  Exit 0: identical over the common length; 1: first difference printed."""
import re, sys
tm_re = re.compile(r'\[COMMIT\] cyc=(-?\d+) pc=0x([0-9a-f]+)')
rtl_re = re.compile(r'\[cyc (\d+)\] commit\[\d+\] type=\S+ pc=([0-9a-f]+)')
def load(path, rx):
    out = []
    for l in open(path, errors='replace'):
        m = rx.search(l)
        if m: out.append((int(m[1]), int(m[2], 16)))
    return out
tm, rtl = load(sys.argv[1], tm_re), load(sys.argv[2], rtl_re)
ctx = int(sys.argv[3]) if len(sys.argv) > 3 else 5
if not tm or not rtl: sys.exit(f'empty trace: tm={len(tm)} rtl={len(rtl)}')
# the first instruction of the boot window is not reported by trace-model: align on the first commit of tm
skip = next((k for k, c in enumerate(rtl) if c[1] == tm[0][1]), None)
if skip is None: sys.exit('the first trace-model pc never appears in the RTL trace')
rtl = rtl[skip:]
off = rtl[0][0] - tm[0][0]
n = min(len(tm), len(rtl))
print(f'tm {len(tm)} commits, rtl {len(rtl)} commits (skipped {skip} leading rtl commits), cycle offset rtl-tm = {off}')
for i in range(n):
    if tm[i][1] != rtl[i][1] or rtl[i][0] - tm[i][0] != off:
        kind = 'pc differs (instruction stream)' if tm[i][1] != rtl[i][1] else 'cycle differs (timing)'
        print(f'FIRST DIFFERENCE at commit #{i}: {kind}')
        for j in range(max(0, i - ctx), min(n, i + ctx + 1)):
            mark = '>>' if j == i else '  '
            print(f'{mark} #{j}: tm cyc={tm[j][0]:>8} pc={tm[j][1]:08x}   rtl cyc={rtl[j][0]:>8} (tm+off={tm[j][0]+off:>8}) pc={rtl[j][1]:08x}')
        sys.exit(1)
print(f'identical over {n} commits' + ('' if len(tm) == len(rtl) else f'  (lengths differ: only the first {n} compared)'))
