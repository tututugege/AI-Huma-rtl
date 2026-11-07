#!/usr/bin/env bash
# synth_depth.sh <tag> <module...>: area (cells) and depth proxy (longest topological path in gate levels, flip-flops excluded) of each module,
#   with the 09-synthesis-report settings plus SYNTH_DEPTH (balancing ABC script) and SYNTH_LTP.  Output: build/synth_<tag>/<module>.{stat,ltp}.
#   The depth is a logic-level count of the flattened gate netlist (generic gates, no library, no wire load): relative proxy, not timing.
set -uo pipefail
cd "$(dirname "$0")/.."
TAG=$1; shift
export SLANG_OPTS="--unroll-limit 100000 -Wno-error=index-oob" SYNTH_LIGHT=1 SYNTH_MEM=1 SYNTH_LTP=1 SYNTH_DEPTH=${SYNTH_DEPTH:-1}
mkdir -p "build/synth_$TAG"
printf "%s\n" "$@" | xargs -P "${JOBS:-3}" -I{} bash -c "bash scripts/synth_module.sh {} 12000 ${TMO:-1500} > build/synth_$TAG/{}.out 2>&1; cp build/synth/{}.stat build/synth/{}.ltp build/synth_$TAG/ 2>/dev/null"
for m in "$@"; do printf "%-18s cells=%-9s depth=%s\n" "$m" "$(grep -m1 ' cells$' "build/synth_$TAG/$m.stat" 2>/dev/null | awk '{print $1}')" "$(grep -m1 'Longest topological path' "build/synth_$TAG/$m.ltp" 2>/dev/null | sed 's/.*length=\([0-9]*\).*/\1/')"; done
