#!/usr/bin/env python3
"""Query a Verilator VCD (soc_tb with SOC_TB_VCD=<from>:<to>:<file>, built with scripts/build_soc_vcd.sh) by signal name.

usage:
  vcd_query.py <file.vcd> --list <regex>                 list the signals whose hierarchical name matches the regex
  vcd_query.py <file.vcd> <regex> [<regex> ...] [--from C] [--to C] [--cyc0 N]
        print, per CPU cycle (rising edge of the clock `clk_cpu`), the value of every matching signal at the end of the cycle,
        one line per cycle and only when something changed.  --cyc0 = the cycle number of the first dumped cycle (the <from> of
        SOC_TB_VCD), so the output carries the same cycle numbers as the testbench logs.
Values are printed in hex (vectors) or 0/1.  Names look like  TOP.soc_top.u_core.u_back.u_rob.<signal>.
"""
import re, sys

def parse_header(f):
    scope, ids, names = [], {}, {}
    for line in f:
        t = line.split()
        if not t: continue
        if t[0] == "$scope": scope.append(t[2])
        elif t[0] == "$upscope": scope.pop()
        elif t[0] == "$var":
            code, name = t[3], t[4]
            full = ".".join(scope + [name])
            names.setdefault(code, []).append(full)
            ids[full] = code
        elif t[0] == "$enddefinitions": break
    return names, ids

def main():
    a = sys.argv[1:]
    if len(a) < 2: print(__doc__); return 1
    path = a[0]; a = a[1:]
    lst = False; fr = 0; to = 1 << 60; cyc0 = 0; pats = []
    i = 0
    while i < len(a):
        if a[i] == "--list": lst = True
        elif a[i] == "--from": fr = int(a[i + 1]); i += 1
        elif a[i] == "--to": to = int(a[i + 1]); i += 1
        elif a[i] == "--cyc0": cyc0 = int(a[i + 1]); i += 1
        else: pats.append(re.compile(a[i]))
        i += 1
    with open(path) as f:
        names, ids = parse_header(f)
        if lst:
            for full in sorted(ids):
                if any(p.search(full) for p in pats): print(full)
            return 0
        want = {}
        for full, code in ids.items():
            if any(p.search(full) for p in pats): want.setdefault(code, []).append(full)
        clk = [c for full, c in ids.items() if full.endswith(".clk_cpu")][:1]
        cur, cyc, last_clk, prev, out = {}, cyc0 - 1, "0", {}, []
        def flush():
            snap = {n: cur.get(c, "x") for c, ns in want.items() for n in ns}
            if cyc >= fr and snap != prev_snap[0]:
                diff = {n: v for n, v in snap.items() if prev_snap[0].get(n) != v}
                print("cyc=%d " % cyc + " ".join("%s=%s" % (n.split(".", 3)[-1] if False else n, v) for n, v in sorted(diff.items())))
            prev_snap[0] = snap
        prev_snap = [{}]
        for line in f:
            if not line: continue
            c0 = line[0]
            if c0 == "#": continue
            if c0 in "01xz" and len(line) > 1:
                code, val = line[1:].strip(), c0
            elif c0 == "b":
                val, code = line[1:].split()
                try: val = "%x" % int(val, 2)
                except ValueError: pass
            else: continue
            if code in want: cur[code] = val
            if clk and code == clk[0]:
                if val == "1" and last_clk == "0":
                    if cyc >= cyc0: flush()
                    cyc += 1
                    if cyc > to: break
                last_clk = val
    return 0

if __name__ == "__main__":
    sys.exit(main())
