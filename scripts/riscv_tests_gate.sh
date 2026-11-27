#!/usr/bin/env bash
# Build and run official riscv-tests (RV64) on RTL core_tb with function-model difftest + SVA + optional coverage.
#   usage: scripts/riscv_tests_gate.sh <core_tb> <outdir>
#   env:
#     RISCV_TESTS  path to riscv-tests checkout (default: ~/qimeng1-serial-regression/source/baremetal/riscv-tests)
#     SUITES       space-separated suites (default: "rv64ui rv64um rv64ua rv64uf rv64ud rv64uc rv64uzba rv64uzbb rv64uzbc rv64uzbs")
#     JOBS         parallel workers (default: 16)
#     MAX_CYCLES   per-test cycle cap (default: 200000)
#     SOC_TB_FM_STRICT=1  enable strict CSR + MMIO store checking
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/env.sh"

TB=${1:?usage: riscv_tests_gate.sh <soc_tb> <outdir>}
OUT=${2:?usage: riscv_tests_gate.sh <soc_tb> <outdir>}
RT=${RISCV_TESTS:-$HOME/qimeng1-serial-regression/source/baremetal/riscv-tests}
SUITES=${SUITES:-"rv64ui rv64um rv64ua rv64uf rv64ud rv64uc rv64uzba rv64uzbb rv64uzbc rv64uzbs"}
SKIP_TESTS=${SKIP_TESTS:-"rv64ui-ma_data"}   # known unsupported: misaligned data access
JOBS=${JOBS:-16}
MAX_CYCLES=${MAX_CYCLES:-200000}

CC=${CC:-$(command -v clang || command -v clang-18)}
LLD=${LLD:-$(command -v ld.lld)}
OBJCOPY=${OBJCOPY:-$(command -v llvm-objcopy || command -v llvm-objcopy-18 || command -v objcopy)}
BM="${TM_DIR:-$AI_HUMA_ROOT/trace-model}/baremetal"

[ -d "$RT/isa" ] || { echo "ERROR: riscv-tests not found at $RT/isa"; exit 1; }
mkdir -p "$OUT/env" "$OUT/bins" "$OUT/logs"

# Prepare linker script (adapted from function-model/tests/rv64/riscv-tests-fp.sh)
sed -e 's/(wxa!ri)/(wxa)/' -e 's/^\( *\)\. = __stack_size;/\1. += __stack_size;/' -e 's/\(\.stack ORIGIN[^:]*\):/\1 (NOLOAD) :/' \
  "$BM/link.lds" > "$OUT/env/link.lds.0"
python3 - "$OUT/env/link.lds.0" "$OUT/env/link.lds" <<'PY'
import sys
t = open(sys.argv[1]).read()
t = t.replace("  .data ", "  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } >ram AT>ram\n  .data ", 1)
t = t.replace("  .dma_buffer", "  .bss (NOLOAD) : { *(.sbss .sbss.* .bss .bss.* COMMON) . = ALIGN(8); } >ram AT>ram\n\n  .dma_buffer", 1)
open(sys.argv[2], "w").write(t)
PY

# Wrapper riscv_test.h: enable mstatus.FS at entry; self-check failure loops forever so soc_tb reports NO EBREAK (FAIL).
cat > "$OUT/env/riscv_test.h" <<HDR
#include "$RT/isa/riscv_test.h"
#define RVTEST_RV64UF
#undef RVTEST_CODE_BEGIN
#define RVTEST_CODE_BEGIN .section .text; .globl main; main: li t0, 0x2000; csrs mstatus, t0;
#undef RVTEST_FAIL
#define RVTEST_FAIL 1: j 1b;
HDR

CT="--target=riscv64 -march=rv64imafdc_zba_zbb_zbc_zbs_zicsr_zifencei -mabi=lp64d -mcmodel=medany"
"$CC" $CT -c "$BM/start.S" -o "$OUT/env/start.o"

# Collect all .S tests
LIST="$OUT/tests.list"
: > "$LIST"
for suite in $SUITES; do
  [ -d "$RT/isa/$suite" ] || continue
  for s in "$RT/isa/$suite"/*.S; do
    [ -f "$s" ] || continue
    echo "$suite $(basename "$s" .S) $s" >> "$LIST"
  done
done

run_one() {
  local suite=$1 name=$2 src=$3
  local t="${suite}-${name}"
  case " $SKIP_TESTS " in
    *" $t "*) echo "SKIP $t (known unsupported)"; return ;;
  esac
  local d="$OUT/bins/$t"
  mkdir -p "$d"
  if ! "$CC" $CT -ffreestanding -nostdlib \
        -I"$OUT/env" -I"$RT/isa/macros/scalar" -c "$src" -o "$d/t.o" 2>"$d/cc.log" || \
     ! "$LLD" -T "$OUT/env/link.lds" --gc-sections "$OUT/env/start.o" "$d/t.o" -o "$d/t.elf" 2>"$d/ld.log" || \
     ! "$OBJCOPY" -O binary "$d/t.elf" "$d/t.bin" 2>"$d/oc.log"; then
    echo "BUILD_FAIL $t"
    return
  fi
  SOC_TB_FM=1 SOC_TB_COV_OUT="$OUT/logs/$t.cov.dat" \
    perl -e 'alarm 300; exec @ARGV' "$TB" "$d/t.bin" "$MAX_CYCLES" > "$OUT/logs/$t.log" 2>&1
  local l fm sva cyc
  l=$(grep -a "sim-time" "$OUT/logs/$t.log" | head -1)
  fm=$(grep -aE "^\[FM\].*(rtl=|rejects)" "$OUT/logs/$t.log" | wc -l | tr -d " ")
  sva=$(grep -aE "%Error|Assertion failed|\[SVA_" "$OUT/logs/$t.log" | wc -l | tr -d " ")
  cyc=$(echo "$l" | sed -n 's/.*= \([0-9]*\), committed= \([0-9]*\).*/\1 \2/p')
  if [ -n "$cyc" ] && [ "$fm" = 0 ] && [ "$sva" = 0 ] && ! echo "$l" | grep -q "NO EBREAK"; then
    echo "PASS $t $cyc"
  else
    echo "FAIL $t fm=$fm sva=$sva $l"
  fi
}
export -f run_one
export CC LLD OBJCOPY CT OUT RT TB MAX_CYCLES SKIP_TESTS

xargs -P "$JOBS" -L1 bash -c 'run_one "$0" "$1" "$2"' < "$LIST" | sort > "$OUT/summary.txt"
PASS_N=$(grep -c '^PASS ' "$OUT/summary.txt" || true)
FAIL_N=$(grep -c '^FAIL ' "$OUT/summary.txt" || true)
SKIP_N=$(grep -c '^SKIP ' "$OUT/summary.txt" || true)
BFAIL_N=$(grep -c '^BUILD_FAIL ' "$OUT/summary.txt" || true)
echo "== riscv-tests ($(basename "$OUT")): PASS $PASS_N  FAIL $FAIL_N  SKIP $SKIP_N  BUILD_FAIL $BFAIL_N =="
grep -v '^PASS ' "$OUT/summary.txt" || true
[ "$FAIL_N" = 0 ] && [ "$BFAIL_N" = 0 ]
