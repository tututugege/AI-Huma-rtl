// Drives isu_wb_gate with the stimulus on stdin (one cycle per line: flush, then ISSUE_WIDTH x "valid off") and prints port_ok.
// A port reserves when its pick is valid and port_ok, as the issue stage does (the grant of a pick that passes every gate).
#include "Visu_wb_gate.h"
#include <cstdio>
#ifndef NPORT
#define NPORT 12
#endif
int main() {
  Visu_wb_gate d; d.clk = 0; d.rst_n = 0; d.reserve = 0; d.flush_all = 0;
  for (int p = 0; p < NPORT; p++) d.off[p] = 1;
  for (int i = 0; i < 3; i++) { d.clk = 0; d.eval(); d.clk = 1; d.eval(); }
  d.rst_n = 1;
  int fl, v[NPORT], o[NPORT];
  while (scanf("%d", &fl) == 1) {
    for (int p = 0; p < NPORT; p++) scanf("%d %d", &v[p], &o[p]);
    d.clk = 0; d.flush_all = fl; d.reserve = 0;
    for (int p = 0; p < NPORT; p++) d.off[p] = o[p];
    d.eval();
    unsigned ok = d.port_ok, res = 0;
    for (int p = 0; p < NPORT; p++) if (v[p] && ((ok >> p) & 1)) res |= 1u << p;
    d.reserve = res; d.eval();
    printf("%u\n", ok);
    d.clk = 1; d.eval();
  }
}
