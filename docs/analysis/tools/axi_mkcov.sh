#!/usr/bin/env bash
# build coverage-instrumented simulator (only the two AXI files instrumented, -O0)
set -e
cd "$1"
INC=(-I./include/ -I./libs/include/ -I./back-end/include/ -I./back-end/Exu/include/ -I./back-end/Lsu/include/ -I./back-end/tools/include/ -I./MemSubSystem/include/ -I./diff/include/ -I./GenSimpoint/include/api/ -I./legacy/mmu/include/ -I./front-end/ -I./axi-interconnect-kit/include/ -I./axi-interconnect-kit/axi_interconnect/include/ -I./axi-interconnect-kit/sim_ddr/include/ -I./axi-interconnect-kit/mmio/include/)
D=build/axi-interconnect-kit/axi_interconnect
for f in AXI_Interconnect AXI_LLC; do
  clang++ -O0 -g --coverage --std=c++2a -DNDEBUG "${INC[@]}" -c axi-interconnect-kit/axi_interconnect/$f.cpp -o $D/$f.o -w &
done
wait
OBJS=($(find build -name "*.o"))
clang++ "${OBJS[@]}" ./GenSimpoint/librefcpu.a ./libs/softfloat.a -lz --coverage -o build/simulator_cov
ls -la build/simulator_cov
