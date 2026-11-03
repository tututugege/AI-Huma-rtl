#include <cstdio>
#include "golden.h"
long long sim_time = 0;
int main() {
  FpuGolden g; int l;
  auto P = [&](const char *n, uint32_t f7, uint32_t f3, uint32_t imm, uint32_t a, uint32_t b) {
    uint32_t r = g.run(f7, f3, imm, a, b, &l); std::printf("%-28s a=%08x b=%08x -> %08x lat=%d\n", n, a, b, r, l); };
  P("fadd qnan+1", 0, 0, 0, 0x7fc00000, 0x3f800000);
  P("fadd snan+1", 0, 0, 0, 0x7f800001, 0x3f800000);
  P("fadd nan payload+1", 0, 0, 0, 0x7fc12345, 0x3f800000);
  P("fadd -nan+1", 0, 0, 0, 0xffc00000, 0x3f800000);
  P("fadd inf-inf", 0, 0, 0, 0x7f800000, 0xff800000);
  P("fmul 0*inf", 8, 0, 0, 0, 0x7f800000);
  P("fdiv 0/0", 0xc, 0, 0, 0, 0);
  P("fdiv 1/0", 0xc, 0, 0, 0x3f800000, 0);
  P("fsqrt -1", 0x2c, 0, 0, 0xbf800000, 0);
  P("fsqrt -0", 0x2c, 0, 0, 0x80000000, 0);
  P("fcvt.w.s nan", 0x60, 0, 0, 0x7fc00000, 0);
  P("fcvt.w.s +big", 0x60, 0, 0, 0x7f800000, 0);
  P("fcvt.w.s -big", 0x60, 0, 0, 0xff800000, 0);
  P("fcvt.w.s 3e9", 0x60, 0, 0, 0x4f351b9d, 0);
  P("fcvt.wu.s nan", 0x60, 0, 1, 0x7fc00000, 0);
  P("fcvt.wu.s -1.0", 0x60, 1, 1, 0xbf800000, 0);
  P("fcvt.wu.s -0.5 rtz", 0x60, 1, 1, 0xbf000000, 0);
  P("fcvt.wu.s -inf", 0x60, 0, 1, 0xff800000, 0);
  P("fcvt.wu.s +inf", 0x60, 0, 1, 0x7f800000, 0);
  P("fcvt.s.w -1", 0x68, 0, 0, 0xffffffff, 0);
  P("fmin nan,1", 0x14, 0, 0, 0x7fc00000, 0x3f800000);
  P("fmin -0,+0", 0x14, 0, 0, 0x80000000, 0);
  P("fmax -0,+0", 0x14, 1, 0, 0x80000000, 0);
  P("feq nan", 0x50, 2, 0, 0x7fc00000, 0x7fc00000);
  P("fclass", 0x70, 1, 0, 0x00000001, 0);
  P("fadd rm=7", 0, 7, 0, 0x3f800001, 0x33800000);
  P("fadd rm=5", 0, 5, 0, 0x3f800001, 0x33800000);
  P("fadd rm=1 ", 0, 1, 0, 0x3f800001, 0x33800000);
  P("fadd tiny rm=2", 0, 2, 0, 0x00000001, 0x80000000);
  P("fadd 1+(-1) rm=2", 0, 2, 0, 0x3f800000, 0xbf800000);
  P("fadd 1+(-1) rm=0", 0, 0, 0, 0x3f800000, 0xbf800000);
  P("fsub 1-1 rm=2", 4, 2, 0, 0x3f800000, 0x3f800000);
  P("fsgnj", 0x10, 0, 0, 0x7fc00000, 0x80000000);
  P("fcvt.w.s rm=7 2.5", 0x60, 7, 0, 0x40200000, 0);
  P("fcvt.w.s rm=5 2.5", 0x60, 5, 0, 0x40200000, 0);
  P("fsqrt rm=7", 0x2c, 7, 0, 0x40000000, 0);
}
