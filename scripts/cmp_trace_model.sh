#!/usr/bin/env bash
# Whole-program comparison RTL closed loop (tb/soc/soc_tb) vs the trace-model simulator: cycle count and committed-instruction count.
#   usage: cmp_trace_model.sh [list-file=scripts/progs_smoke.txt]     env TM (trace-model simulator, default AI-Huma/trace-model/build/simulator), JOBS (4)
# The instruction count follows the reference (Ren.cpp commit_num): a commit slot is not counted in a cycle where rob_bcast.interrupt is set.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TM=${TM:-/Users/ruyaoh/personal/AI-Huma/trace-model/build/simulator}
LIST=${1:-$ROOT/scripts/progs_smoke.txt}
export ROOT TM
one() {
  p=$1; n=$(basename "$p" .bin)
  a=$(cd "$(dirname "$(dirname "$TM")")" && perl -e 'alarm 600; exec @ARGV' "$TM" "$p" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -aE "^cycle +num|^instruction num" | awk '{print $NF}' | tr '\n' ' ')
  ic=$(echo $a | awk '{print $1}'); cy=$(echo $a | awk '{print $2}')
  b=$(perl -e 'alarm 900; exec @ARGV' "$ROOT/build/soc/obj/soc_tb" "$p" 2000000 2>&1 | grep -a "sim-time" | sed 's/.*= \([0-9]*\), committed= \([0-9]*\).*/\1 \2/')
  rc=$(echo $b | awk '{print $1}'); rn=$(echo $b | awk '{print $2}')
  st=PASS; [ -n "$cy" ] && [ "$cy" = "$rc" ] || st=CYCLE-DIFF; [ "$ic" = "$rn" ] || st="$st/INSTR-DIFF"
  echo "$st $n trace-model: cyc=$cy inst=$ic | rtl: cyc=$rc commits=$rn"
}
export -f one
OUT=$ROOT/build/cmp_trace_model.txt
xargs -P "${JOBS:-4}" -I{} bash -c 'one {}' < "$LIST" | tee "$OUT"
echo "== PASS: $(grep -c '^PASS ' "$OUT")  DIFF: $(grep -vc '^PASS ' "$OUT")"
