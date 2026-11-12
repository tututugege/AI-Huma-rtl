"""Random check of isu_fp_gate against the reference's FpStats::try_reserve (ring of 64 busy counters, P ports)."""
import random, subprocess, sys
random.seed(3)
P, NC, RING = 2, 5, 64
cyc = []
for t in range(20000):
    fl = 1 if random.random() < 0.01 else 0
    c = []
    for k in range(NC):
        c.append((int(random.random() < 0.5), int(random.random() < 0.8), random.choice([2, 2, 3, 3, 11, 19, 23])))
    cyc.append((fl, c))
stim = "\n".join(" ".join([str(fl)] + [f"{v} {f} {l}" for v, f, l in c]) for fl, c in cyc)
out = subprocess.run([sys.argv[1]], input=stim, capture_output=True, text=True).stdout.split()
busy = [0] * RING
bad = 0
for t, (fl, c) in enumerate(cyc):
    exp = 0
    for k, (v, f, l) in enumerate(c):
        ok = 1
        if v and f:
            s = (t + l) % RING
            if busy[s] >= P: ok = 0
            else: busy[s] += 1
        exp |= ok << k
    busy[t % RING] = 0          # the slot of this cycle is consumed
    if fl: busy = [0] * RING    # global flush clears every reservation
    if int(out[t]) != exp:
        bad += 1
        if bad < 5: print("MISMATCH cycle", t, "rtl", out[t], "ref", exp)
print(len(cyc), "cycles checked, mismatches:", bad)
