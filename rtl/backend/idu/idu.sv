// Ref: back-end/Idu.cpp  class Idu  (comb_branch / comb_decode / comb_fire / seq)
`default_nettype none

// Idu top: pure combinational 8-wide decoder (idu_br_latch moved to back_top after EXP-068).
module idu import ttg_cfg_pkg::*; (
  // PreIduQueue issue group
  input  logic [DECODE_WIDTH-1:0]     pre_issue_entries_valid,
  input  logic [31:0]                 pre_issue_entries_inst [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0]     pre_issue_entries_page_fault_inst,
  input  logic [DECODE_WIDTH-1:0]     pre_issue_entries_pf_inst_hi,
  input  logic [FTQ_IDX_WIDTH-1:0]    pre_issue_entries_ftq_idx [DECODE_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] pre_issue_entries_ftq_offset [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0]     pre_issue_entries_ftq_is_last,
  // rename ready, ROB flush, mispredict broadcast (from back_top u_br_latch)
  input  logic                        ren2dec_ready,
  input  logic                        rob_bcast_flush,
  input  logic                        dec_bcast_mispred,
  // dec2ren
  output logic [DECODE_WIDTH-1:0]     dec2ren_valid,
  output logic [XLEN_BITS-1:0]        dec2ren_uop_diag_val [DECODE_WIDTH],
  output logic [AREG_IDX_WIDTH-1:0]   dec2ren_uop_dest_areg [DECODE_WIDTH],
  output logic [AREG_IDX_WIDTH-1:0]   dec2ren_uop_src1_areg [DECODE_WIDTH],
  output logic [AREG_IDX_WIDTH-1:0]   dec2ren_uop_src2_areg [DECODE_WIDTH],
  output logic [FTQ_IDX_WIDTH-1:0]    dec2ren_uop_ftq_idx [DECODE_WIDTH],
  output logic [FTQ_OFFSET_WIDTH-1:0] dec2ren_uop_ftq_offset [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0]     dec2ren_uop_ftq_is_last,
  output logic [4:0]                  dec2ren_uop_type [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0]     dec2ren_uop_dest_en,
  output logic [DECODE_WIDTH-1:0]     dec2ren_uop_src1_en,
  output logic [DECODE_WIDTH-1:0]     dec2ren_uop_src2_en,
  output logic [DECODE_WIDTH-1:0]     dec2ren_uop_is_atomic,
  output logic [DECODE_WIDTH-1:0]     dec2ren_uop_src1_is_pc,
  output logic [DECODE_WIDTH-1:0]     dec2ren_uop_src2_is_imm,
  output logic [DECODE_WIDTH-1:0]     dec2ren_uop_is_word,
  output logic [2:0]                  dec2ren_uop_func3 [DECODE_WIDTH],
  output logic [6:0]                  dec2ren_uop_func7 [DECODE_WIDTH],
  output logic [31:0]                 dec2ren_uop_imm [DECODE_WIDTH],
  output logic [CSR_IDX_WIDTH-1:0]    dec2ren_uop_csr_idx [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0]     dec2ren_uop_page_fault_inst,
  output logic [DECODE_WIDTH-1:0]     dec2ren_uop_pf_inst_hi,
  output logic [DECODE_WIDTH-1:0]     dec2ren_uop_illegal_inst,
  output logic [DECODE_WIDTH-1:0]     dec2ren_uop_dest_fp,
  output logic [DECODE_WIDTH-1:0]     dec2ren_uop_src1_fp,
  output logic [DECODE_WIDTH-1:0]     dec2ren_uop_src2_fp,
  output logic [DECODE_WIDTH-1:0]     dec2ren_uop_src3_en,
  output logic [AREG_IDX_WIDTH-1:0]   dec2ren_uop_src3_areg [DECODE_WIDTH],
  output logic [2:0]                  dec2ren_uop_fp_cls [DECODE_WIDTH],
  // idu_consume
  output logic [DECODE_WIDTH-1:0]     idu_consume_fire
);

  /* verilator lint_off UNUSEDSIGNAL */
  logic [DECODE_WIDTH-1:0] lane_is_branch;
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- decode lanes ----
  for (genvar i = 0; i < DECODE_WIDTH; i++) begin : g_lane
    assign dec2ren_valid[i]    = pre_issue_entries_valid[i];
    assign idu_consume_fire[i] = pre_issue_entries_valid[i] && ren2dec_ready && !rob_bcast_flush && !dec_bcast_mispred;

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

endmodule

`default_nettype wire
