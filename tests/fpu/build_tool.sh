#!/usr/bin/env bash
# Compile a C++ tool against the reference model headers + softfloat.   usage: build_tool.sh <src.cpp> <out> [extra clang args]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-/Users/ruyaoh/personal/tututugege-rtl/refsim}
SRC=$1; OUT=$2; shift 2
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include MemSubSystem/include diff/include GenSimpoint/include/api legacy/mmu/include front-end; do INC+=("-I$REF/$d"); done
mkdir -p "$(dirname "$OUT")"
clang++ -std=c++2a -O2 -w "${INC[@]}" -Iharness/include -Ibuild/fpu -Itests/fpu "$SRC" "$@" "$REF/libs/softfloat.a" -o "$OUT"
