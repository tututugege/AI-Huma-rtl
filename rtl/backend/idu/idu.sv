// Ref: back-end/Idu.cpp  class Idu  (comb_branch / comb_decode / comb_fire / seq)   reference model commit 2f31e8d
`default_nettype none

// Idu top: port adaptation only. Decode lanes, branch tag allocation, in-flight-branch state and the
// dec_bcast broadcast are separate sub-modules (see docs/modules/idu.md).
module idu import ttg_cfg_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  // PreIduQueue issue group
  input  logic [DECODE_WIDTH-1:0] pre_issue_entries_valid,
  input  logic [31:0]                 pre_issue_entries_inst [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0] pre_issue_entries_page_fault_inst,
  input  logic [FTQ_IDX_WIDTH-1:0]    pre_issue_entries_ftq_idx [DECODE_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] pre_issue_entries_ftq_offset [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0] pre_issue_entries_ftq_is_last,
  // rename ready, ROB flush
  input  logic                        ren2dec_ready,
  input  logic                        rob_bcast_flush,
  // EXU branch resolution
  input  logic                        exu2id_mispred,
  input  logic [31:0]                 exu2id_redirect_pc,
  input  logic [ROB_IDX_WIDTH-1:0]    exu2id_redirect_rob_idx,
  input  logic [BR_TAG_WIDTH-1:0]     exu2id_br_id,
  input  logic [FTQ_IDX_WIDTH-1:0]    exu2id_ftq_idx,
  input  logic [31:0]                 exu2id_br_pc,
  input  logic [BR_MASK_WIDTH-1:0]    exu2id_clear_mask,
  // dec2ren
  output logic [DECODE_WIDTH-1:0] dec2ren_valid,
  output logic [31:0]                 dec2ren_uop_diag_val [DECODE_WIDTH],
  output logic [AREG_IDX_WIDTH-1:0]   dec2ren_uop_dest_areg [DECODE_WIDTH],
  output logic [AREG_IDX_WIDTH-1:0]   dec2ren_uop_src1_areg [DECODE_WIDTH],
  output logic [AREG_IDX_WIDTH-1:0]   dec2ren_uop_src2_areg [DECODE_WIDTH],
  output logic [FTQ_IDX_WIDTH-1:0]    dec2ren_uop_ftq_idx [DECODE_WIDTH],
  output logic [FTQ_OFFSET_WIDTH-1:0] dec2ren_uop_ftq_offset [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_ftq_is_last,
  output logic [4:0]                  dec2ren_uop_type [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_dest_en,
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_src1_en,
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_src2_en,
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_is_atomic,
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_src1_is_pc,
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_src2_is_imm,
  output logic [2:0]                  dec2ren_uop_func3 [DECODE_WIDTH],
  output logic [6:0]                  dec2ren_uop_func7 [DECODE_WIDTH],
  output logic [31:0]                 dec2ren_uop_imm [DECODE_WIDTH],
  output logic [BR_TAG_WIDTH-1:0]     dec2ren_uop_br_id [DECODE_WIDTH],
  output logic [BR_MASK_WIDTH-1:0]    dec2ren_uop_br_mask [DECODE_WIDTH],
  output logic [CSR_IDX_WIDTH-1:0]    dec2ren_uop_csr_idx [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_page_fault_inst,
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_illegal_inst,
  // dec_bcast
  output logic                        dec_bcast_mispred,
  output logic [BR_MASK_WIDTH-1:0]    dec_bcast_br_mask,
  output logic [BR_TAG_WIDTH-1:0]     dec_bcast_br_id,
  output logic [ROB_IDX_WIDTH-1:0]    dec_bcast_redirect_rob_idx,
  output logic [BR_MASK_WIDTH-1:0]    dec_bcast_clear_mask,
  // idu_consume
  output logic [DECODE_WIDTH-1:0] idu_consume_fire,
  // br_latch (read directly by BackTop / PreIduQueue)
  output logic                        br_latch_mispred,
  output logic [31:0]                 br_latch_redirect_pc,
  output logic [FTQ_IDX_WIDTH-1:0]    br_latch_ftq_idx,
  output logic [31:0]                 br_latch_br_pc
);

  // ---- internal nets ----
  logic [DECODE_WIDTH-1:0] entry_valid_vec, lane_is_branch, lane_valid, consume_fire_vec;
  logic [BR_MASK_WIDTH-1:0] alloc_oh [MAX_BR_PER_CYCLE];
  logic [BR_MASK_WIDTH-1:0] lane_tag_oh [DECODE_WIDTH], lane_cp_mask [DECODE_WIDTH];
  logic [BR_MASK_WIDTH-1:0] lane_commit_oh [DECODE_WIDTH], commit_all_oh, lane_br_mask [DECODE_WIDTH];
  logic [BR_TAG_WIDTH-1:0]  lane_br_id [DECODE_WIDTH];
  logic [BR_MASK_WIDTH-1:0] tag_free, now_br_mask, mispred_ckpt;
  logic [BR_MASK_WIDTH-1:0] latch_clear_mask, clear_eff, base_mask;
  logic                     latch_mispred;
  logic [BR_TAG_WIDTH-1:0]  latch_br_id;
  logic [ROB_IDX_WIDTH-1:0] latch_rob_idx;

  // tag 0 means "no branch"; its clear bit never affects tag state (reference loops start at tag 1)
  always_comb begin
    clear_eff = latch_clear_mask & ~BR_MASK_WIDTH'(1);
    base_mask = now_br_mask & ~latch_clear_mask;          // Ref: running_mask = now_br_mask & ~clear
  end

  // ---- decode lanes ----
  for (genvar i = 0; i < DECODE_WIDTH; i++) begin : g_lane
    assign entry_valid_vec[i] = pre_issue_entries_valid[i];
    assign dec2ren_valid[i]   = lane_valid[i];
    assign dec2ren_uop_br_id[i]   = lane_br_id[i];
    assign dec2ren_uop_br_mask[i] = lane_br_mask[i];
    assign idu_consume_fire[i]    = consume_fire_vec[i];

    idu_decoder u_dec (
      .entry_valid(pre_issue_entries_valid[i]), .entry_inst(pre_issue_entries_inst[i]),
      .entry_page_fault_inst(pre_issue_entries_page_fault_inst[i]), .entry_ftq_idx(pre_issue_entries_ftq_idx[i]),
      .entry_ftq_offset(pre_issue_entries_ftq_offset[i]), .entry_ftq_is_last(pre_issue_entries_ftq_is_last[i]),
      .uop_diag_val(dec2ren_uop_diag_val[i]), .uop_dest_areg(dec2ren_uop_dest_areg[i]),
      .uop_src1_areg(dec2ren_uop_src1_areg[i]), .uop_src2_areg(dec2ren_uop_src2_areg[i]),
      .uop_ftq_idx(dec2ren_uop_ftq_idx[i]), .uop_ftq_offset(dec2ren_uop_ftq_offset[i]),
      .uop_ftq_is_last(dec2ren_uop_ftq_is_last[i]), .uop_type(dec2ren_uop_type[i]),
      .uop_dest_en(dec2ren_uop_dest_en[i]), .uop_src1_en(dec2ren_uop_src1_en[i]),
      .uop_src2_en(dec2ren_uop_src2_en[i]), .uop_is_atomic(dec2ren_uop_is_atomic[i]),
      .uop_src1_is_pc(dec2ren_uop_src1_is_pc[i]), .uop_src2_is_imm(dec2ren_uop_src2_is_imm[i]),
      .uop_func3(dec2ren_uop_func3[i]), .uop_func7(dec2ren_uop_func7[i]), .uop_imm(dec2ren_uop_imm[i]),
      .uop_csr_idx(dec2ren_uop_csr_idx[i]), .uop_page_fault_inst(dec2ren_uop_page_fault_inst[i]),
      .uop_illegal_inst(dec2ren_uop_illegal_inst[i]),
      .is_branch(lane_is_branch[i])
    );
  end

  // ---- branch tagging of the group ----
  idu_br_alloc #(.NTAG(BR_MASK_WIDTH), .NALLOC(MAX_BR_PER_CYCLE)) u_alloc (
    .tag_free(tag_free), .alloc_oh(alloc_oh)
  );

  idu_br_group #(.DW(DECODE_WIDTH), .NTAG(BR_MASK_WIDTH), .NALLOC(MAX_BR_PER_CYCLE)) u_group (
    .entry_valid(entry_valid_vec), .is_branch(lane_is_branch), .alloc_oh(alloc_oh), .base_mask(base_mask),
    .lane_valid(lane_valid), .lane_br_id(lane_br_id), .lane_br_mask(lane_br_mask), .lane_tag_oh(lane_tag_oh),
    .lane_cp_mask(lane_cp_mask)
  );

  idu_fire_ctl #(.DW(DECODE_WIDTH), .NTAG(BR_MASK_WIDTH)) u_fire (
    .lane_valid(lane_valid), .ren_ready(ren2dec_ready), .rob_flush(rob_bcast_flush), .latch_mispred(latch_mispred),
    .lane_tag_oh(lane_tag_oh), .consume_fire(consume_fire_vec), .lane_commit_oh(lane_commit_oh),
    .commit_all_oh(commit_all_oh)
  );

  // ---- branch state ----
  idu_br_latch u_latch (
    .clk(clk), .rst_n(rst_n), .rob_flush(rob_bcast_flush), .exu_mispred(exu2id_mispred),
    .exu_redirect_pc(exu2id_redirect_pc), .exu_redirect_rob_idx(exu2id_redirect_rob_idx),
    .exu_br_id(exu2id_br_id), .exu_ftq_idx(exu2id_ftq_idx), .exu_br_pc(exu2id_br_pc),
    .exu_clear_mask(exu2id_clear_mask),
    .mispred(latch_mispred), .redirect_pc(br_latch_redirect_pc), .redirect_rob_idx(latch_rob_idx),
    .br_id(latch_br_id), .ftq_idx(br_latch_ftq_idx), .br_pc(br_latch_br_pc), .clear_mask(latch_clear_mask)
  );

  idu_br_state #(.NTAG(BR_MASK_WIDTH)) u_state (
    .clk(clk), .rst_n(rst_n), .rob_flush(rob_bcast_flush), .latch_mispred(latch_mispred), .clear_mask(clear_eff),
    .mispred_ckpt(mispred_ckpt), .commit_all_oh(commit_all_oh), .tag_free(tag_free), .now_br_mask(now_br_mask)
  );

  idu_br_cp #(.DW(DECODE_WIDTH), .NTAG(BR_MASK_WIDTH)) u_cp (
    .clk(clk), .rst_n(rst_n), .clear_mask(clear_eff), .wr_tag_oh(lane_commit_oh),
    .wr_data(lane_cp_mask), .rd_br_id(latch_br_id), .rd_data(mispred_ckpt)
  );

  idu_bcast u_bcast (
    .latch_mispred(latch_mispred), .latch_redirect_rob_idx(latch_rob_idx),
    .latch_br_id(latch_br_id), .latch_clear_mask(latch_clear_mask), .mispred(dec_bcast_mispred),
    .br_mask(dec_bcast_br_mask), .br_id(dec_bcast_br_id), .redirect_rob_idx(dec_bcast_redirect_rob_idx),
    .clear_mask(dec_bcast_clear_mask)
  );

  // br_latch outputs
  assign br_latch_mispred          = latch_mispred;

endmodule

`default_nettype wire
