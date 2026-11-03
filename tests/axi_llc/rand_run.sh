#!/usr/bin/env bash
# Random-traffic lock-step: reference interconnect + LLC + sim_ddr driven by tests/axi_llc/rand_axi.cpp, RTL checked every tick.
#   usage: rand_run.sh <module: axi_subsys|axi_interconnect|axi_llc> <seed> <cpu_cycles>
#   env: REFSIM (tap refsim tree, must be built), TTG_LLC_KB/TTG_LLC_WAYS (reference geometry) + SETS/WAYS (RTL macros, must match),
#        BUILD_ONLY=1 (only build), RAND_* (see rand_axi.cpp), OUTDIR
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MOD=$1; SEED=${2:-1}; CYC=${3:-20000}
REF=${REFSIM:?set REFSIM}
SETS=${SETS:-4096}; WAYS=${WAYS:-16}
OUT=${OUTDIR:-$ROOT/build/rand_${MOD}_${SETS}x${WAYS}}; mkdir -p "$OUT"
if [ -z "${NOBUILD:-}" ]; then
  # driver: copy of AxiLlcTableRuntime from MemSubsystem.cpp + the reference objects
  python3 - "$REF/MemSubSystem/MemSubsystem.cpp" "$OUT/axi_llc_tables_runtime.inc" <<'PY'
import sys
t = open(sys.argv[1]).read()
i = t.index('struct AxiLlcTableRuntime {')
j = t.index('} // namespace', i)
open(sys.argv[2], 'w').write(t[i:j])
PY
  INC=(); for d in include libs/include back-end/include MemSubSystem/include front-end axi-interconnect-kit/include \
      axi-interconnect-kit/axi_interconnect/include axi-interconnect-kit/sim_ddr/include axi-interconnect-kit/mmio/include; do INC+=("-I$REF/$d"); done
  clang++ -std=c++2a -O2 -w -DNDEBUG "${INC[@]}" -I"$OUT" "$ROOT/tests/axi_llc/rand_axi.cpp" \
    "$REF/build/axi-interconnect-kit/axi_interconnect/AXI_Interconnect.o" "$REF/build/axi-interconnect-kit/axi_interconnect/AXI_LLC.o" \
    "$REF/build/axi-interconnect-kit/sim_ddr/SimDDR.o" -o "$OUT/rand_axi" 2> "$OUT/driver.log" || { echo DRIVER BUILD FAILED; head -20 "$OUT/driver.log"; exit 1; }
  VFLAGS="${VFLAGS_EXTRA:-} -Wno-fatal --assert -fno-dfg -DAXI_LLC_SETS=$SETS -DAXI_LLC_WAYS=$WAYS" OUTDIR="$OUT" BUILD_ONLY=1 JOBS=${JOBS:-4} \
    bash "$ROOT/scripts/lockstep_ticks_axi.sh" "$MOD" dummy > "$OUT/plugin_build.log" 2>&1 || { echo PLUGIN BUILD FAILED; tail -5 "$OUT/plugin_build.log"; exit 1; }
fi
[ -z "${BUILD_ONLY:-}" ] || { echo "built $OUT"; exit 0; }
TTG_REC_END="$OUT/lock_${MOD}.dylib" "$OUT/rand_axi" "$SEED" "$CYC" 2>&1 | grep -aE "rand_axi:|LOCKSTEP|MISMATCH|inputs this cycle|^    " | head -${HEADN:-40}
