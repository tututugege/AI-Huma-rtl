// Ref: back-end/Idu.cpp  class Idu  (comb_branch / comb_decode / comb_fire / seq)
`default_nettype none

// Idu top: 8-wide decode + 1-cycle branch-resolution latch & broadcast (9-bit rob_ptr age flush).
module idu import ttg_cfg_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  // PreIduQueue issue group
  input  logic [DECODE_WIDTH-1:0] pre_issue_entries_valid,
  input  logic [31:0]                 pre_issue_entries_inst [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0] pre_issue_entries_page_fault_inst,
  input  logic [DECODE_WIDTH-1:0] pre_issue_entries_pf_inst_hi,
  input  logic [FTQ_IDX_WIDTH-1:0]    pre_issue_entries_ftq_idx [DECODE_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] pre_issue_entries_ftq_offset [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0] pre_issue_entries_ftq_is_last,
  // rename ready, ROB flush
  input  logic                        ren2dec_ready,
  input  logic                        rob_bcast_flush,
  // EXU branch resolution
  input  logic                        exu2id_mispred,
  input  logic [XLEN_BITS-1:0]        exu2id_redirect_pc,
  input  logic [ROB_IDX_WIDTH-1:0]    exu2id_redirect_rob_idx,
  input  logic                        exu2id_redirect_rob_flag,
  input  logic [FTQ_IDX_WIDTH-1:0]    exu2id_ftq_idx,
  input  logic [FTQ_OFFSET_WIDTH-1:0] exu2id_ftq_offset,
  input  logic [XLEN_BITS-1:0]        exu2id_br_pc,
  input  logic                        exu2id_br_is_rvc,
  // dec2ren
  output logic [DECODE_WIDTH-1:0] dec2ren_valid,
  output logic [XLEN_BITS-1:0]        dec2ren_uop_diag_val [DECODE_WIDTH],
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
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_is_word,
  output logic [2:0]                  dec2ren_uop_func3 [DECODE_WIDTH],
  output logic [6:0]                  dec2ren_uop_func7 [DECODE_WIDTH],
  output logic [31:0]                 dec2ren_uop_imm [DECODE_WIDTH],
  output logic [CSR_IDX_WIDTH-1:0]    dec2ren_uop_csr_idx [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_page_fault_inst,
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_pf_inst_hi,
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_illegal_inst,
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_dest_fp,
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_src1_fp,
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_src2_fp,
  output logic [DECODE_WIDTH-1:0] dec2ren_uop_src3_en,
  output logic [AREG_IDX_WIDTH-1:0]   dec2ren_uop_src3_areg [DECODE_WIDTH],
  output logic [2:0]                  dec2ren_uop_fp_cls [DECODE_WIDTH],
  // dec_bcast
  output logic                        dec_bcast_mispred,
  output logic [ROB_IDX_WIDTH-1:0]    dec_bcast_redirect_rob_idx,
  output logic                        dec_bcast_redirect_rob_flag,
  // idu_consume
  output logic [DECODE_WIDTH-1:0] idu_consume_fire,
  // br_latch (read directly by BackTop / PreIduQueue)
  output logic                        br_latch_mispred,
  output logic [XLEN_BITS-1:0]        br_latch_redirect_pc,
  output logic [FTQ_IDX_WIDTH-1:0]    br_latch_ftq_idx,
  output logic [FTQ_OFFSET_WIDTH-1:0] br_latch_ftq_offset,
  output logic [XLEN_BITS-1:0]        br_latch_br_pc,
  output logic                        br_latch_is_rvc
);

  /* verilator lint_off UNUSEDSIGNAL */
  logic [DECODE_WIDTH-1:0] lane_is_branch;
  /* verilator lint_on UNUSEDSIGNAL */
  logic                     latch_mispred;
  logic [ROB_IDX_WIDTH-1:0] latch_rob_idx;
  logic                     latch_rob_flag;

  // ---- decode lanes ----
  for (genvar i = 0; i < DECODE_WIDTH; i++) begin : g_lane
    assign dec2ren_valid[i]    = pre_issue_entries_valid[i];
    assign idu_consume_fire[i] = pre_issue_entries_valid[i] && ren2dec_ready && !rob_bcast_flush && !latch_mispred;

    idu_decoder u_dec (
      .entry_valid(pre_issue_entries_valid[i]), .entry_inst(pre_issue_entries_inst[i]),
      .entry_page_fault_inst(pre_issue_entries_page_fault_inst[i]),
      .entry_pf_inst_hi(pre_issue_entries_pf_inst_hi[i]),
      .entry_ftq_idx(pre_issue_entries_ftq_idx[i]),
      .entry_ftq_offset(pre_issue_entries_ftq_offset[i]), .entry_ftq_is_last(pre_issue_entries_ftq_is_last[i]),
      .uop_diag_val(dec2ren_uop_diag_val[i]), .uop_dest_areg(dec2ren_uop_dest_areg[i]),
      .uop_src1_areg(dec2ren_uop_src1_areg[i]), .uop_src2_areg(dec2ren_uop_src2_areg[i]),
      .uop_ftq_idx(dec2ren_uop_ftq_idx[i]), .uop_ftq_offset(dec2ren_uop_ftq_offset[i]),
      .uop_ftq_is_last(dec2ren_uop_ftq_is_last[i]), .uop_type(dec2ren_uop_type[i]),
      .uop_dest_en(dec2ren_uop_dest_en[i]), .uop_src1_en(dec2ren_uop_src1_en[i]),
      .uop_src2_en(dec2ren_uop_src2_en[i]), .uop_is_atomic(dec2ren_uop_is_atomic[i]),
      .uop_src1_is_pc(dec2ren_uop_src1_is_pc[i]), .uop_src2_is_imm(dec2ren_uop_src2_is_imm[i]),
      .uop_is_word(dec2ren_uop_is_word[i]),
      .uop_func3(dec2ren_uop_func3[i]), .uop_func7(dec2ren_uop_func7[i]), .uop_imm(dec2ren_uop_imm[i]),
      .uop_csr_idx(dec2ren_uop_csr_idx[i]), .uop_page_fault_inst(dec2ren_uop_page_fault_inst[i]),
      .uop_pf_inst_hi(dec2ren_uop_pf_inst_hi[i]),
      .uop_illegal_inst(dec2ren_uop_illegal_inst[i]),
      .uop_dest_fp(dec2ren_uop_dest_fp[i]), .uop_src1_fp(dec2ren_uop_src1_fp[i]),
      .uop_src2_fp(dec2ren_uop_src2_fp[i]), .uop_src3_en(dec2ren_uop_src3_en[i]),
      .uop_src3_areg(dec2ren_uop_src3_areg[i]), .uop_fp_cls(dec2ren_uop_fp_cls[i]),
      .is_branch(lane_is_branch[i])
    );
  end

  // ---- branch resolution latch & broadcast ----
  idu_br_latch u_latch (
    .clk(clk), .rst_n(rst_n), .rob_flush(rob_bcast_flush), .exu_mispred(exu2id_mispred),
    .exu_redirect_pc(exu2id_redirect_pc),
    .exu_redirect_rob_idx(exu2id_redirect_rob_idx),
    .exu_redirect_rob_flag(exu2id_redirect_rob_flag),
    .exu_ftq_idx(exu2id_ftq_idx), .exu_ftq_offset(exu2id_ftq_offset),
    .exu_br_pc(exu2id_br_pc), .exu_br_is_rvc(exu2id_br_is_rvc),
    .mispred(latch_mispred), .redirect_pc(br_latch_redirect_pc),
    .redirect_rob_idx(latch_rob_idx), .redirect_rob_flag(latch_rob_flag),
    .ftq_idx(br_latch_ftq_idx), .ftq_offset(br_latch_ftq_offset),
    .br_pc(br_latch_br_pc), .br_is_rvc(br_latch_is_rvc)
  );

  idu_bcast u_bcast (
    .latch_mispred(latch_mispred),
    .latch_redirect_rob_idx(latch_rob_idx),
    .latch_redirect_rob_flag(latch_rob_flag),
    .mispred(dec_bcast_mispred),
    .redirect_rob_idx(dec_bcast_redirect_rob_idx),
    .redirect_rob_flag(dec_bcast_redirect_rob_flag)
  );

  assign br_latch_mispred = latch_mispred;

endmodule

`default_nettype wire
