#!/usr/bin/env bash
# Build the closed-loop SoC testbench: Verilated soc_top + the reference's SimDDR / PhysMemory.
#   usage: tb/soc/build.sh        env: REFSRC (reference source tree), JOBS
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
REF=${REFSRC:-/Users/ruyaoh/personal/llm4trace/third_party/tututugege/baseline-sim/src}
OUT=$ROOT/build/soc; mkdir -p "$OUT"
INC=""
for d in include libs/include back-end back-end/include axi-interconnect-kit/include axi-interconnect-kit/sim_ddr/include \
         axi-interconnect-kit/axi_interconnect/include axi-interconnect-kit/mmio/include MemSubSystem/include diff/include front-end back-end/Exu/include back-end/Lsu/include back-end/tools/include GenSimpoint/include/api legacy/mmu/include; do INC="$INC -I$REF/$d"; done
FILES=(); while IFS= read -r f; do FILES+=("$ROOT/$f"); done < <(bash "$ROOT/scripts/rtl_files.sh" "$ROOT")
python3 "$ROOT/tools/gen_soc_probe.py" >/dev/null
cd "$OUT"
# reference platform models (not RTL)
for s in axi-interconnect-kit/sim_ddr/SimDDR.cpp back-end/PhysMemory.cpp; do
  clang++ -std=c++2a -O2 -w $INC -c "$REF/$s" -o "$(basename "$s" .cpp).o" &
done
wait
verilator --cc --exe --build -j "${JOBS:-6}" -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT --public-flat-rw --x-assign 0 --x-initial 0 \
  --top-module soc_top -Mdir obj -CFLAGS "-O2 -std=c++2a -w $INC -I$ROOT/harness/include -I$ROOT/tb/soc" \
  -LDFLAGS "$OUT/SimDDR.o $OUT/PhysMemory.o" \
  "$ROOT/tb/soc/soc_tb.cpp" "${FILES[@]}" -o soc_tb > build.log 2>&1 || { grep -E "error:|%Error" build.log | grep -v "Command Failed" | head -12 | cut -c1-200; echo "BUILD FAILED, see $OUT/build.log"; exit 1; }
ls -la "$OUT/obj/soc_tb" | awk '{print "built", $9}'
