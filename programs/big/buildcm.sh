#!/bin/bash
B=/Users/ruyaoh/personal/llm4trace/third_party/tututugege/simulator/baremetal
L=/opt/homebrew/opt/llvm/bin
T=/Users/ruyaoh/personal/AI-Huma/trace-model/build/tests
mkdir -p /Users/ruyaoh/personal/AI-Huma/rtl/programs/big/cm
for IT in 2; do
  CF="--target=riscv32 -march=rv32ima_zicsr_zifencei -mabi=ilp32 -O2 -mcmodel=medlow -mstrict-align -ffreestanding -fno-builtin -nostdlib -I/Users/ruyaoh/personal/AI-Huma/rtl/programs/big/inc -I$B/coremark -I$B -I$B/include -DITERATIONS=$IT"
  objs=(); ok=1
  for s in $B/start.S $B/lib/*.c $B/coremark/*.c; do
    o=/Users/ruyaoh/personal/AI-Huma/rtl/programs/big/cm/$IT.$(basename $s).o
    $L/clang $CF -c $s -o $o 2>/Users/ruyaoh/personal/AI-Huma/rtl/programs/big/cm/cc.$IT.log || { ok=0; echo "cc fail $s"; tail -3 /Users/ruyaoh/personal/AI-Huma/rtl/programs/big/cm/cc.$IT.log; break; }
    objs+=($o)
  done
  if [ $ok = 1 ]; then
    /opt/homebrew/bin/ld.lld -T $T/link.lds --gc-sections "${objs[@]}" -o /Users/ruyaoh/personal/AI-Huma/rtl/programs/big/cm/coremark$IT.elf 2>/Users/ruyaoh/personal/AI-Huma/rtl/programs/big/cm/ld.log \
      && $L/llvm-objcopy -O binary /Users/ruyaoh/personal/AI-Huma/rtl/programs/big/cm/coremark$IT.elf /Users/ruyaoh/personal/AI-Huma/rtl/programs/big/cm/coremark$IT.bin && ls -l /Users/ruyaoh/personal/AI-Huma/rtl/programs/big/cm/coremark$IT.bin || tail -3 /Users/ruyaoh/personal/AI-Huma/rtl/programs/big/cm/ld.log
  fi
done
