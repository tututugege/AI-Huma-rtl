// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (LR/SC reservation updates of the write-back, lp_emit_load_wb)
`default_nettype none

// reservation: P1 commit clears spec -> direct LR arms -> SC clears -> WBP LR arms (all before pf_any and mispred)
module lp_rsv
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic             clk,
  input  logic             rst_n,
  input  logic [NCM-1:0]   cm_valid,
  input  logic [ROBW-1:0]  cm_rob_idx [NCM],
  input  logic [NCM-1:0]   cm_rob_flag,
  input  logic             lr1_v,
  input  logic [31:0]      lr1_addr,
  input  logic [ROBW-1:0]  lr1_rob_idx,
  input  logic             lr1_rob_flag,
  input  logic             sc_clr,
  input  logic             lr2_v,
  input  logic [31:0]      lr2_addr,
  input  logic [ROBW-1:0]  lr2_rob_idx,
  input  logic             lr2_rob_flag,
  input  logic             pf_any,
  input  logic             mispred,
  input  logic [ROBW-1:0]  dec_rob_idx,
  input  logic             dec_rob_flag,
  output logic             rsv_valid_q,
  output logic [31:0]      rsv_addr_q
);

  logic [ROBW-1:0] rsv_rob_idx_q;
  logic            rsv_rob_flag_q;
  logic            rsv_spec_q;
  logic            cm_hit;
  logic            rv_i, rrf_i, rs_i;
  logic [31:0]     ra_i;
  logic [ROBW-1:0] rri_i;

  always_comb begin
    cm_hit = 1'b0;
    for (int i = 0; i < NCM; i++) begin
      if (cm_valid[i] && cm_rob_idx[i] == rsv_rob_idx_q && cm_rob_flag[i] == rsv_rob_flag_q)
        cm_hit = 1'b1;
    end
    rv_i  = rsv_valid_q;
    ra_i  = rsv_addr_q;
    rri_i = rsv_rob_idx_q;
    rrf_i = rsv_rob_flag_q;
    rs_i  = rsv_spec_q && !cm_hit;
    if (lr1_v) begin
      rv_i  = 1'b1;
      ra_i  = lr1_addr;
      rri_i = lr1_rob_idx;
      rrf_i = lr1_rob_flag;
      rs_i  = 1'b1;
    end
    if (sc_clr) begin
      rv_i = 1'b0;
      rs_i = 1'b0;
    end
    if (lr2_v) begin
      rv_i  = 1'b1;
      ra_i  = lr2_addr;
      rri_i = lr2_rob_idx;
      rrf_i = lr2_rob_flag;
      rs_i  = 1'b1;
    end
  end
  lsu_lrsc u_rsv (
    .clk(clk), .rst_n(rst_n),
    .valid_q(rsv_valid_q), .addr_q(rsv_addr_q),
    .rob_idx_q(rsv_rob_idx_q), .rob_flag_q(rsv_rob_flag_q), .spec_q(rsv_spec_q),
    .valid_i(rv_i), .addr_i(ra_i), .rob_idx_i(rri_i), .rob_flag_i(rrf_i), .spec_i(rs_i),
    .pf_clear(pf_any), .mispred(mispred), .dec_rob_idx(dec_rob_idx), .dec_rob_flag(dec_rob_flag)
  );

endmodule

`default_nettype wire
