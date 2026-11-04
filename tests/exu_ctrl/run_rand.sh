#!/usr/bin/env bash
# Build the random-stimulus generator against the (read-only) reference sources and write traces/exu_ctrl/rand_*.trc.
#   usage: bash tests/exu_ctrl/run_rand.sh    (needs build/exu_ctrl/exu_ctrl_rec.cpp, e.g. after scripts/record.sh exu_ctrl)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-$ROOT/refsim}
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include MemSubSystem/include diff/include front-end; do INC+=("-I$REF/$d"); done
python3 harness/tools/iogen.py spec/exu_ctrl.io build/exu_ctrl >/dev/null
# the field recorder of the real-program recorder, reused on the stand-in BackTop struct of the generator
python3 - <<'PY'
import re
s = open("build/exu_ctrl/exu_ctrl_rec.cpp").read()
a = s.index("(void)cpu; (void)bt;") + len("(void)cpu; (void)bt;")
b = s.index("r.tw.commit(cycle);")
open("build/exu_ctrl/rand_record.inc", "w").write(s[a:b].replace("r.tw.set", "w.set"))
PY
clang++ -std=c++2a -O1 -w -DNDEBUG "${INC[@]}" -Iharness/include -Ibuild/exu_ctrl -Itests/exu_ctrl -Ibuild/exu_ctrl \
  tests/exu_ctrl/rand_trace.cpp "$REF/back-end/Exu/Exu.cpp" "$REF/libs/softfloat.a" -o build/exu_ctrl/rand_trace
mkdir -p traces/exu_ctrl
#                                  file                      seed cycles p_issue p_flush p_misp mix
build/exu_ctrl/rand_trace traces/exu_ctrl/rand_a.trc 1 40000 60 2 8 0
build/exu_ctrl/rand_trace traces/exu_ctrl/rand_b.trc 2 40000 90 1 4 1
build/exu_ctrl/rand_trace traces/exu_ctrl/rand_c.trc 3 40000 40 6 15 1
build/exu_ctrl/rand_trace traces/exu_ctrl/rand_d.trc 4 40000 95 0 20 0
