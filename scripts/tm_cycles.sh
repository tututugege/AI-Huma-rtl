#!/usr/bin/env bash
# tm_cycles.sh <trace-model-simulator> [outfile]: run every program of scripts/ref_cycles.txt on the trace-model and print
# "<cycles> <path>" lines (the format of ref_cycles.txt), e.g. to regenerate it after a configuration change.
#   env JOBS (default 8), TTG_PROGS / TTG_BIG (see env.sh)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/scripts/env.sh"
SIMB=$1; OUTF=${2:-/dev/stdout}
one() {
  rel=$1
  case "$rel" in
    big/*) p=$TTG_BIG/${rel#big/} ;;
    directed/*) p=$ROOT/programs/$rel ;;
    *) p=$TTG_PROGS/tests/$rel; [ -f "$p" ] || p=$TTG_PROGS/vm/$rel ;;
  esac
  c=$(cd "$(dirname "$(dirname "$SIMB")")" && perl -e 'alarm 900; exec @ARGV' "$SIMB" "$p" 2>&1 | grep -a -o 'sim-time(cycle)= *[0-9]*' | tail -1 | grep -o '[0-9]*$')
  echo "${c:-FAIL} $rel"
}
export -f one; export SIMB TTG_PROGS TTG_BIG
grep -v '^#' "$ROOT/scripts/ref_cycles.txt" | awk 'NF{print $2}' | xargs -P "${JOBS:-8}" -I{} bash -c 'one {}' | sort -k2 > "$OUTF"
