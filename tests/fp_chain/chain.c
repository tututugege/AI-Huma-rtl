// F/D value check through the RTL core: dependent and independent FP chains whose results are moved to integer registers
// (fcvt.w.* / fmv.x.w / feq / flt / fclass), so the per-commit function-model check (SOC_TB_FM) compares them.  No FP loads or
// stores (the LSU part is S4) and no fcsr access (S5): operands come from integer registers via fcvt.*.w.
static unsigned chain_d(int a, int b) {
  int x, y, z, w;
  __asm__ volatile(
      "fcvt.d.w ft0, %[a]\n fcvt.d.w ft1, %[b]\n"
      "fmul.d ft2, ft0, ft1\n fadd.d ft3, ft2, ft0\n fmadd.d ft4, ft0, ft1, ft3\n fsub.d ft5, ft4, ft2\n"
      "fdiv.d ft6, ft5, ft1\n fsqrt.d ft7, ft0\n fmin.d ft8, ft6, ft7\n fmax.d ft9, ft6, ft7\n fsgnjn.d ft10, ft9, ft8\n"
      "fnmsub.d ft11, ft0, ft1, ft2\n fmsub.d fa0, ft7, ft7, ft0\n fnmadd.d fa1, ft6, ft8, ft9\n"
      "feq.d %[x], ft0, ft0\n flt.d t1, ft8, ft9\n fcvt.w.d %[y], ft10, rtz\n fcvt.w.d %[z], ft4, rne\n"
      "fcvt.wu.d t2, ft11, rdn\n fcvt.w.d t3, fa0, rup\n fcvt.w.d %[w], fa1, rmm\n fclass.d t4, ft8\n"
      "add %[x], %[x], t1\n add %[z], %[z], t2\n add %[w], %[w], t3\n xor %[w], %[w], t4\n"
      : [x] "=&r"(x), [y] "=&r"(y), [z] "=&r"(z), [w] "=&r"(w)
      : [a] "r"(a), [b] "r"(b)
      : "t1", "t2", "t3", "t4", "ft0", "ft1", "ft2", "ft3", "ft4", "ft5", "ft6", "ft7", "ft8", "ft9", "ft10", "ft11", "fa0", "fa1");
  return (unsigned)x * 3u + (unsigned)y * 5u + (unsigned)z + (unsigned)w * 7u;
}

static unsigned chain_s(int a, int b) {
  int x, y, z;
  __asm__ volatile(
      "fcvt.s.w ft0, %[a]\n fcvt.s.w ft1, %[b]\n"
      "fadd.s ft2, ft0, ft1\n fmul.s ft3, ft2, ft1\n fmadd.s ft4, ft0, ft3, ft2\n fdiv.s ft5, ft4, ft1\n fsqrt.s ft6, ft0\n"
      "fsgnjx.s ft7, ft5, ft6\n fmin.s ft8, ft5, ft6\n fcvt.d.s ft9, ft8\n fcvt.s.d ft10, ft9\n fadd.d ft9, ft9, ft9\n"
      "fmv.x.w %[x], ft7\n fcvt.w.s %[y], ft5, rtz\n fle.s t1, ft6, ft5\n fclass.s t2, ft10\n fcvt.wu.s %[z], ft4, rne\n"
      "fmv.w.x ft11, %[x]\n fadd.s ft11, ft11, ft11\n fmv.x.w t3, ft11\n"
      "add %[y], %[y], t1\n xor %[y], %[y], t2\n add %[z], %[z], t3\n"
      : [x] "=&r"(x), [y] "=&r"(y), [z] "=&r"(z)
      : [a] "r"(a), [b] "r"(b)
      : "t1", "t2", "t3", "ft0", "ft1", "ft2", "ft3", "ft4", "ft5", "ft6", "ft7", "ft8", "ft9", "ft10", "ft11");
  return (unsigned)x + (unsigned)y * 5u + (unsigned)z * 9u;
}

int main(void) {
  unsigned s = 0;
  __asm__ volatile("li t0, 0x6000\n csrs mstatus, t0" ::: "t0");   // mstatus.FS = Dirty (FP instructions enabled)
  for (int i = 1; i <= 40; i++) s += chain_d(i * 7 + 3, i + 2) ^ chain_s(i * 5 + 1, i + 3);
  return s == 0xFFFFFFFFu;   // (the value is irrelevant: every integer result was compared)
}
