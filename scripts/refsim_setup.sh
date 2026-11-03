#!/usr/bin/env bash
# Create/refresh refsim/: a copy of the reference simulator (baseline-sim) with the recording hook added.
# The baseline itself is never modified. The copy keeps the baseline's object files, so only the hooked file
# is recompiled. Idempotent.
#   env BASELINE_SRC overrides the baseline location.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE=${BASELINE_SRC:-/Users/ruyaoh/personal/llm4trace/third_party/tututugege/baseline-sim/src}
REF=$ROOT/refsim
mkdir -p "$REF"
rsync -a --exclude '.git' "$BASE/" "$REF/"
cp "$ROOT/refhook/ttg_rec_hook.h" "$REF/include/ttg_rec_hook.h"
python3 - "$REF/rv_simu_mmu_v2.cpp" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if 'ttg_rec_hook.h' not in s:
    s = '#include "ttg_rec_hook.h"\n' + s
    old = "    back.comb();\n  }\n"
    assert s.count(old) == 1, "hook site not found / not unique"
    s = s.replace(old, old + "  ttg_rec::cycle(this, ctx.perf.cycle);\n")
    open(p, 'w').write(s)
    print("hook inserted")
PY
cd "$REF" && gmake LDFLAGS="-lz" -j8 2>&1 | grep -E " error|Linking|Nothing" || true
ls -la "$REF/build/simulator" | awk '{print $6,$7,$8,$9}'
