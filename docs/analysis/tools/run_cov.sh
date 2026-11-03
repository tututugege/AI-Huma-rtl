#!/usr/bin/env bash
# Run one coverage plugin on one program and keep its COV lines.
#   usage: run_cov.sh <plugin.dylib> <outdir> <prog.bin>        env: REFSIM (patched refsim, required), CAP (cycles, default 100000)
#   typical:  ls progs | xargs -P4 -n1 run_cov.sh cov.dylib cov/       then  agg.py cov/
set -euo pipefail
plug=$1; out=$2; prog=$3; name=$(basename "$prog" .bin)
: "${REFSIM:?set REFSIM to the patched refsim directory}"
mkdir -p "$out"
( cd "$REFSIM" && CHK_N=${CAP:-100000} TTG_REC="$plug" build/simulator "$prog" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "^COV|^MISMATCH" > "$out/$name.txt" ) || true
echo "$name $(wc -l < "$out/$name.txt") lines"
