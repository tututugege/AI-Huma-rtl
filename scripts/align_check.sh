#!/usr/bin/env bash
# align_check.sh <prog.bin> [soc_tb] [trace-model simulator]   env: BIN (fingerprint bin, cycles, default 256), IV (PMU series interval, default 1024),
#   MAXCYC (RTL cycle limit), DRILL=1 (on a difference, rerun both with FPR_DUMP on the first differing bin and print the raw events of both sides)
# Runs the RTL testbench and the trace-model on one program and reports the first interval / bin where they differ (see align_check.py).
# The model runs in its default configuration (= the RTL configuration; no environment needed since 2026-11-19).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/scripts/env.sh"
P=$1; SOC=${2:-$ROOT/build/soc/obj/soc_tb}; TMS=${3:-$TM}; BIN=${BIN:-256}; IV=${IV:-1024}; MAXCYC=${MAXCYC:-20000000}
DEF=${PMU_EVENTS_DEF:-$(dirname "$(dirname "$TMS")")/include/pmu_events.def}
T=$(mktemp -d)
run() {   # run <dump-window-or-empty>
  d=$1
  env FPR=$BIN ${d:+FPR_DUMP=$d} PMU=1 PMU_OUT=$T/p PMU_INTERVAL=$IV PMU_PCPROF=0 "$TMS" "$P" > "$T/tm.out" 2> "$T/tm.err" || true
  env FPR=$BIN ${d:+FPR_DUMP=$d} SOC_TB_PMU=1 SOC_TB_PMU_IV=$IV "$SOC" "$P" "$MAXCYC" > "$T/rtl.out" 2> "$T/rtl.err" || true
}
run ""
python3 "$ROOT/scripts/align_check.py" "$T/tm.err" "$T/p_series.csv" "$T/rtl.out" "$T/rtl.err" "$DEF" --bin "$BIN"; rc=$?
if [ $rc -ne 0 ] && [ -n "${DRILL:-}" ]; then
  s=$(python3 "$ROOT/scripts/align_check.py" "$T/tm.err" "$T/p_series.csv" "$T/rtl.out" "$T/rtl.err" "$DEF" --bin "$BIN" | grep -m1 "drill down" )
  if [ -n "$s" ]; then
    win=$(echo "$s" | sed -n 's/.*FPR_DUMP=\([0-9]*:[0-9]*\).*/\1/p'); st=$(echo "$s" | sed -n 's/.*stream \([A-Z]*\).*/\1/p')
    run "$win"
    echo "== raw $st events in cycles $win (trace-model | rtl)"
    grep -a "^FPRRAW $st" "$T/tm.err" | sed 's/^FPRRAW //' > "$T/tm.raw"; grep -a "^FPRRAW $st" "$T/rtl.err" | sed 's/^FPRRAW //' > "$T/rtl.raw"
    diff -y -W 200 --suppress-common-lines "$T/tm.raw" "$T/rtl.raw" | head -${DRILL_LINES:-20}
  fi
fi
echo "logs: $T"; exit $rc
