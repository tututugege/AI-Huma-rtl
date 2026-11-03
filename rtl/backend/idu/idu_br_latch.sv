// Ref: back-end/Idu.cpp  class Idu (br_latch / br_latch_1, Idu::comb_fire first lines, Idu::seq)
`default_nettype none

// One-cycle latch of the branch resolution from EXU. A ROB flush clears it (br_latch_1 = {}).
module idu_br_latch import ttg_cfg_pkg::*; (
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic                        rob_flush,
  input  logic                        exu_mispred,
  input  logic [31:0]                 exu_redirect_pc,
  input  logic [ROB_IDX_WIDTH-1:0]    exu_redirect_rob_idx,
  input  logic [BR_TAG_WIDTH-1:0]     exu_br_id,
  input  logic [FTQ_IDX_WIDTH-1:0]    exu_ftq_idx,
  input  logic [BR_MASK_WIDTH-1:0]    exu_clear_mask,
  output logic                        mispred,
  output logic [31:0]                 redirect_pc,
  output logic [ROB_IDX_WIDTH-1:0]    redirect_rob_idx,
  output logic [BR_TAG_WIDTH-1:0]     br_id,
  output logic [FTQ_IDX_WIDTH-1:0]    ftq_idx,
  output logic [BR_MASK_WIDTH-1:0]    clear_mask
);

  logic                        mispred_q, mispred_d;
  logic [31:0]                 redirect_pc_q, redirect_pc_d;
  logic [ROB_IDX_WIDTH-1:0]    redirect_rob_idx_q, redirect_rob_idx_d;
  logic [BR_TAG_WIDTH-1:0]     br_id_q, br_id_d;
  logic [FTQ_IDX_WIDTH-1:0]    ftq_idx_q, ftq_idx_d;
  logic [BR_MASK_WIDTH-1:0]    clear_mask_q, clear_mask_d;

  // Ref: Idu::comb_fire  (if (!flush) br_latch_1 = *exu2id; else br_latch_1 = {})
  always_comb begin
    mispred_d          = exu_mispred          & ~rob_flush;
    redirect_pc_d      = exu_redirect_pc      & {32{~rob_flush}};
    redirect_rob_idx_d = exu_redirect_rob_idx & {ROB_IDX_WIDTH{~rob_flush}};
    br_id_d            = exu_br_id            & {BR_TAG_WIDTH{~rob_flush}};
    ftq_idx_d          = exu_ftq_idx          & {FTQ_IDX_WIDTH{~rob_flush}};
    clear_mask_d       = exu_clear_mask       & {BR_MASK_WIDTH{~rob_flush}};
  end

  // Ref: Idu::seq
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mispred_q          <= 1'b0;
      redirect_pc_q      <= '0;
      redirect_rob_idx_q <= '0;
      br_id_q            <= '0;
      ftq_idx_q          <= '0;
      clear_mask_q       <= '0;
    end else begin
      mispred_q          <= mispred_d;
      redirect_pc_q      <= redirect_pc_d;
      redirect_rob_idx_q <= redirect_rob_idx_d;
      br_id_q            <= br_id_d;
      ftq_idx_q          <= ftq_idx_d;
      clear_mask_q       <= clear_mask_d;
    end
  end

  assign mispred          = mispred_q;
  assign redirect_pc      = redirect_pc_q;
  assign redirect_rob_idx = redirect_rob_idx_q;
  assign br_id            = br_id_q;
  assign ftq_idx          = ftq_idx_q;
  assign clear_mask       = clear_mask_q;

endmodule

`default_nettype wire
