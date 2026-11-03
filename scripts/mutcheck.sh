#!/usr/bin/env bash
# Coordinator mutation check: apply ONE textual mutation to a copy of a module branch and require the replay to FAIL.
#   usage: mutcheck.sh <worktree-dir> <module> <rtl-file-relative-to-worktree> <old> <new> <trace-name>...
set -uo pipefail
MAIN=$(cd "$(dirname "$0")/.." && pwd)
W=$1; MOD=$2; F=$3; OLD=$4; NEW=$5; shift 5
T=$(mktemp -d); cp -R "$W/rtl" "$W/spec" "$T/"
python3 - "$T/$F" "$OLD" "$NEW" <<'EOF' || exit 2
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) >= 1, "pattern not found"
open(p, "w").write(s.replace(old, new, 1))
EOF
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(cd "$T" && { find rtl/common -name 'ttg_*.sv' ! -name ttg_cfg_pkg.sv | sort; find rtl -path rtl/common -prune -o -name '*.sv' -print | sort; })
( cd "$T" && bash "$MAIN/scripts/hbuild.sh" "spec/$MOD.io" "$T/build" rtl/common/ttg_cfg_pkg.sv "${FILES[@]}" ) 2>&1 | tail -1
for t in "$@"; do echo -n "$t: "; "$T/build/replay" "$W/traces/$MOD/$t.trc" | head -3 | tr '\n' ' '; echo; done
rm -rf "$T"
