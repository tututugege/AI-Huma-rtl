#!/usr/bin/env bash
# build.sh: assemble and link the directed test programs of this directory (needs LLVM with the RISC-V target and ld.lld)
#   *.S    -> <name>.bin         rv32ia (rv32ima for memspec_data)
#   memspec_data.S, memspec_addr.S, memspec_pf.S also -> memspec_*64.bin  (rv64ima, -DRV64)
set -euo pipefail
cd "$(dirname "$0")"
CLANG=${CLANG:-/opt/homebrew/opt/llvm/bin/clang}; LLD=${LD_LLD:-ld.lld}; OBJCOPY=${OBJCOPY:-/opt/homebrew/opt/llvm/bin/llvm-objcopy}
for s in *.S; do
  n=${s%.S}
  arch=rv32ia; case $n in memspec_data|memspec_addr|memspec_pf) arch=rv32ima_zicsr;; esac
  "$CLANG" --target=riscv32-unknown-elf -march=$arch -mabi=ilp32 -c "$s" -o "/tmp/$n.o"
  "$LLD" -m elf32lriscv --no-relax -T link.ld "/tmp/$n.o" -o "/tmp/$n.elf"
  "$OBJCOPY" -O binary "/tmp/$n.elf" "$n.bin"
  echo "built $n.bin"
done
for n in memspec_data memspec_addr memspec_pf; do
  "$CLANG" --target=riscv64-unknown-elf -march=rv64ima_zicsr -mabi=lp64 -DRV64 -c $n.S -o /tmp/${n}64.o
  "$LLD" -m elf64lriscv --no-relax -T link.ld /tmp/${n}64.o -o /tmp/${n}64.elf
  "$OBJCOPY" -O binary /tmp/${n}64.elf ${n}64.bin
  echo "built ${n}64.bin"
done
