#!/usr/bin/env bash
# drill_pmu.sh <soc_tb> <trace-model simulator> <vcd soc_tb> <image> <max-cycles> <out-dir> [iv=25]
# Finds the first PMU interval (iv cycles) in which the RTL and the trace-model differ, from reset, in ONE model run and ONE RTL run, and then captures the
# waveform of that window with the VCD build (soc_tb built by scripts/build_soc_vcd.sh) in ONE more RTL run: two RTL runs in total, no manual zooming.
# prints the first differing interval (tier-1 events) and writes <out-dir>/w.vcd (query it with scripts/vcd_query.py --cyc0 <printed from>).
# env TM_ENV (model environment, default empty: the model default = the RTL configuration), PAD (cycles of waveform before / after the interval, default 40).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/scripts/env.sh"
SOC=$1; TMS=$2; VSOC=$3; IMG=$4; MAXC=$5; OUT=$6; IV=${7:-25}; PAD=${PAD:-40}; mkdir -p "$OUT"
DEF=${PMU_EVENTS_DEF:-$(dirname "$(dirname "$TMS")")/include/pmu_events.def}
env ${TM_ENV:-} SIM_MAX_CYCLES=$MAXC PMU=1 PMU_OUT="$OUT/p" PMU_INTERVAL=$IV PMU_PCPROF=0 "$TMS" "$IMG" > "$OUT/tm.out" 2> "$OUT/tm.err" &
TP=$!
SOC_TB_SEMIHOST=1 SOC_TB_PMU=1 SOC_TB_PMU_IV=$IV "$SOC" "$IMG" "$MAXC" > "$OUT/rtl.out" 2> "$OUT/rtl.err"; wait $TP
al=$(python3 "$ROOT/scripts/align_check.py" "$OUT/tm.err" "$OUT/p_series.csv" "$OUT/rtl.out" "$OUT/rtl.err" "$DEF" | grep -a -m1 "first difference in interval")
echo "$al"; [ -n "$al" ] || { echo "no PMU difference up to $MAXC"; exit 0; }
hi=$(echo "$al" | sed -n 's/.*cycles \([0-9]*\)\.\.\([0-9]*\).*/\2/p'); lo=$(echo "$al" | sed -n 's/.*cycles \([0-9]*\)\.\.\([0-9]*\).*/\1/p')
from=$((lo - PAD)); to=$((hi + PAD)); echo "waveform window $from:$to"
SOC_TB_SEMIHOST=1 SOC_TB_VCD=$from:$to:$OUT/w.vcd "$VSOC" "$IMG" $((to + 10)) > "$OUT/v.out" 2> "$OUT/v.err"
echo "vcd: $OUT/w.vcd   (python3 scripts/vcd_query.py $OUT/w.vcd <regex> --cyc0 $from)"
