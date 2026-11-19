"""Random check of isu_wb_gate against the reference's WbBusy (Isu.cpp): one busy bit per (port, cycle) in a ring of 64, a pick reserves
the completion cycle of its class (offset = isu_pkg wb_cls_off) when it is free, the slot of the current cycle is consumed, a flush clears
everything. Also checks the per-class free bits (cls_free, read by the select with WB_PRESEL): free = the class's completion cycle on the
port is not reserved, 1 for a class the port does not serve."""
import random, subprocess, sys
random.seed(5)
exe, NP = sys.argv[1], int(sys.argv[2])
RING = 64
tab = subprocess.run([exe], input="", capture_output=True, text=True).stdout.split()
assert tab[0] == "TAB"
NC = int(tab[1]); OFF = [int(x) for x in tab[2:2 + NC]]; SERVE = [int(x) for x in tab[2 + NC:2 + NC + NP]]
cyc = []
for t in range(30000):
    fl = 1 if random.random() < 0.01 else 0
    c = []
    for p in range(NP):   # no issue in a flush cycle (the issue stage is blocked); a pick has a class its port serves
        cl = random.choice([k for k in range(NC) if SERVE[p] >> k & 1] + [0, 0])
        v = 0 if fl else int(random.random() < 0.6)
        c.append((v, cl))
    cyc.append((fl, c))
stim = "\n".join(" ".join([str(fl)] + [f"{v} {k}" for v, k in c]) for fl, c in cyc)
lines = subprocess.run([exe], input=stim, capture_output=True, text=True).stdout.strip().split("\n")[1:]
busy = [[0] * RING for _ in range(NP)]
bad = refused = 0
for t, (fl, c) in enumerate(cyc):
    exp_ok = 0; exp_free = []
    for p in range(NP):
        fr = 0
        for k in range(NC):
            free = 1 if not (SERVE[p] >> k & 1) else (0 if busy[p][(t + OFF[k]) % RING] else 1)
            fr |= free << k
        exp_free.append(fr)
    for p, (v, k) in enumerate(c):
        ok = exp_free[p] >> k & 1
        exp_ok |= ok << p
        if v:
            if ok: busy[p][(t + OFF[k]) % RING] = 1
            else: refused += 1
    for p in range(NP): busy[p][t % RING] = 0
    if fl: busy = [[0] * RING for _ in range(NP)]
    got = [int(x) for x in lines[t].split()]
    if got != [exp_ok] + exp_free:
        bad += 1
        if bad < 5: print("MISMATCH cycle", t, "rtl", got, "ref", [exp_ok] + exp_free)
print(len(cyc), "cycles checked,", refused, "refused picks, mismatches:", bad)
sys.exit(1 if bad or not refused else 0)
