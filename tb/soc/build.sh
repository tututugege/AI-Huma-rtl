#!/usr/bin/env bash
# Build the real full-SoC Verilator testbench for chip_top (tb/soc/soc_tb).
# Supports DDR_DATA_W=64 (default, real 8-beat AXI4 DDR), 128 (4-beat), or 256 (2-beat).
# Reuses SimDDR + PhysMemory + SoftFloat DPI from tb/core/platform.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/scripts/env.sh"
REF=${REFSRC:-$ROOT/tb/core/platform}
DDR_DATA_W=${DDR_DATA_W:-64}
DDR_BEAT_BYTES=$((DDR_DATA_W / 8))
OUT=${SOC_OUT:-${CHIP_OUT:-$ROOT/build/soc}}; mkdir -p "$OUT"
VOPT=${SOC_VOPT:-${CHIP_VOPT:-}}
COPT=${SOC_COPT:-${CHIP_COPT:--O2}}

FMDIR=$(bash "$ROOT/scripts/fm_lib.sh")
DS3FLAGS="-DSIM_DDR_DATA -DCONFIG_AXI_KIT_SIM_DDR_BEAT_BYTES=$DDR_BEAT_BYTES -DAXI_KIT_SIM_DDR_BEAT_BYTES=$DDR_BEAT_BYTES -DCHIP_DDR_DATA_W=$DDR_DATA_W"; DS3LD=""
if [ "${DS3:-1}" != 0 ]; then
  TM_DIR=${TM_DIR:-$AI_HUMA_ROOT/trace-model}
  DS3_DIR=$(cd "${DS3_DIR:-$TM_DIR/third_party/DRAMsim3}" 2>/dev/null && pwd) || { echo "DRAMsim3 not found"; exit 1; }
  DS3_LIB=${DS3_LIB:-$TM_DIR/build_dramsim3/libdramsim3.a}
  [ -f "$DS3_LIB" ] || { (cd "$TM_DIR" && { command -v gmake >/dev/null && gmake dramsim3 || make dramsim3; }) || exit 1; }
  DS3FLAGS="$DS3FLAGS -DSIM_DDR_DS3 -I$DS3_DIR/src -DDS3_CFG_PATH=$DS3_DIR/configs/DDR4_8Gb_x8_3200.ini"
  DS3LD="$DS3_LIB"
fi

FPDPI=("$ROOT/tb/fp_dpi/fp_dpi.cpp")
FPINC="-DSOC_FP -I$FMDIR/lib/softfloat/include"
FPLD="$FMDIR/lib/softfloat/softfloat.a"

INC=""
for d in include libs/include back-end back-end/include axi-interconnect-kit/include axi-interconnect-kit/sim_ddr/include \
         axi-interconnect-kit/axi_interconnect/include axi-interconnect-kit/mmio/include MemSubSystem/include diff/include \
         front-end back-end/Exu/include back-end/Lsu/include back-end/tools/include function-model/include/api legacy/mmu/include; do
  INC="$INC -I$REF/$d"
done

FILES=(); while IFS= read -r f; do FILES+=("$ROOT/$f"); done < <(bash "$ROOT/scripts/rtl_files.sh" "$ROOT")

cd "$OUT"
for s in axi-interconnect-kit/sim_ddr/SimDDR.cpp back-end/PhysMemory.cpp; do
  clang++ -std=c++2a -O2 -w $INC $DS3FLAGS -c "$REF/$s" -o "$(basename "$s" .cpp).o" &
done
wait

JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 6)}
verilator --cc --exe --build -j "$JOBS" --output-split 5000 --output-split-cfuncs 5000 \
  --assert -GDDR_DATA_W="$DDR_DATA_W" \
  -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT --x-assign 0 --x-initial 0 $VOPT \
  --top-module chip_top -Mdir obj \
  -CFLAGS "$COPT $DS3FLAGS -DXLEN=64 -std=c++2a -w $INC $FPINC" \
  -LDFLAGS "-Wl,--start-group $OUT/SimDDR.o $OUT/PhysMemory.o $DS3LD $FPLD -Wl,--end-group ${SOC_LDFLAGS:-${CHIP_LDFLAGS:-}}" \
  "$ROOT/tb/soc/soc_tb.cpp" "${FPDPI[@]}" "${FILES[@]}" -o soc_tb > build.log 2>&1 || {
    grep -E "error:|%Error" build.log | grep -v "Command Failed" | head -20
    echo "BUILD FAILED, see $OUT/build.log"
    exit 1
  }
ls -la "$OUT/obj/soc_tb" | awk '{print "built", $9}'
