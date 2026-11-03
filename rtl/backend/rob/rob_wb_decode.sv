// Ref: back-end/Rob.cpp  class Rob  (comb_complete: per write-back port, which slot field is written how)
`default_nettype none

module rob_wb_decode
  import ttg_cfg_pkg::*;
  import rob_pkg::*;
(
  input  rob_wb_t    wb [ISSUE_WIDTH],
  output rob_event_t wb_ev [ISSUE_WIDTH]
);

  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_port
    localparam bit IS_LD  = (p >= IQ_LD_PORT_BASE) && (p < IQ_LD_PORT_BASE + LSU_LDU_COUNT);
    localparam bit IS_STA = (p >= IQ_STA_PORT_BASE) && (p < IQ_STA_PORT_BASE + LSU_STA_COUNT);
    assign wb_ev[p] = rob_make_event(wb[p], IS_LD, IS_STA, rob_port_cplt_bit(p));
  end

endmodule

`default_nettype wire
