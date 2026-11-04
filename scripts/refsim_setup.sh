#!/usr/bin/env bash
# Create/refresh refsim/: a copy of the reference simulator (baseline-sim) with the recording hook added.
# The baseline itself is never modified. The copy keeps the baseline's object files, so only the hooked file
# is recompiled. Idempotent.
#   env BASELINE_SRC overrides the baseline location, REFSIM_DIR the output directory.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/env.sh"
BASE=$BASELINE_SRC
REF=${REFSIM_DIR:-$ROOT/refsim}   # REFSIM_DIR: build into another directory (used to avoid disturbing a refsim that is in use)
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
# Front-end recording tap (read-only copies of front_comb_calc locals; active only when $TTG_REC is set).
cp "$ROOT/refhook/front_tap.h" "$REF/front-end/front_tap.h"
if ! grep -q 'front_tap.h' "$REF/front-end/front_top.cpp"; then
  (cd "$REF" && patch -p1 < "$ROOT/refhook/front_top_tap.patch") || { echo "front_top_tap.patch failed"; exit 1; }
  echo "front tap inserted"
fi
cd "$REF" && gmake LDFLAGS="-lz" -j8 2>&1 | grep -E " error|Linking|Nothing" || true
ls -la "$REF/build/simulator" | awk '{print $6,$7,$8,$9}'
