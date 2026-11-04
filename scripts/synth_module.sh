#!/usr/bin/env bash
# Area proxy: sv2v + yosys generic synthesis of ONE module (flattened below it), both under a watchdog (yosys once exhausted the machine).
#   usage: scripts/synth_module.sh <top-module> [max_rss_mb=3000] [timeout_s=300]    output: build/synth/<top>.{v,log,stat}
#   The yosys SV front end cannot read this RTL (unpacked-array localparams ...), so sv2v converts it first.  The result is a RELATIVE
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

sv2v --top "$TOP" $FILES > "$OUT/$TOP.v" 2> "$OUT/$TOP.sv2v.err" &
watch $! || { rc=$?; echo "sv2v failed (rc=$rc):"; head -5 "$OUT/$TOP.sv2v.err" | cut -c1-200; exit $rc; }
cat > "$OUT/$TOP.ys" <<EOF
read_verilog -sv $OUT/$TOP.v
hierarchy -check -top $TOP
synth -top $TOP -flatten
tee -o $OUT/$TOP.stat stat
EOF
yosys -q -l "$OUT/$TOP.log" "$OUT/$TOP.ys" > "$OUT/$TOP.out" 2>&1 &
watch $! || { rc=$?; echo "yosys failed (rc=$rc):"; grep -h "ERROR" "$OUT/$TOP.out" "$OUT/$TOP.log" | head -5 | cut -c1-200; exit $rc; }
grep -E "Number of cells|cells$" "$OUT/$TOP.stat" | head -2
