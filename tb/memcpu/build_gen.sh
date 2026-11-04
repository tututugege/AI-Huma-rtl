#!/usr/bin/env bash
# Build the random trace generator of one CPU-phase memory block and write its random traces.
#   usage: bash tb/memcpu/build_gen.sh <mod> [run]          mod = mem_route | ptw_walk | peripheral_axi | axi_cpu_port_adapter
#   needs: REFSIM = the memcpu-patched refsim (docs/analysis/memcpu-record-hook.md), build/lock_<mod>/<mod>_fields.h
#          (run  REFSIM=.. BUILD_ONLY=1 bash scripts/lockstep.sh <mod> x  once).   Traces: traces/<mod>/rand<profile>.trc
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MOD=$1
REF=${REFSIM:?set REFSIM}
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include MemSubSystem/include diff/include function-model/include/api legacy/mmu/include front-end axi-interconnect-kit/include axi-interconnect-kit/axi_interconnect/include axi-interconnect-kit/sim_ddr/include axi-interconnect-kit/mmio/include; do INC+=("-I$REF/$d"); done
B=$ROOT/build/gen_$MOD; mkdir -p "$B"
case $MOD in
  mem_route)      DEF=MOD_ROUTE; SRC=("$REF/MemSubSystem/MemRouteBlock.cpp"); CYC=60000;;
  ptw_walk)       DEF=MOD_PTW;   SRC=(); CYC=60000;;
  peripheral_axi) DEF=MOD_PERI;  SRC=("$REF/MemSubSystem/PeripheralAxi.cpp"); CYC=60000;;
  axi_cpu_port_adapter) DEF=MOD_AXI; SRC=(); CYC=8000;;
  *) echo "unknown module $MOD"; exit 2;;
esac
if [ "$MOD" = axi_cpu_port_adapter ]; then
  python3 - "$REF/rv_simu_mmu_v2.cpp" "$B/axi_cpu_funcs.inc" <<'PY'
import sys,re
s=open(sys.argv[1]).read()
def cut(a,b):
    i=s.index(a); j=s.index(b,i); return s[i:j]
out=cut("bool is_dcache_read_master","template <typename InterconnectT>\nvoid clear_axi_master_inputs") if False else ""
out+=cut("bool is_dcache_read_master(int master)","template <typename InterconnectT>")
out+=cut("struct AxiCpuBoundaryState","void axi_subsystem_comb_outputs(SimCpu &cpu)")
out+=cut("void ttg_mc_sample_axi(SimCpu &cpu","void run_extra_axi_subsystem_ticks")
open(sys.argv[2],'w').write(out)
PY
fi
FH=$ROOT/build/lock_$MOD
[ -f "$FH/${MOD}_rec.cpp" ] || { echo "run the lockstep build of $MOD first (needs $FH/${MOD}_rec.cpp)"; exit 2; }
clang++ -std=c++2a -O1 -w -DNDEBUG -D$DEF "${INC[@]}" -I"$ROOT/harness/include" -I"$FH" -I"$B" \
  "$ROOT/tb/memcpu/gen_rand.cpp" "$FH/${MOD}_rec.cpp" ${SRC[@]+"${SRC[@]}"} -o "$B/gen_rand" -Wl,-undefined,dynamic_lookup
if [ "${2:-}" = run ]; then
  mkdir -p "$ROOT/traces/$MOD"
  for p in 0 1 2 3 4 5; do "$B/gen_rand" "$ROOT/traces/$MOD/rand$p.trc" $((p + 11)) $CYC $p; done
fi
