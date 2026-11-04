#!/bin/bash
set -e
RUNS=${1:-64}
B=/Users/ruyaoh/personal/llm4trace/third_party/tututugege/baseline-sim/src/baremetal
L=/opt/homebrew/opt/llvm/bin
T=/Users/ruyaoh/personal/AI-Huma/trace-model/build/tests
D=/Users/ruyaoh/personal/AI-Huma/rtl/programs/big/dhry; mkdir -p $D; cd $D; rm -f *.o
cp $B/dhrystone/*.c $B/dhrystone/*.h .
sed -i '' "s/#define NUMBER_OF_RUNS [0-9]*/#define NUMBER_OF_RUNS $RUNS/" dhrystone.h
CF="--target=riscv32 -march=rv32ima_zicsr_zifencei -mabi=ilp32 -O0 -mcmodel=medlow -mstrict-align -ffreestanding -fno-builtin -nostdlib -std=gnu89 -I. -I/Users/ruyaoh/personal/AI-Huma/rtl/programs/big/inc -I$B -I$B/include -w"
objs=()
for s in $B/start.S $B/lib/*.c dhrystone.c dhrystone_main.c /Users/ruyaoh/personal/AI-Huma/rtl/programs/big/libc_min.c; do
  o=$(basename $s).o; $L/clang $CF -c $s -o $o; objs+=($o)
done
/opt/homebrew/bin/ld.lld -T $T/link.lds --gc-sections "${objs[@]}" -o dhry$RUNS.elf
$L/llvm-objcopy -O binary dhry$RUNS.elf dhry$RUNS.bin
ls -l dhry$RUNS.bin
