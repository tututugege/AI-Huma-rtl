#!/usr/bin/env bash
# Build tests/fp_${SRC:-chain}.chain.c (rv32imafd) and run it on the RTL SoC (FP=1 config build) with the per-commit function-model check.
#   usage: [SRC=chain|mem] tests/fp_chain/run.sh <soc_tb built with SOC_FM=1 FMLIB=<rv32 F/D librefcpu.a>> <work-dir>      env LLVM, LLD, TM_TESTS (dir with start.S, link.lds)
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd); TB=$1; W=${2:?work dir}; mkdir -p "$W"; . "$R/scripts/env.sh"
L=${LLVM:-/opt/homebrew/opt/llvm/bin}; LD=${LLD:-/opt/homebrew/bin/ld.lld}
CT="--target=riscv32 -march=rv32imafd_zicsr_zifencei -mabi=ilp32d -mcmodel=medlow"
$L/clang $CT -c "$AI_HUMA_ROOT/trace-model/baremetal/start.S" -o "$W/start.o"
$L/clang $CT -O1 -ffreestanding -nostdlib -c "$R/tests/fp_chain/${SRC:-chain}.c" -o "$W/${SRC:-chain}.o"
cp "$AI_HUMA_ROOT/trace-model/baremetal/link.lds" "$W/link.lds" 2>/dev/null || true
$LD -T "${LINK_LDS:-$W/link.lds}" --gc-sections "$W/start.o" "$W/${SRC:-chain}.o" -o "$W/${SRC:-chain}.elf"
$L/llvm-objcopy -O binary "$W/${SRC:-chain}.elf" "$W/${SRC:-chain}.bin"
SOC_TB_FM=1 "$TB" "$W/${SRC:-chain}.bin" 200000 2>&1 | grep -aE "sim-time|\[FM\]" | head -12
