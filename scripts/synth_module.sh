#!/usr/bin/env bash
# Area proxy: yosys (+ yosys-slang front end) generic synthesis of ONE module (flattened below it), both under a watchdog (yosys once exhausted the machine).
#   usage: scripts/synth_module.sh <top-module> [max_rss_mb=3000] [timeout_s=300]    output: build/synth/<top>.{log,stat}
#   yosys' own SV front end cannot read this RTL (unpacked-array localparams ...); the yosys-slang plugin (SLANG=path to slang.so) can.  The result is a RELATIVE
#   number (cells per module before vs. after a change), not a sign-off figure.  Big memories should be black-boxed by the caller.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); TOP=$1; MAXMB=${2:-3000}; TMO=${3:-300}
OUT="$ROOT/build/synth"; mkdir -p "$OUT"; cd "$ROOT"
FILES=$(bash scripts/rtl_files.sh "$ROOT" | tr '\n' ' ')

watch() {   # watch <pid> : kill on RSS or time limit; returns the child's status
  local pid=$1 start; start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    local rss; rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' '); rss=${rss:-0}
    if [ $((rss / 1024)) -gt "$MAXMB" ]; then kill -9 "$pid"; echo "WATCHDOG: killed (rss $((rss / 1024)) MB > $MAXMB MB)"; return 3; fi
    if [ $(( $(date +%s) - start )) -gt "$TMO" ]; then kill -9 "$pid"; echo "WATCHDOG: killed (timeout ${TMO}s)"; return 4; fi
    sleep 1
  done
  wait "$pid"
}

SLANG=${SLANG:-/Users/ruyaoh/personal/yosys-slang/build/slang.so}   # yosys-slang plugin (read_slang): full SystemVerilog front end
# SYNTH_MEM=1: keep memories as $mem cells (stat lists their bits) instead of mapping them to flops: for storage-dominated modules.
# Both options skip the SAT-based `share` pass: on wide muxes (dcache_arr, lsu_dc_req_st: 1.9M SAT variables) it never finishes.
# SYNTH_LTP=1: also print the longest topological path (gate levels, flip-flops excluded) of the flattened result to build/synth/<top>.ltp: a depth proxy, not timing.
# SYNTH_ADDER=<kogge-stone|sklansky|han-carlson>: map the adders ($alu / $lcu) with that yosys choice instead of the default carry chain (depth proxy: a tool maps `+` to a fast adder)
# SYNTH_LIGHT=1: light ABC script (strash; map) instead of yosys' default one.  The default script does not finish (>600 s) on deep combinational
#   logic (fpu_div: 7.4k gates, divider array); the light one takes ~2 s and gives a comparable (less optimised) gate count.
ABC_CMD="abc"; [ -n "${SYNTH_LIGHT:-}" ] && ABC_CMD="abc -script +strash;map"
# SYNTH_DEPTH=1: depth-oriented ABC script (AIG balancing + dc2 before the delay-oriented map): use together with SYNTH_LTP for the depth proxy;
#   the plain light script keeps OR/AND chains of loops unbalanced (a 64-step chain stays 64 levels deep).
[ -n "${SYNTH_DEPTH:-}" ] && ABC_CMD="abc -script +strash;balance;dc2;balance;map"
# SYNTH_ABC="<abc commands>": any ABC script (e.g. "strash;balance;map"); dc2 rewrites adders / comparators into long carry chains, so a script without it shows the structural depth of arithmetic
[ -n "${SYNTH_ABC:-}" ] && ABC_CMD="abc -script +$SYNTH_ABC"
TECHMAP_CMD="techmap"; [ -n "${SYNTH_ADDER:-}" ] && TECHMAP_CMD="techmap -map +/choices/$SYNTH_ADDER.v -map +/techmap.v"
if [ -n "${SYNTH_MEM:-}${SYNTH_LIGHT:-}" ]; then
  MEMMAP="memory_map"; [ -n "${SYNTH_MEM:-}" ] && MEMMAP=""
  MEM_CMD="memory -nomap"
  # SYNTH_NO_MEMPRIO=1: skip opt_mem_priority (O(W^2) on multi-write-port BPU tables)
  [ -n "${SYNTH_NO_MEMPRIO:-}" ] && MEM_CMD="opt_mem
opt_mem_feedback
memory_bmux2rom
memory_dff
opt_clean
memory_share
opt_mem_widen
memory_collect"
  # coarse part of `synth` written out WITHOUT `check`: on very wide vectors (icache_arr: 850k wire bits, 421 cells) `check` never finishes
  SYNTH_CMD="proc
flatten
opt_expr
opt_clean
opt -nodffe -nosdff
fsm
opt
wreduce
peepopt
opt_clean
alumacc
opt
$MEM_CMD
opt_clean
opt -fast -full
$MEMMAP
opt -full
$TECHMAP_CMD
opt -fast
$ABC_CMD
opt -fast"
else SYNTH_CMD="synth -top $TOP -flatten"; fi
cat > "$OUT/$TOP.ys" <<EOF
read_slang --top $TOP --keep-hierarchy ${SLANG_OPTS:-} $FILES
hierarchy -check -top $TOP
$SYNTH_CMD
tee -o $OUT/$TOP.stat stat
${SYNTH_LTP:+tee -o $OUT/$TOP.ltp ltp -noff}
EOF
yosys -m "$SLANG" -q -l "$OUT/$TOP.log" "$OUT/$TOP.ys" > "$OUT/$TOP.out" 2>&1 &
watch $! || { rc=$?; echo "yosys failed (rc=$rc):"; grep -h "ERROR" "$OUT/$TOP.out" "$OUT/$TOP.log" | head -5 | cut -c1-200; exit $rc; }
grep -E "Number of cells|cells$" "$OUT/$TOP.stat" | head -2
