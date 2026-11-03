#!/usr/bin/env bash
# Build the constrained-random Idu trace generator against the (read-only) reference sources.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
REF=${REFSIM:-/Users/ruyaoh/personal/tututugege-rtl/refsim}
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include diff/include front-end; do INC+=("-I$REF/$d"); done
mkdir -p "$ROOT/build/tb"
clang++ -std=c++2a -O1 -w -DNDEBUG "${INC[@]}" -I"$ROOT/harness/include" -I"$ROOT/build/idu" \
  "$ROOT/tb/idu/gen_rand.cpp" "$REF/back-end/Idu.cpp" -o "$ROOT/build/tb/gen_rand"
