#!/usr/bin/env bash
# build.sh: assemble and link the directed test programs of this directory (needs LLVM with the RISC-V target and ld.lld)
set -euo pipefail
cd "$(dirname "$0")"
CLANG=${CLANG:-/opt/homebrew/opt/llvm/bin/clang}; LLD=${LD_LLD:-ld.lld}; OBJCOPY=${OBJCOPY:-/opt/homebrew/opt/llvm/bin/llvm-objcopy}
for s in *.S; do
  n=${s%.S}
  "$CLANG" --target=riscv32-unknown-elf -march=rv32ia -mabi=ilp32 -c "$s" -o "/tmp/$n.o"
  "$LLD" -m elf32lriscv --no-relax -T link.ld "/tmp/$n.o" -o "/tmp/$n.elf"
  "$OBJCOPY" -O binary "/tmp/$n.elf" "$n.bin"
  echo "built $n.bin"
done
