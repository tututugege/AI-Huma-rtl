// Test wrapper of isu_wb_gate: the gate plus the class tables of isu_pkg (offset of every completion class, the classes each port serves),
// so the checker (check.py) needs no copy of them.
`default_nettype none
module wb_gate_tw
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   flush_all,
  input  logic [WB_CLS_W-1:0]    cls [ISSUE_WIDTH],
  input  logic [ISSUE_WIDTH-1:0] reserve,
  output logic [ISSUE_WIDTH-1:0] port_ok,
  output logic [WB_NCLS-1:0]     cls_free [ISSUE_WIDTH],
  output logic [7:0]             off_tab [WB_NCLS],
  output logic [WB_NCLS-1:0]     serve_tab [ISSUE_WIDTH]
);
  isu_wb_gate u_gate (.clk(clk), .rst_n(rst_n), .flush_all(flush_all), .cls(cls), .reserve(reserve), .port_ok(port_ok), .cls_free(cls_free));
  for (genvar c = 0; c < WB_NCLS; c++) begin : g_off
    assign off_tab[c] = 8'(wb_cls_off(c));
  end
  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_serve
    for (genvar c = 0; c < WB_NCLS; c++) begin : g_c
      assign serve_tab[p][c] = port_serves_cls(p, c);
    end
  end
endmodule
`default_nettype wire
