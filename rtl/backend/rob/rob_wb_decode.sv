// Ref: back-end/Rob.cpp  class Rob  (comb_complete: per write-back port, which slot field is written how)
`default_nettype none

module rob_wb_decode
  import ttg_cfg_pkg::*;
  import rob_pkg::*;
(
  input  rob_wb_t    wb [ROB_WB_WIDTH],
  output rob_event_t wb_ev [ROB_WB_WIDTH]
);

  for (genvar p = 0; p < ROB_WB_WIDTH; p++) begin : g_port
    localparam bit IS_LD  = (p >= ROB_WB_LD_BASE)  && (p < ROB_WB_LD_BASE  + LSU_LOAD_WB_WIDTH);
    localparam bit IS_STA = (p >= ROB_WB_STA_BASE) && (p < ROB_WB_STA_BASE + LSU_STA_COUNT);
    assign wb_ev[p] = rob_make_event(wb[p], IS_LD, IS_STA, rob_port_cplt_bit(p));
  end

endmodule

`default_nettype wire
