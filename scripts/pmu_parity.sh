#!/usr/bin/env bash
# PMU tier-1 parity: per-event totals of the RTL SoC testbench (SOC_TB_PMU=1) vs the trace-model (PMU=1), one program.
#   usage: pmu_parity.sh <prog.bin> [soc_tb] [trace-model simulator]
# Only the events of "RTL tier 1" (trace-model include/pmu_events.def) are compared; they must be equal.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
P=$1; SOC=${2:-$ROOT/build/soc/obj/soc_tb}; TM=${3:-$ROOT/../trace-model-pmu/build/simulator}
DEF=${PMU_EVENTS_DEF:-$ROOT/../trace-model-pmu/include/pmu_events.def}
T1="CYCLES INSTRET COMMIT_LOAD COMMIT_STORE COMMIT_BRANCH COMMIT_JUMP CYC_COMMIT_ZERO CYC_COMMIT_FULL BR_MISPRED FLUSH_EXCEPTION FLUSH_OTHER SLOT_FIRE SLOT_KILLED SLOT_FE_EMPTY SLOT_FE_RECOV_MISPRED SLOT_FE_RECOV_FLUSH SLOT_BE CYC_RECOVERING"
TMF=$(mktemp -d)
PMU=1 PMU_OUT=$TMF/p PMU_PCPROF=0 "$TM" "$P" > $TMF/tm.log 2>&1 || true
SOC_TB_PMU=1 "$SOC" "$P" 20000000 > $TMF/rtl.log 2>&1 || true
python3 - "$DEF" "$TMF" "$T1" <<'PY'
import re, sys, csv
deffile, d, t1 = sys.argv[1], sys.argv[2], sys.argv[3].split()
names = [m.group(1) for l in open(deffile) if (m := re.match(r'\s*PMU_EV\((\w+),', l))]
tm = {r['event']: int(r['count']) for r in csv.DictReader(open(f"{d}/p_events.csv"))}
rtl = {}
for l in open(f"{d}/rtl.log", errors="ignore"):
    m = re.match(r'PMU_EV (\d+) (\d+)', l)
    if m: rtl[names[int(m.group(1))]] = int(m.group(2))
bad = 0
for n in t1:
    ok = tm.get(n) == rtl.get(n)
    bad += not ok
    print(f"{'OK  ' if ok else 'DIFF'} {n:18} trace-model {tm.get(n)!s:>10}  rtl {rtl.get(n)!s:>10}")
print("PMU_PARITY", "PASS" if not bad else f"FAIL ({bad} events differ)")
sys.exit(1 if bad else 0)
PY
