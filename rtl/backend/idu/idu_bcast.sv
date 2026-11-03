// Ref: back-end/Idu.cpp  class Idu::comb_branch
`default_nettype none

// Broadcast of the latched branch resolution (dec_bcast). Consumers read br_mask / br_id / redirect_rob_idx only
// under mispred, so those pass straight through; clear_mask is always consumed.
module idu_bcast import ttg_cfg_pkg::*; (
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

  // Ref: Idu::comb_branch
  always_comb begin
    mispred          = latch_mispred;
    br_mask          = BR_MASK_WIDTH'(1) << latch_br_id;
    br_id            = latch_br_id;
    redirect_rob_idx = latch_redirect_rob_idx;
    clear_mask       = latch_clear_mask;
  end

endmodule

`default_nettype wire
