#!/usr/bin/env bash
# Build the directed DCache coverage programs tests/dcache/*.c with Homebrew LLVM (riscv32), same flags/linker script as
# tututugege-trace/scripts/build_tests.sh (which must have been run once: it produces build/tests/link.lds).
#   usage: build_dcache_tests.sh [outdir]      default outdir: build/dcache_tests   (one <name>/<name>.bin per source)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/build/dcache_tests}
BM=/Users/ruyaoh/personal/llm4trace/third_party/tututugege/baseline-sim/src/baremetal
LDS=/Users/ruyaoh/personal/AI-Huma/trace-model/build/tests/link.lds
L=${LLVM:-/opt/homebrew/opt/llvm/bin}
CF="--target=riscv32 -march=rv32ima_zicsr_zifencei -mabi=ilp32 -O2 -ffp-contract=off -mcmodel=medlow -mstrict-align -ffreestanding -fno-builtin -nostdlib -I$BM -I$BM/include"
for src in "$ROOT"/tests/dcache/*.c; do
  t=$(basename "$src" .c); d=$OUT/$t; mkdir -p "$d"; objs=(); ok=1
  for s in "$BM/start.S" "$BM"/lib/*.c "$src"; do
    o=$d/$(basename "$s").o
    $L/clang $CF -c "$s" -o "$o" 2>"$d/cc.log" || { ok=0; break; }; objs+=("$o")
  done
  [ $ok = 1 ] && /opt/homebrew/bin/ld.lld -T "$LDS" --gc-sections "${objs[@]}" -o "$d/$t.elf" 2>"$d/ld.log" \
    && $L/llvm-objcopy -O binary "$d/$t.elf" "$d/$t.bin" || ok=0
  echo "$t $([ $ok = 1 ] && echo OK || echo FAIL)"
done
