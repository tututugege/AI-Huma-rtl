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
print(f'tm {len(tm)} commits, rtl {len(rtl)} commits (skipped {skip} leading rtl commits), cycle offset rtl-tm = {off}')
# trace-model does not list an instruction that traps (ecall, illegal, page fault) but the RTL stream does: an RTL commit whose successor
# is the next trace-model pc is skipped (counted).  Known limitation: around asynchronous interrupts trace-model's log also lacks a few
# commits (the whole-program cycle and instruction counts still agree), so programs that take interrupts can report a false difference.
i = j = trapped = 0
def show(i, j, kind):
    print(f'FIRST DIFFERENCE at tm commit #{i} / rtl commit #{j}: {kind}')
    for k in range(-ctx, ctx + 1):
        a, b = i + k, j + k
        mark = '>>' if k == 0 else '  '
        ta = f'tm cyc={tm[a][0]:>8} pc={tm[a][1]:08x}' if 0 <= a < len(tm) else 'tm  -'
        rb = f'rtl cyc={rtl[b][0]:>8} (tm+off={tm[a][0]+off if 0 <= a < len(tm) else 0:>8}) pc={rtl[b][1]:08x}' if 0 <= b < len(rtl) else 'rtl -'
        print(f'{mark} {ta}   {rb}')
while i < len(tm) and j < len(rtl):
    if tm[i][1] == rtl[j][1]:
        if rtl[j][0] - tm[i][0] != off:
            show(i, j, 'cycle differs (timing)'); sys.exit(1)
        i += 1; j += 1
    elif j + 1 < len(rtl) and rtl[j + 1][1] == tm[i][1]:
        trapped += 1; j += 1
    else:
        show(i, j, 'pc differs (instruction stream)'); sys.exit(1)
extra = '' if (i == len(tm) and j == len(rtl)) else f'  (one trace ended earlier: tm {i}/{len(tm)}, rtl {j}/{len(rtl)})'
print(f'identical over {i} trace-model commits ({trapped} RTL-only trapping instructions skipped){extra}')
