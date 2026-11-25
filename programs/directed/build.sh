#!/usr/bin/env bash
# build.sh: assemble and link the directed test programs of this directory (needs LLVM with the RISC-V target and ld.lld)
#   *.S    -> <name>.bin         rv64ima (-DRV64)
set -euo pipefail
cd "$(dirname "$0")"
CLANG=${CLANG:-$(command -v clang || echo /opt/homebrew/opt/llvm/bin/clang)}
LLD=${LD_LLD:-$(command -v ld.lld || echo ld.lld)}
OBJCOPY=${OBJCOPY:-$(command -v llvm-objcopy || command -v llvm-objcopy-18 || echo /opt/homebrew/opt/llvm/bin/llvm-objcopy)}
T=${TMPDIR:-/tmp}
for s in *.S; do
  n=${s%.S}
  "$CLANG" --target=riscv64-unknown-elf -march=rv64imafd_zicsr_zifencei -mabi=lp64d -DRV64 -c "$s" -o "$T/$n.o"
  "$LLD" -m elf64lriscv --no-relax -T link.ld "$T/$n.o" -o "$T/$n.elf"
  "$OBJCOPY" -O binary "$T/$n.elf" "$n.bin"
  echo "built $n.bin"
done
