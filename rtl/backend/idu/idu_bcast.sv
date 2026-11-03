// Ref: back-end/Idu.cpp  class Idu::comb_branch
`default_nettype none

// Broadcast of the latched branch resolution (dec_bcast). The reference model only writes redirect_rob_idx when the
// latched branch mispredicted; otherwise dec_bcast keeps the value of the last cycle (the signal is never cleared),
// so the last driven value is kept in a register (stale-read dependency, see docs/modules/idu.md section 4).
module idu_bcast import ttg_cfg_pkg::*; (
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic                        latch_mispred,
  input  logic [ROB_IDX_WIDTH-1:0]    latch_redirect_rob_idx,
  input  logic [BR_TAG_WIDTH-1:0]     latch_br_id,
  input  logic [BR_MASK_WIDTH-1:0]    latch_clear_mask,
  output logic                        mispred,
  output logic [BR_MASK_WIDTH-1:0]    br_mask,
  output logic [BR_TAG_WIDTH-1:0]     br_id,
  output logic [ROB_IDX_WIDTH-1:0]    redirect_rob_idx,
  output logic [BR_MASK_WIDTH-1:0]    clear_mask
);

  logic [ROB_IDX_WIDTH-1:0] redirect_rob_idx_hold_q, redirect_rob_idx_hold_d;
  logic [BR_MASK_WIDTH-1:0] mispred_tag_oh;

  // Ref: Idu::comb_branch
  always_comb begin
    mispred_tag_oh          = BR_MASK_WIDTH'(1) << latch_br_id;
    mispred                 = latch_mispred;
    br_mask                 = mispred_tag_oh & {BR_MASK_WIDTH{latch_mispred}};
    br_id                   = latch_br_id & {BR_TAG_WIDTH{latch_mispred}};
    redirect_rob_idx        = latch_mispred ? latch_redirect_rob_idx : redirect_rob_idx_hold_q;
    clear_mask              = latch_clear_mask;
    redirect_rob_idx_hold_d = redirect_rob_idx;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) redirect_rob_idx_hold_q <= '0;
    else        redirect_rob_idx_hold_q <= redirect_rob_idx_hold_d;
  end

endmodule

`default_nettype wire
