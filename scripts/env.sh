#!/usr/bin/env bash
# Common locations for every script of this repository.  Source it:   . "$(dirname "$0")/env.sh"     (from tests/<m>/: . "$ROOT/scripts/env.sh")
# Nothing here is machine specific: everything is derived from where this file lives, and every variable can be overridden from the environment.
#
#   RTL_ROOT         this repository                                   (derived)
#   AI_HUMA_ROOT     the AI-Huma checkout that contains rtl/ and trace-model/   (default: parent of RTL_ROOT)
#   TTG_PROGS        built test programs: $TTG_PROGS/tests/<t>/<t>.bin, $TTG_PROGS/vm/<t>/<t>.bin   (default: trace-model/build)
#   TTG_BIG          shortened dhrystone(64) / coremark(2)             (default: $RTL_ROOT/programs/big)
#   TM               trace-model simulator binary                      (default: trace-model/build/simulator)
#   BASELINE_SRC     source of the reference simulator (read-only, lives outside AI-Huma)
#   REFSIM / REFSIM_TAP / REFSIM_AXI   reference-simulator copies with the recording hooks (default: $RTL_ROOT/refsim, refsim_tap, refsim_axi)
# Program lists (scripts/progs*.txt, ...): one program per line; a relative entry is resolved by `ttg_resolve_list`:
#   tests/<t>/<t>.bin, vm/<t>/<t>.bin  -> $TTG_PROGS/...      big/<n>.bin -> $TTG_BIG/<n>.bin      tm/<path> -> $AI_HUMA_ROOT/trace-model/<path>      baseline/<path> -> $BASELINE_SRC/<path>
#   absolute entries are kept as they are; a `|cap` suffix (scripts/progs.txt) is kept.

_env_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RTL_ROOT=${RTL_ROOT:-$(cd "$_env_dir/.." && pwd)}
AI_HUMA_ROOT=${AI_HUMA_ROOT:-$(cd "$RTL_ROOT/.." && pwd)}
TTG_PROGS=${TTG_PROGS:-$AI_HUMA_ROOT/trace-model/build}
TTG_BIG=${TTG_BIG:-$RTL_ROOT/programs/big}
TM=${TM:-$AI_HUMA_ROOT/trace-model/build/simulator}
BASELINE_SRC=${BASELINE_SRC:-$AI_HUMA_ROOT/../llm4trace/third_party/tututugege/baseline-sim/src}
REFSIM=${REFSIM:-$RTL_ROOT/refsim}
REFSIM_TAP=${REFSIM_TAP:-$RTL_ROOT/refsim_tap}
REFSIM_AXI=${REFSIM_AXI:-$RTL_ROOT/refsim_axi}
export RTL_ROOT AI_HUMA_ROOT TTG_PROGS TTG_BIG TM BASELINE_SRC REFSIM REFSIM_TAP REFSIM_AXI

# ttg_resolve_list <file>: print the program paths of a list, absolute
ttg_resolve_list() {
  local l
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in
      ''|'#'*) continue ;;
      /*) echo "$l" ;;
      big/*) echo "$TTG_BIG/${l#big/}" ;;
      tm/*) echo "$AI_HUMA_ROOT/trace-model/${l#tm/}" ;;
      baseline/*) echo "$BASELINE_SRC/${l#baseline/}" ;;
      *) echo "$TTG_PROGS/$l" ;;
    esac
  done < "$1"
}

# ttg_all_progs: every gate test + vm test + dhrystone/coremark (shortened) + float_test that exists
ttg_all_progs() {
  ls "$TTG_PROGS"/tests/*/*.bin "$TTG_PROGS"/vm/*/*.bin
  local p
  for p in "$TTG_BIG/dhrystone.bin" "$TTG_BIG/coremark.bin" "$AI_HUMA_ROOT/trace-model/baremetal/float-test/float_test.bin"; do [ -f "$p" ] && echo "$p"; done
}
