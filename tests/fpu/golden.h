// Golden wrapper: runs the reference FPUSoftfloat (Berkeley softfloat) on one instruction.
#pragma once
#include <cstdint>
#define protected public
#define private public
#include "FPU.h"
#undef protected
#undef private

struct FpuGolden : FPUSoftfloat {
  FpuGolden() : FPUSoftfloat("FPU", 1, 10) {}
  // Returns the result word; `lat` receives the latency the reference model assigns.
  uint32_t run(uint32_t func7, uint32_t func3, uint32_t imm, uint32_t a, uint32_t b, int *lat) {
    ExuInst inst;
    inst.op = UOP_FP; inst.func7 = func7; inst.func3 = func3; inst.imm = imm;
    inst.src1_rdata = a; inst.src2_rdata = b;
    impl_compute(inst);
    if (lat) *lat = calculate_latency(inst);
    return inst.result;
  }
};
