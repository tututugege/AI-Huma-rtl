#!/bin/bash
set -e
# usage: build_dhry.sh [runs=64]  -> dhry/dhry<runs>.bin  (programs/big/dhrystone.bin is the 64-run build)
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../scripts/env.sh"
RUNS=${1:-64}
B=$AI_HUMA_ROOT/trace-model/baremetal
L=${LLVM:-/opt/homebrew/opt/llvm/bin}
T=$TTG_PROGS/tests
D=$HERE/dhry; mkdir -p $D; cd $D; rm -f *.o
cp $B/dhrystone/*.c $B/dhrystone/*.h .
sed -i '' "s/#define NUMBER_OF_RUNS [0-9]*/#define NUMBER_OF_RUNS $RUNS/" dhrystone.h
CF="--target=riscv32 -march=rv32ima_zicsr_zifencei -mabi=ilp32 -O0 -mcmodel=medlow -mstrict-align -ffreestanding -fno-builtin -nostdlib -std=gnu89 -I. -I$HERE/inc -I$B -I$B/include -w"
objs=()
for s in $B/start.S $B/lib/*.c dhrystone.c dhrystone_main.c $HERE/libc_min.c; do
  o=$(basename $s).o; $L/clang $CF -c $s -o $o; objs+=($o)
done
/opt/homebrew/bin/ld.lld -T $T/link.lds --gc-sections "${objs[@]}" -o dhry$RUNS.elf
$L/llvm-objcopy -O binary dhry$RUNS.elf dhry$RUNS.bin
ls -l dhry$RUNS.bin
