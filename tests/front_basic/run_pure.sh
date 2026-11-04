#!/usr/bin/env bash
# Build the golden-model trace generators for the pure modules against the (read-only) reference sources and write
#   traces/{predecode,sequential_next_pc,predecode_checker}/rand_*.trc
#   usage: bash tests/front_basic/run_pure.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
. "$ROOT/scripts/env.sh"
REF=${REFSIM:-$ROOT/refsim_tap}
SRC=$BASELINE_SRC
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include MemSubSystem/include diff/include front-end; do INC+=("-I$REF/$d"); done
build() {   # <module> <generator.cpp> <reference .cpp...>
  local m=$1 g=$2; shift 2
  python3 harness/tools/iogen.py spec/$m.io build/$m >/dev/null
  clang++ -std=c++2a -O1 -w -DNDEBUG "${INC[@]}" -Iharness/include -Ibuild/$m -Itests/front_basic \
    -DMODFIELDS="\"${m}_fields.h\"" "-DMOD=$m" tests/front_basic/$g "$@" -o build/$m/gen
  mkdir -p traces/$m
}
build predecode gen_predecode.cpp "$SRC/front-end/predecode.cpp"
build sequential_next_pc gen_predecode.cpp "$SRC/front-end/predecode.cpp"
build predecode_checker gen_checker.cpp "$SRC/front-end/predecode_checker.cpp"
build/predecode/gen traces/predecode/rand_a.trc 1 200000
build/predecode/gen traces/predecode/rand_b.trc 2 200000
build/sequential_next_pc/gen traces/sequential_next_pc/rand_a.trc 1 200000
build/predecode_checker/gen traces/predecode_checker/rand_a.trc 1 300000
build/predecode_checker/gen traces/predecode_checker/rand_b.trc 2 300000
# front_ctrl: literal transcription of the C++ control + exhaustive inputs
build front_ctrl gen_ctrl.cpp
build/front_ctrl/gen traces/front_ctrl/exh_a.trc 1 100000
build/front_ctrl/gen traces/front_ctrl/exh_b.trc 2 100000
