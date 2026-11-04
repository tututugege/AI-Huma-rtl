#!/usr/bin/env bash
# Build the constrained-random exu_fu trace generators against the (read-only) reference sources and write
# traces/<mod>/rand*.trc.   usage: bash tests/exu_fu/run_rand.sh [mod...]   (default: all seven)
# The generator is built twice (-O0 and -O3 -march=native, the reference simulator's own flags) and the two traces must be
# byte identical: this pins down the behaviour of the C++ undefined-behaviour spots (rol/ror by 0) on both builds.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-/Users/ruyaoh/personal/AI-Huma/rtl/refsim}
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include MemSubSystem/include diff/include front-end; do INC+=("-I$REF/$d"); done
MODS=("$@"); [ ${#MODS[@]} -gt 0 ] || MODS=(alu_bank bru_bank agu_bank sdu_bank csr_fu mul_bank div_bank)
mkdir -p build/tb
for m in "${MODS[@]}"; do
  python3 harness/tools/iogen.py spec/$m.io build/$m >/dev/null
  mkdir -p traces/$m
  case $m in alu_bank) K=FU_ALU;; bru_bank) K=FU_BRU;; agu_bank) K=FU_AGU;; sdu_bank) K=FU_SDU;; csr_fu) K=FU_CSR;; mul_bank) K=FU_MUL;; div_bank) K=FU_DIV;; esac
  # no -DNDEBUG: the reference's Assert()s stay on, so the stimulus is checked to be legal
  for O in O0 O3; do
    F=(-$O); [ $O = O3 ] && F=(-O3 -march=native)
    clang++ -std=c++2a "${F[@]}" -w -D$K "-DFIELDS_HDR=\"${m}_fields.h\"" "${INC[@]}" -Iharness/include -Ibuild/$m \
      tests/exu_fu/rand_fu.cpp -o build/tb/${m}_rand_$O -Wl,-undefined,dynamic_lookup
  done
  if [ $K = FU_MUL ] || [ $K = FU_DIV ]; then
    #                        seed cycles p_en p_consume p_flush
    ARGS=("1 60000 60 40 4" "2 60000 90 15 2" "3 60000 40 80 8" "4 60000 95 50 0")
  else
    ARGS=("1 40000" "2 40000" "3 40000")
  fi
  n=0
  for a in "${ARGS[@]}"; do
    n=$((n + 1))
    build/tb/${m}_rand_O3 traces/$m/rand$n.trc $a
    build/tb/${m}_rand_O0 build/tb/${m}_rand$n.O0.trc $a
    cmp traces/$m/rand$n.trc build/tb/${m}_rand$n.O0.trc || { echo "O0/O3 traces differ for $m rand$n"; exit 1; }
    rm -f build/tb/${m}_rand$n.O0.trc
  done
  echo "$m: wrote traces/$m/rand1..$n.trc (O0 == O3)"
done
