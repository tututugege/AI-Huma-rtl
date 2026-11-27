#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
CLANG=${CLANG:-$(command -v clang)}
LLD=${LD_LLD:-$(command -v ld.lld)}
OBJCOPY=${OBJCOPY:-$(command -v llvm-objcopy || command -v llvm-objcopy-18)}
T=${TMPDIR:-/tmp}
for s in *.S; do
  n=${s%.S}
  "$CLANG" --target=riscv64-unknown-elf -march=rv64imafd_zicsr_zifencei -mabi=lp64d -c "$s" -o "$T/$n.o"
  "$LLD" -m elf64lriscv --no-relax -T link.ld "$T/$n.o" -o "$T/$n.elf"
  "$OBJCOPY" -O binary "$T/$n.elf" "$n.bin"
  echo "built $n.bin"
done
