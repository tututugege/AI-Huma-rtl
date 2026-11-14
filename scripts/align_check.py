#!/usr/bin/env python3
"""Find the first point where the RTL and the trace-model disagree.

usage: align_check.py <model_stderr> <model_series.csv> <rtl_stdout> <rtl_stderr> <pmu_events.def> [--bin N]

Two independent kinds of evidence, both written by the simulators themselves (scripts/align_check.sh runs them):
  * PMU time series: the tier-1 event counts of every PMU_INTERVAL cycles (model: PMU=1 CSV, RTL: SOC_TB_PMU_IV lines).  The first interval in
    which any event count differs says which subsystem diverges first and within how many cycles.
  * fingerprints (trace-model front-end/BPU/fpr.h, same code in the RTL testbench): per bin of FPR cycles, the number of PTAB writes (PT) and of
    predictor-table updates (UP) and a commutative hash of them.  The first bin whose (count, hash) differs is the first divergence of that stream.
Exit status 0 = no difference in the compared range, 1 = a difference was found.  The last (incomplete) interval / bin of each run is ignored.
"""
import csv, re, sys

def names_from_def(path):
    return [m.group(1) for l in open(path) if (m := re.match(r'\s*PMU_EV\((\w+),', l))]

def read_fpr(path):
    d = {"PT": {}, "UP": {}}
    for l in open(path, errors="ignore"):
        m = re.match(r'FPR (PT|UP) bin=(\d+) n=(\d+) h=([0-9a-f]+)', l)
        if m: d[m.group(1)][int(m.group(2))] = (int(m.group(3)), m.group(4))
    return d

def main():
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    binw = int(sys.argv[sys.argv.index("--bin") + 1]) if "--bin" in sys.argv else 256
    if "--bin" in sys.argv: a.remove(sys.argv[sys.argv.index("--bin") + 1])
    tm_err, tm_csv, rtl_out, rtl_err, deffile = a[:5]
    names = names_from_def(deffile)
    bad = 0
    # ---- PMU series
    tm = list(csv.DictReader(open(tm_csv))) if tm_csv != "-" else []
    rtl = []
    for l in open(rtl_out, errors="ignore"):
        if l.startswith("PMU_IV "):
            f = l.split(); rtl.append((int(f[1]), [int(x) for x in f[2:]]))
    t1 = ["CYCLES", "INSTRET", "COMMIT_LOAD", "COMMIT_STORE", "COMMIT_BRANCH", "COMMIT_JUMP", "CYC_COMMIT_ZERO", "CYC_COMMIT_FULL", "BR_MISPRED",
          "FLUSH_EXCEPTION", "FLUSH_OTHER", "SLOT_FIRE", "SLOT_KILLED", "SLOT_FE_EMPTY", "SLOT_FE_RECOV_MISPRED", "SLOT_FE_RECOV_FLUSH", "SLOT_BE", "CYC_RECOVERING"]
    n = min(len(tm), len(rtl)) - 1   # the last interval may be incomplete
    first = None
    for i in range(max(n, 0)):
        diffs = []
        for e in t1:
            if e not in names or e not in tm[i]: continue
            idx = names.index(e)
            if idx >= len(rtl[i][1]): continue
            if int(tm[i][e]) != rtl[i][1][idx]: diffs.append((e, int(tm[i][e]), rtl[i][1][idx]))
        if diffs: first = (i, diffs); break
    if tm and rtl:
        if first:
            i, diffs = first
            print("PMU series: first difference in interval %d (cycles %s..%s):" % (i, rtl[i - 1][0] if i else 0, rtl[i][0]))
            for e, x, y in diffs: print("   %-22s trace-model %8d   rtl %8d" % (e, x, y))
            bad = 1
        else:
            print("PMU series: %d intervals compared, tier-1 events equal" % max(n, 0))
    else:
        print("PMU series: not compared (no series on one side)")
    # ---- fingerprints
    fm, fr = read_fpr(tm_err), read_fpr(rtl_err)
    for s in ("PT", "UP"):
        a_, b_ = fm[s], fr[s]
        if not a_ and not b_:
            print("%s fingerprint: not compared (no FPR lines)" % s); continue
        lim = min(max(a_, default=0), max(b_, default=0))   # compare the bins both runs completed
        diff = None
        for k in sorted(set(a_) | set(b_)):
            if k >= lim: break
            if a_.get(k) != b_.get(k): diff = k; break
        if diff is None:
            print("%s fingerprint: bins 0..%d equal (%d / %d non-empty bins)" % (s, lim - 1, len(a_), len(b_)))
        else:
            lo, hi = diff * binw, (diff + 1) * binw - 1
            print("%s fingerprint: first difference in bin %d (cycles %d..%d): trace-model %s  rtl %s" % (s, diff, lo, hi, a_.get(diff), b_.get(diff)))
            print("   drill down: FPR=%d FPR_DUMP=%d:%d on both, FPRRAW lines of stream %s" % (binw, lo, hi, s))
            bad = 1
    return bad

sys.exit(main())
