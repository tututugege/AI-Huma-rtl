// Ref: back-end/Idu.cpp  class Idu (br_latch / br_latch_1, Idu::comb_fire first lines, Idu::seq)
`default_nettype none

// One-cycle latch of the branch resolution from EXU. Only mispred and clear_mask steer state, so only those are
// cleared by a ROB flush; the payload (pc, rob idx, tag, ftq idx) is only read under mispred and is captured as is.
module idu_br_latch import ttg_cfg_pkg::*; (
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic                        rob_flush,
  input  logic                        exu_mispred,
  input  logic [XLEN_BITS-1:0]                 exu_redirect_pc,
  input  logic [ROB_IDX_WIDTH-1:0]    exu_redirect_rob_idx,
  input  logic [BR_TAG_WIDTH-1:0]     exu_br_id,
  input  logic [FTQ_IDX_WIDTH-1:0]    exu_ftq_idx,
  input  logic [XLEN_BITS-1:0]                 exu_br_pc,
  input  logic [BR_MASK_WIDTH-1:0]    exu_clear_mask,
  output logic                        mispred,
  output logic [XLEN_BITS-1:0]                 redirect_pc,
  output logic [ROB_IDX_WIDTH-1:0]    redirect_rob_idx,
  output logic [BR_TAG_WIDTH-1:0]     br_id,
  output logic [FTQ_IDX_WIDTH-1:0]    ftq_idx,
  output logic [XLEN_BITS-1:0]                 br_pc,
  output logic [BR_MASK_WIDTH-1:0]    clear_mask
);

  logic                        mispred_q, mispred_d;
  logic [BR_MASK_WIDTH-1:0]    clear_mask_q, clear_mask_d;
  logic [XLEN_BITS-1:0]                 redirect_pc_q;
  logic [ROB_IDX_WIDTH-1:0]    redirect_rob_idx_q;
  logic [BR_TAG_WIDTH-1:0]     br_id_q;
  logic [FTQ_IDX_WIDTH-1:0]    ftq_idx_q;
  logic [XLEN_BITS-1:0]                 br_pc_q;

  // Ref: Idu::comb_fire  (flush -> br_latch_1 = {})
  always_comb begin
    mispred_d    = exu_mispred & ~rob_flush;
    clear_mask_d = exu_clear_mask & {BR_MASK_WIDTH{~rob_flush}};
  end

  // Ref: Idu::seq
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mispred_q          <= 1'b0;
      clear_mask_q       <= '0;
      redirect_pc_q      <= '0;
      redirect_rob_idx_q <= '0;
      br_id_q            <= '0;
      ftq_idx_q          <= '0;
      br_pc_q            <= '0;
    end else begin
      mispred_q          <= mispred_d;
      clear_mask_q       <= clear_mask_d;
      redirect_pc_q      <= exu_redirect_pc;
      redirect_rob_idx_q <= exu_redirect_rob_idx;
      br_id_q            <= exu_br_id;
      ftq_idx_q          <= exu_ftq_idx;
      br_pc_q            <= exu_br_pc;
    end
  end

  assign mispred          = mispred_q;
  assign clear_mask       = clear_mask_q;
  assign redirect_pc      = redirect_pc_q;
  assign redirect_rob_idx = redirect_rob_idx_q;
  assign br_id            = br_id_q;
  assign ftq_idx          = ftq_idx_q;
  assign br_pc            = br_pc_q;

endmodule

`default_nettype wire
