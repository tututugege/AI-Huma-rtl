// Drives isu_fp_gate with the stimulus on stdin (one cycle per line: flush, then NC x "valid fpw lat") and prints gate_ok.
#include "Visu_fp_gate.h"
#include <cstdio>
int main() {
  Visu_fp_gate d; d.clk = 0; d.rst_n = 0; d.cand_valid = 0; d.cand_fpw = 0; d.flush_all = 0;
  for (int i = 0; i < 3; i++) { d.clk = 0; d.eval(); d.clk = 1; d.eval(); }
  d.rst_n = 1;
  int fl, v[5], f[5], l[5];
  while (scanf("%d", &fl) == 1) {
    for (int k = 0; k < 5; k++) scanf("%d %d %d", &v[k], &f[k], &l[k]);
    d.clk = 0; d.flush_all = fl; d.cand_valid = 0; d.cand_fpw = 0;
    for (int k = 0; k < 5; k++) { d.cand_valid |= v[k] << k; d.cand_fpw |= f[k] << k; d.cand_lat[k] = l[k]; }
    d.eval();
    printf("%d\n", (int)d.gate_ok);
    d.clk = 1; d.eval();
  }
}
