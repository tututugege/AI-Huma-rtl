#!/usr/bin/env bash
# usage: build_plugin.sh <refsim dir> <src.cpp> <out.dylib> [extra clang flags]
REF=$1; SRC=$2; OUT=$3; shift 3
INC=""
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include \
         MemSubSystem/include diff/include GenSimpoint/include/api legacy/mmu/include front-end \
         axi-interconnect-kit/include axi-interconnect-kit/axi_interconnect/include \
         axi-interconnect-kit/sim_ddr/include axi-interconnect-kit/mmio/include; do INC="$INC -I$REF/$d"; done
clang++ -std=c++2a -O1 -w -fPIC -shared -undefined dynamic_lookup -DNDEBUG $INC "$@" "$SRC" -o "$OUT"
