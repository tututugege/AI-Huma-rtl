#!/usr/bin/env bash
# Build the closed-loop SoC testbench: Verilated soc_top + the reference's SimDDR / PhysMemory.
#   usage: tb/soc/build.sh        env: REFSRC (reference source tree), JOBS
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/scripts/env.sh"
REF=${REFSRC:-$ROOT/tb/soc/platform}   # frozen platform models (SimDDR, PhysMemory, PeripheralModel); no reference simulator needed
OUT=${SOC_OUT:-$ROOT/build/soc}; mkdir -p "$OUT"   # SOC_OUT: build a variant next to the default one
VOPT=${SOC_VOPT:-}   # extra verilator options, e.g. -O3
COPT=${SOC_COPT:--O2}   # C++ optimisation flags
FMOPT=(); FMLD=""
if [ -n "${SOC_FM:-}" ]; then   # per-commit check against the function model (librefcpu, built in ../function-model)
  FMOPT=(-DSOC_TB_FM -I"$AI_HUMA_ROOT/function-model/include/api"); FMLD="$AI_HUMA_ROOT/function-model/librefcpu.a $AI_HUMA_ROOT/function-model/lib/softfloat/softfloat.a -lz"
fi
# DRAMsim3 behind SimDDR (EXP-006), on by default; DS3=0 builds the fixed-latency SimDDR.  DRAMsim3 is the pinned submodule of
# the trace-model repository (TM_DIR, default $AI_HUMA_ROOT/trace-model); its static library is built there by `gmake dramsim3`.
DS3FLAGS="-DSIM_DDR_DATA"; DS3LD=""   # SIM_DDR_DATA: SimDDR serves read data from / writes data to PhysMemory
if [ "${DS3:-1}" != 0 ]; then
  TM_DIR=${TM_DIR:-$AI_HUMA_ROOT/trace-model}
  DS3_DIR=$(cd "${DS3_DIR:-$TM_DIR/third_party/DRAMsim3}" 2>/dev/null && pwd) || { echo "DRAMsim3 not found (run 'git submodule update --init third_party/DRAMsim3' in $TM_DIR, or DS3=0)"; exit 1; }
  DS3_LIB=${DS3_LIB:-$TM_DIR/build_dramsim3/libdramsim3.a}
  [ -f "$DS3_LIB" ] || { (cd "$TM_DIR" && { command -v gmake >/dev/null && gmake dramsim3 || make dramsim3; }) || exit 1; }
  DS3FLAGS="$DS3FLAGS -DSIM_DDR_DS3 -I$DS3_DIR/src -DDS3_CFG_PATH=$DS3_DIR/configs/DDR4_8Gb_x16_3200.ini"
  DS3LD="$DS3_LIB"
fi
INC=""
for d in include libs/include back-end back-end/include axi-interconnect-kit/include axi-interconnect-kit/sim_ddr/include \
         axi-interconnect-kit/axi_interconnect/include axi-interconnect-kit/mmio/include MemSubSystem/include diff/include front-end back-end/Exu/include back-end/Lsu/include back-end/tools/include function-model/include/api legacy/mmu/include; do INC="$INC -I$REF/$d"; done
FILES=(); while IFS= read -r f; do FILES+=("$ROOT/$f"); done < <(bash "$ROOT/scripts/rtl_files.sh" "$ROOT")
python3 "$ROOT/tools/gen_soc_probe.py" >/dev/null
cd "$OUT"
# reference platform models (not RTL)
for s in axi-interconnect-kit/sim_ddr/SimDDR.cpp back-end/PhysMemory.cpp; do
  clang++ -std=c++2a -O2 -w $INC $DS3FLAGS -c "$REF/$s" -o "$(basename "$s" .cpp).o" &
done
wait
verilator --cc --exe --build -j "${JOBS:-6}" -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT ${DEBUG:+--public-flat-rw} $VOPT --x-assign 0 --x-initial 0 \
  --top-module soc_top -Mdir obj -CFLAGS "$COPT $DS3FLAGS ${FMOPT[*]:-} ${DEBUG:+-DSOC_TB_DEBUG} -std=c++2a -w $INC -I$ROOT/harness/include -I$ROOT/tb/soc" \
  -LDFLAGS "$OUT/SimDDR.o $OUT/PhysMemory.o $FMLD $DS3LD" \
  "$ROOT/tb/soc/soc_public.vlt" "$ROOT/tb/soc/pmu_public.vlt" "$ROOT/tb/soc/soc_tb.cpp" "${FILES[@]}" -o soc_tb > build.log 2>&1 || { grep -E "error:|%Error" build.log | grep -v "Command Failed" | head -12 | cut -c1-200; echo "BUILD FAILED, see $OUT/build.log"; exit 1; }
# idle-tick skip: byte ranges of Verilator scratch temporaries (ignored by the fixed-point compare)
VI=$(verilator --getenv VERILATOR_ROOT)/include
echo '#include "Vsoc_top___024root.h"' > obj/lay.cpp
clang++ -std=c++2a -w -Iobj -I"$VI" -I"$VI/vltstd" -Xclang -fdump-record-layouts -fsyntax-only obj/lay.cpp > obj/layout.txt 2>&1 || true
python3 "$ROOT/tools/gen_skipmask.py" obj/layout.txt "$OUT/skipmask.txt"
ls -la "$OUT/obj/soc_tb" | awk '{print "built", $9}'
