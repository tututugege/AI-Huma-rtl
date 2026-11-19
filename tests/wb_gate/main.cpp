// Drives isu_wb_gate (through wrap.sv) with the stimulus on stdin and prints its outputs. First line printed: the class tables
// ("TAB ncls off_0 .. off_{ncls-1} serve_0 .. serve_{NPORT-1}", serve_p = bit mask of the classes port p serves). Then one cycle per
// input line (flush, then NPORT x "valid class"): "port_ok cls_free_0 .. cls_free_{NPORT-1}". A port reserves when its pick is valid
// and port_ok, as the issue stage does (the grant of a pick that passes every gate).
#include "Vwb_gate_tw.h"
#include <cstdio>
#ifndef NPORT
#define NPORT 12
#endif
#ifndef NCLS
#define NCLS 11
#endif
int main() {
  Vwb_gate_tw d; d.clk = 0; d.rst_n = 0; d.reserve = 0; d.flush_all = 0;
  for (int p = 0; p < NPORT; p++) d.cls[p] = 0;
  for (int i = 0; i < 3; i++) { d.clk = 0; d.eval(); d.clk = 1; d.eval(); }
  d.rst_n = 1;
  printf("TAB %d", NCLS);
  for (int c = 0; c < NCLS; c++) printf(" %u", (unsigned)d.off_tab[c]);
  for (int p = 0; p < NPORT; p++) printf(" %u", (unsigned)d.serve_tab[p]);
  printf("\n");
  int fl, v[NPORT], k[NPORT];
  while (scanf("%d", &fl) == 1) {
    for (int p = 0; p < NPORT; p++) scanf("%d %d", &v[p], &k[p]);
    d.clk = 0; d.flush_all = fl; d.reserve = 0;
    for (int p = 0; p < NPORT; p++) d.cls[p] = k[p];
    d.eval();
    unsigned ok = d.port_ok, res = 0;
    for (int p = 0; p < NPORT; p++) if (v[p] && ((ok >> p) & 1)) res |= 1u << p;
    printf("%u", ok);
    for (int p = 0; p < NPORT; p++) printf(" %u", (unsigned)d.cls_free[p]);
    printf("\n");
    d.reserve = res; d.eval();
    d.clk = 1; d.eval();
  }
}
