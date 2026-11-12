"""Random check of isu_wb_gate against the reference's WbBusy (Isu.cpp): one busy bit per (port, cycle) in a ring of 64,
a pick reserves its completion cycle when it is free, the slot of the current cycle is consumed, a flush clears everything."""
import random, subprocess, sys
random.seed(5)
NP, RING, MAXOFF = int(sys.argv[2]), 64, int(sys.argv[3])
cyc = []
for t in range(30000):
    fl = 1 if random.random() < 0.01 else 0
    c = []
    for p in range(NP):   # no issue in a flush cycle (the issue stage is blocked)
        v = 0 if fl else int(random.random() < 0.6)
        c.append((v, random.choice([1, 1, 1, 2, 3, 3, MAXOFF, MAXOFF - 1, random.randint(1, MAXOFF)])))
    cyc.append((fl, c))
stim = "\n".join(" ".join([str(fl)] + [f"{v} {o}" for v, o in c]) for fl, c in cyc)
out = subprocess.run([sys.argv[1]], input=stim, capture_output=True, text=True).stdout.split()
busy = [[0] * RING for _ in range(NP)]
bad = refused = 0
for t, (fl, c) in enumerate(cyc):
    exp = 0
    for p, (v, o) in enumerate(c):
        s = (t + o) % RING
        ok = 0 if busy[p][s] else 1
        exp |= ok << p
        if v:
            if ok: busy[p][s] = 1
            else: refused += 1
    for p in range(NP): busy[p][t % RING] = 0
    if fl: busy = [[0] * RING for _ in range(NP)]
    if int(out[t]) != exp:
        bad += 1
        if bad < 5: print("MISMATCH cycle", t, "rtl", out[t], "ref", exp)
print(len(cyc), "cycles checked,", refused, "refused picks, mismatches:", bad)
sys.exit(1 if bad or not refused else 0)
