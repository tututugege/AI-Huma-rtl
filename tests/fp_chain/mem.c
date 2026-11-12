// F/D loads and stores through the RTL LSU (flw / fsw): data in memory -> FP registers -> arithmetic -> memory -> integer
// loads / fmv.x.w, so the per-commit function-model check compares every value.  Includes store-to-load forwarding, a NaN-boxed
// load feeding fcvt.d.s / fadd.s, and an improperly boxed register feeding fadd.s (canonical NaN).  fld / fsd: S4b.
static float buf[16] __attribute__((aligned(16)));

static unsigned one(int seed) {
  unsigned *u = (unsigned *)buf;
  int i;
  for (i = 0; i < 16; i++) u[i] = 0x3f800000u + (unsigned)(seed * 977 + i * 131071) * 4093u;   // assorted floats / NaNs / infs
  int r0, r1, r2, r3, r4, r5;
  __asm__ volatile(
      "flw ft0, 0(%[p])\n flw ft1, 4(%[p])\n flw ft2, 8(%[p])\n"
      "fadd.s ft3, ft0, ft1\n fmul.s ft4, ft3, ft2\n fmadd.s ft5, ft0, ft1, ft2\n"
      "fsw ft3, 16(%[p])\n fsw ft4, 20(%[p])\n fsw ft5, 24(%[p])\n"
      "flw ft6, 16(%[p])\n flw ft7, 24(%[p])\n"          // forwarded from the stores just issued
      "fsub.s ft8, ft6, ft7\n fsw ft8, 28(%[p])\n"
      "lw %[r0], 16(%[p])\n lw %[r1], 20(%[p])\n lw %[r2], 24(%[p])\n lw %[r3], 28(%[p])\n"
      "fmv.x.w %[r4], ft6\n"
      "fcvt.d.s ft9, ft7\n fadd.d ft9, ft9, ft9\n fcvt.w.d %[r5], ft9, rtz\n"   // NaN-boxed single -> double
      "fcvt.d.w ft10, %[r4]\n fadd.s ft11, ft10, ft10\n fmv.x.w %[r4], ft11\n"   // improperly boxed operand: canonical NaN
      : [r0] "=&r"(r0), [r1] "=&r"(r1), [r2] "=&r"(r2), [r3] "=&r"(r3), [r4] "=&r"(r4), [r5] "=&r"(r5)
      : [p] "r"(buf)
      : "memory", "ft0", "ft1", "ft2", "ft3", "ft4", "ft5", "ft6", "ft7", "ft8", "ft9", "ft10", "ft11");
  return (unsigned)r0 + (unsigned)r1 * 3u + (unsigned)r2 * 5u + (unsigned)r3 * 7u + (unsigned)r4 * 11u + (unsigned)r5 * 13u;
}

int main(void) {
  unsigned s = 0;
  __asm__ volatile("li t0, 0x6000\n csrs mstatus, t0" ::: "t0");   // mstatus.FS = Dirty
  for (int i = 0; i < 60; i++) s ^= one(i);
  return s == 0xFFFFFFFFu;
}
