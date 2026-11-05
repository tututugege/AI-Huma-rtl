#!/usr/bin/env bash
# synth_cfg.sh <tag> <cfg_pkg.sv> <modules...>: synthesize modules (synth_module.sh, the 09-synthesis-report settings) under a given
# configuration package, 3 in parallel; stats go to build/synth_<tag>/<module>.stat ("N cells" line).
# The package is installed into rtl/common for the run and the original is restored afterwards.
set -uo pipefail
cd "$(dirname "$0")/.."
TAG=$1; CFG=$2; shift 2
SAVE=$(mktemp); cp rtl/common/ttg_cfg_pkg.sv "$SAVE"; trap 'cp "$SAVE" rtl/common/ttg_cfg_pkg.sv; rm -f "$SAVE"' EXIT
cp "$CFG" rtl/common/ttg_cfg_pkg.sv
export SLANG_OPTS="--unroll-limit 100000 -Wno-error=index-oob" SYNTH_LIGHT=1 SYNTH_MEM=1
mkdir -p "build/synth_$TAG"
printf "%s\n" "$@" | xargs -P 3 -I{} bash -c "bash scripts/synth_module.sh {} 12000 300 > build/synth_$TAG/{}.out 2>&1; cp build/synth/{}.stat build/synth_$TAG/ 2>/dev/null"
for m in "$@"; do printf "%-24s %s\n" "$m" "$(grep -m1 ' cells$' "build/synth_$TAG/$m.stat" 2>/dev/null | awk '{print $1}')"; done
