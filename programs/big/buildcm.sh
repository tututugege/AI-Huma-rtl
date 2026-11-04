#!/bin/bash
# usage: buildcm.sh  -> cm/coremark<IT>.bin  (programs/big/coremark.bin is the 2-iteration build)
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../scripts/env.sh"
B=$AI_HUMA_ROOT/trace-model/baremetal
L=${LLVM:-/opt/homebrew/opt/llvm/bin}
T=$TTG_PROGS/tests
mkdir -p $HERE/cm
for IT in 2; do
  CF="--target=riscv32 -march=rv32ima_zicsr_zifencei -mabi=ilp32 -O2 -mcmodel=medlow -mstrict-align -ffreestanding -fno-builtin -nostdlib -I$HERE/inc -I$B/coremark -I$B -I$B/include -DITERATIONS=$IT"
  objs=(); ok=1
  for s in $B/start.S $B/lib/*.c $B/coremark/*.c; do
    o=$HERE/cm/$IT.$(basename $s).o
    $L/clang $CF -c $s -o $o 2>$HERE/cm/cc.$IT.log || { ok=0; echo "cc fail $s"; tail -3 $HERE/cm/cc.$IT.log; break; }
    objs+=($o)
  done
  if [ $ok = 1 ]; then
    /opt/homebrew/bin/ld.lld -T $T/link.lds --gc-sections "${objs[@]}" -o $HERE/cm/coremark$IT.elf 2>$HERE/cm/ld.log \
      && $L/llvm-objcopy -O binary $HERE/cm/coremark$IT.elf $HERE/cm/coremark$IT.bin && ls -l $HERE/cm/coremark$IT.bin || tail -3 $HERE/cm/ld.log
  fi
done
