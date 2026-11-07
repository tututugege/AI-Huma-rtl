// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (LR/SC reservation updates of the write-back, lp_emit_load_wb)
`default_nettype none

// reservation: direct LR arms -> SC clears -> WBP LR arms (all before the page-fault clear and the mispredict clear)
module lp_rsv
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic             clk,
  input  logic             rst_n,
  input  logic             lr1_v,
  input  logic [31:0]      lr1_addr,
  input  logic [BRW-1:0]   lr1_br,
  input  logic             sc_clr,
  input  logic             lr2_v,
  input  logic [31:0]      lr2_addr,
  input  logic [BRW-1:0]   lr2_br,
  input  logic             pf_any,
  input  logic             mispred,
  input  logic [BRW-1:0]   dec_br_mask,
  input  logic [BRW-1:0]   clear_mask,
  output logic             rsv_valid_q,
  output logic [31:0]      rsv_addr_q
);

  logic [BRW-1:0]  rsv_br_q;
  logic            rv_i;
  logic [31:0]     ra_i;
  logic [BRW-1:0]  rb_i;
  always_comb begin
    rv_i = rsv_valid_q;
    ra_i = rsv_addr_q;
    rb_i = rsv_br_q;
    if (lr1_v) begin
      rv_i = 1'b1;
      ra_i = lr1_addr;
      rb_i = lr1_br;
    end
    if (sc_clr) rv_i = 1'b0;
    if (lr2_v) begin
      rv_i = 1'b1;
      ra_i = lr2_addr;
      rb_i = lr2_br;
    end
  end
  lsu_lrsc u_rsv (.clk(clk), .rst_n(rst_n), .valid_q(rsv_valid_q), .addr_q(rsv_addr_q), .br_q(rsv_br_q),
                  .valid_i(rv_i), .addr_i(ra_i), .br_i(rb_i), .pf_clear(pf_any), .mispred(mispred),
                  .dec_br_mask(dec_br_mask), .clear_mask(clear_mask));

endmodule

`default_nettype wire
