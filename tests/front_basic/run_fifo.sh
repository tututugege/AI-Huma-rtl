#!/usr/bin/env bash
# Build the FIFO random generator (links the REAL reference FIFO classes) and write traces/<fifo>/rand_*.trc.
#   usage: bash tests/front_basic/run_fifo.sh [cycles]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-/Users/ruyaoh/personal/AI-Huma/rtl/refsim_tap}
SRC=$REF/front-end
N=${1:-60000}
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include \
         MemSubSystem/include diff/include GenSimpoint/include/api legacy/mmu/include front-end \
         axi-interconnect-kit/include axi-interconnect-kit/axi_interconnect/include \
         axi-interconnect-kit/sim_ddr/include axi-interconnect-kit/mmio/include; do INC+=("-I$REF/$d"); done
for m in fetch_addr_fifo inst_fifo ptab front2back_fifo; do
  python3 harness/tools/iogen.py spec/$m.io build/$m >/dev/null
  clang++ -std=c++2a -O1 -w -DNDEBUG "${INC[@]}" -Iharness/include -Ibuild/$m -Itests/front_basic \
    -DMODFIELDS="\"${m}_fields.h\"" "-DMOD=$m" tests/front_basic/gen_fifo.cpp \
    $SRC/fifo/fetch_address_FIFO.cpp $SRC/fifo/instruction_FIFO.cpp $SRC/fifo/PTAB.cpp $SRC/fifo/front2bank_FIFO.cpp -o build/$m/genf
  mkdir -p traces/$m
  for s in 1 2 3; do build/$m/genf traces/$m/rand_$s.trc $s $N; done
done
