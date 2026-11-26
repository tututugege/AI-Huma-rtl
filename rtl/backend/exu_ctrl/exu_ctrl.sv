// Ref: back-end/Exu/Exu.cpp  class Exu  (control and arbitration; the functional units themselves are outside)
`default_nettype none
// Exu control: FU input slots, issue-port write-back arbitration, bypass, ready feedback, flush/kill/clear handling and
// the interfaces to Csr / Lsu / Rob / Prf / Isu / Idu. The FUs are inputs (fu_*) and outputs (exu2fu_*).
module exu_ctrl
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
  import fp_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic rob_bcast_flush,
  input  logic dec_bcast_mispred,
  input  logic [ROB_IDX_WIDTH-1:0] dec_bcast_redirect_rob_idx,
  input  logic dec_bcast_redirect_rob_flag,
  input  logic [XLEN_BITS-1:0] csr2exe_rdata,
  input  logic [ISSUE_WIDTH-1:0] prf2exe_valid,
  input  xc_inst_t prf2exe_uop [ISSUE_WIDTH],
  input  logic [CSR_IDX_WIDTH-1:0] prf2exe_csr_idx,
  input  logic [XLEN_BITS-1:0] fu_alu_result [ALU_NUM],
  input  logic [XLEN_BITS-1:0] fu_agu_result [LSU_AGU_COUNT],
  input  logic [XLEN_BITS-1:0] fu_sdu_result [LSU_SDU_COUNT],
  input  logic [XLEN_BITS-1:0] fu_bru_diag_val [BRU_NUM],
  input  logic fu_bru_mispred [BRU_NUM],
  input  logic fu_bru_br_taken [BRU_NUM],
  input  logic [N_MC-1:0] fu_mc_ready,
  input  logic            div_wb_next,
  input  logic [N_MC-1:0] fu_mc_complete,
  input  logic [XLEN_BITS-1:0] fu_mc_result [N_MC],
  input  logic [PRF_IDX_WIDTH-1:0] fu_mc_dest_preg [N_MC],
  input  logic [N_MC-1:0] fu_mc_dest_en,
  input  logic [ROB_IDX_WIDTH-1:0] fu_mc_rob_idx [N_MC],
  input  logic [N_MC-1:0] fu_mc_rob_flag,
  input  logic [N_FPU-1:0] fu_fp_ready,
  input  logic [N_FPU-1:0] fu_fp_complete,
  input  logic [XLEN_BITS-1:0] fu_fp_result [N_FPU],
  input  logic [FW-1:0] fu_fp_fresult [N_FPU],
  input  logic [FFLAGS_W-1:0] fu_fp_fflags [N_FPU],
  input  logic [N_FPU-1:0] fu_fp_illegal,
  input  logic [PRF_IDX_WIDTH-1:0] fu_fp_dest_preg [N_FPU],
  input  logic [N_FPU-1:0] fu_fp_dest_en,
  input  logic [ROB_IDX_WIDTH-1:0] fu_fp_rob_idx [N_FPU],
  input  logic [N_FPU-1:0] fu_fp_rob_flag,
  input  logic [XLEN_BITS-1:0] lsu2exe_wb_req_uop_diag_val [LSU_LOAD_WB_WIDTH],
  input  logic [XLEN_BITS-1:0] lsu2exe_wb_req_uop_result [LSU_LOAD_WB_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] lsu2exe_wb_req_uop_dest_preg [LSU_LOAD_WB_WIDTH],
  input  logic [ROB_IDX_WIDTH-1:0] lsu2exe_wb_req_uop_rob_idx [LSU_LOAD_WB_WIDTH],
  input  logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_rob_flag,
  input  logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_dest_en,
  input  logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_page_fault_load,
  input  logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_rob_defer,
  input  logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_flush_pipe,
  input  logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_is_w,
  input  logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_page_fault_store,
  input  logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_valid,
  input  logic [LSU_STA_COUNT-1:0] lsu2exe_sta_wb_req_valid,
  input  logic [XLEN_BITS-1:0] lsu2exe_sta_wb_req_uop_diag_val [LSU_STA_COUNT],
  input  logic [XLEN_BITS-1:0] lsu2exe_sta_wb_req_uop_result [LSU_STA_COUNT],
  input  logic [ROB_IDX_WIDTH-1:0] lsu2exe_sta_wb_req_uop_rob_idx [LSU_STA_COUNT],
  input  logic [LSU_STA_COUNT-1:0] lsu2exe_sta_wb_req_uop_rob_flag,
  input  logic [LSU_STA_COUNT-1:0] lsu2exe_sta_wb_req_uop_page_fault_store,
  output logic exe2csr_we,
  output logic exe2csr_re,
  output logic [CSR_IDX_WIDTH-1:0] exe2csr_idx,
  output logic [XLEN_BITS-1:0] exe2csr_wdata,
  output logic [1:0] exe2csr_wcmd,
  output logic [XC_OP_NUM-1:0] exe2iss_fu_ready_mask [ISSUE_WIDTH],
  output xc_prf_wb_t exe2prf [WB_LANES],
  output xc_rob_wb_t exu2rob [ISSUE_WIDTH],
  output logic [LSU_LDU_COUNT-1:0] exe2lsu_ldu_req_valid,
  output logic [LSU_LDU_COUNT-1:0] exe2lsu_ldu_req_occ,
  output logic [LSU_STA_COUNT-1:0] exe2lsu_sta_req_occ,
  output logic [XLEN_BITS-1:0] exe2lsu_ldu_req_uop_result [LSU_LDU_COUNT],
  output logic [PRF_IDX_WIDTH-1:0] exe2lsu_ldu_req_uop_dest_preg [LSU_LDU_COUNT],
  output logic [2:0] exe2lsu_ldu_req_uop_func3 [LSU_LDU_COUNT],
  output logic [LSU_LDU_COUNT-1:0] exe2lsu_ldu_req_uop_is_atomic,
  output logic [XC_OP_W-1:0] exe2lsu_ldu_req_uop_amo_op [LSU_LDU_COUNT],
  output logic [ROB_IDX_WIDTH-1:0] exe2lsu_ldu_req_uop_rob_idx [LSU_LDU_COUNT],
  output logic exe2lsu_ldu_req_uop_rob_flag [LSU_LDU_COUNT],
  output logic [STQ_IDX_WIDTH-1:0] exe2lsu_ldu_req_uop_stq_idx [LSU_LDU_COUNT],
  output logic exe2lsu_ldu_req_uop_stq_flag [LSU_LDU_COUNT],
  output logic [LDQ_IDX_WIDTH-1:0] exe2lsu_ldu_req_uop_ldq_idx [LSU_LDU_COUNT],
  output logic [LSU_STA_COUNT-1:0] exe2lsu_sta_req_valid,
  output logic [XLEN_BITS-1:0] exe2lsu_sta_req_uop_result [LSU_STA_COUNT],
  output logic [PRF_IDX_WIDTH-1:0] exe2lsu_sta_req_uop_dest_preg [LSU_STA_COUNT],
  output logic [2:0] exe2lsu_sta_req_uop_func3 [LSU_STA_COUNT],
  output logic [LSU_STA_COUNT-1:0] exe2lsu_sta_req_uop_is_atomic,
  output logic [XC_OP_W-1:0] exe2lsu_sta_req_uop_amo_op [LSU_STA_COUNT],
  output logic [ROB_IDX_WIDTH-1:0] exe2lsu_sta_req_uop_rob_idx [LSU_STA_COUNT],
  output logic exe2lsu_sta_req_uop_rob_flag [LSU_STA_COUNT],
  output logic [STQ_IDX_WIDTH-1:0] exe2lsu_sta_req_uop_stq_idx [LSU_STA_COUNT],
  output logic [LSU_SDU_COUNT-1:0] exe2lsu_sdu_req_valid,
  output logic [XLEN_BITS-1:0] exe2lsu_sdu_req_uop_result [LSU_SDU_COUNT],
  output logic [ROB_IDX_WIDTH-1:0] exe2lsu_sdu_req_uop_rob_idx [LSU_SDU_COUNT],
  output logic [LSU_SDU_COUNT-1:0] exe2lsu_sdu_req_uop_rob_flag,
  output logic [STQ_IDX_WIDTH-1:0] exe2lsu_sdu_req_uop_stq_idx [LSU_SDU_COUNT],
  output logic exu2id_mispred,
  output logic [XLEN_BITS-1:0] exu2id_redirect_pc,
  output logic [ROB_IDX_WIDTH-1:0] exu2id_redirect_rob_idx,
  output logic exu2id_redirect_rob_flag,
  output logic [FTQ_IDX_WIDTH-1:0] exu2id_ftq_idx,
  output logic [FTQ_OFFSET_WIDTH-1:0] exu2id_ftq_offset,
  output logic [XLEN_BITS-1:0] exu2id_br_pc, output logic exu2id_br_is_rvc,
  output logic exu2fu_flush_all,
  output logic exu2fu_flush_br,
  output logic [ROB_IDX_WIDTH-1:0] exu2fu_flush_rob_idx,
  output logic exu2fu_flush_rob_flag,
  output logic exu2fu_alu_en [ALU_NUM],
  output logic [XC_OP_W-1:0] exu2fu_alu_op [ALU_NUM],
  output logic [2:0] exu2fu_alu_func3 [ALU_NUM],
  output logic [6:0] exu2fu_alu_func7 [ALU_NUM],
  output logic exu2fu_alu_src1_is_pc [ALU_NUM],
  output logic exu2fu_alu_src2_is_imm [ALU_NUM],
  output logic exu2fu_alu_is_word [ALU_NUM],
  output logic [XLEN_BITS-1:0] exu2fu_alu_pc [ALU_NUM],
  output logic [31:0] exu2fu_alu_imm [ALU_NUM],
  output logic [XLEN_BITS-1:0] exu2fu_alu_src1_rdata [ALU_NUM],
  output logic [XLEN_BITS-1:0] exu2fu_alu_src2_rdata [ALU_NUM],
  output logic exu2fu_bru_en [BRU_NUM],
  output logic [XC_OP_W-1:0] exu2fu_bru_op [BRU_NUM],
  output logic [2:0] exu2fu_bru_func3 [BRU_NUM],
  output logic exu2fu_bru_src1_en [BRU_NUM],
  output logic [XLEN_BITS-1:0] exu2fu_bru_src1_rdata [BRU_NUM],
  output logic [XLEN_BITS-1:0] exu2fu_bru_src2_rdata [BRU_NUM],
  output logic [XLEN_BITS-1:0] exu2fu_bru_pc [BRU_NUM],
  output logic [31:0] exu2fu_bru_imm [BRU_NUM],
  output logic exu2fu_bru_ftq_pred_taken [BRU_NUM],
  output logic exu2fu_bru_ftq_is_rvc [BRU_NUM],
  output logic [XLEN_BITS-1:0] exu2fu_bru_ftq_next_pc [BRU_NUM],
  output logic exu2fu_agu_en [LSU_AGU_COUNT],
  output logic [XLEN_BITS-1:0] exu2fu_agu_src1_rdata [LSU_AGU_COUNT],
  output logic [31:0] exu2fu_agu_imm [LSU_AGU_COUNT],
  output logic exu2fu_sdu_en [LSU_SDU_COUNT],
  output logic exu2fu_sdu_is_atomic [LSU_SDU_COUNT],
  output logic [6:0] exu2fu_sdu_func7 [LSU_SDU_COUNT],
  output logic exu2fu_sdu_amo_w [LSU_SDU_COUNT],
  output logic [XLEN_BITS-1:0] exu2fu_sdu_src1_rdata [LSU_SDU_COUNT],
  output logic [XLEN_BITS-1:0] exu2fu_sdu_src2_rdata [LSU_SDU_COUNT],
  output logic [N_MC-1:0] exu2fu_mc_en,
  output logic [N_MC-1:0] exu2fu_mc_consume,
  output logic [2:0] exu2fu_mc_func3 [N_MC],
  output logic exu2fu_mc_is_word [N_MC],
  output logic [6:0] exu2fu_mc_func7 [N_MC],
  output logic [XC_OP_W-1:0] exu2fu_mc_op [N_MC],
  output logic [31:0] exu2fu_mc_imm [N_MC],
  output logic [XLEN_BITS-1:0] exu2fu_mc_src1_rdata [N_MC],
  output logic [XLEN_BITS-1:0] exu2fu_mc_src2_rdata [N_MC],
  output logic [PRF_IDX_WIDTH-1:0] exu2fu_mc_dest_preg [N_MC],
  output logic [N_MC-1:0] exu2fu_mc_dest_en,
  output logic [ROB_IDX_WIDTH-1:0] exu2fu_mc_rob_idx [N_MC],
  output logic [N_MC-1:0] exu2fu_mc_rob_flag,
  output logic [N_FPU-1:0] exu2fu_fp_en,
  output logic [N_FPU-1:0] exu2fu_fp_consume,
  output logic [2:0] exu2fu_fp_func3 [N_FPU],
  output logic [6:0] exu2fu_fp_func7 [N_FPU],
  output logic [31:0] exu2fu_fp_imm [N_FPU],
  output logic [XLEN_BITS-1:0] exu2fu_fp_src1_rdata [N_FPU],
  output logic [FW-1:0] exu2fu_fp_fsrc1 [N_FPU],
  output logic [FW-1:0] exu2fu_fp_fsrc2 [N_FPU],
  output logic [FW-1:0] exu2fu_fp_fsrc3 [N_FPU],
  output logic [PRF_IDX_WIDTH-1:0] exu2fu_fp_dest_preg [N_FPU],
  output logic [N_FPU-1:0] exu2fu_fp_dest_en,
  output logic [ROB_IDX_WIDTH-1:0] exu2fu_fp_rob_idx [N_FPU],
  output logic [N_FPU-1:0] exu2fu_fp_rob_flag
);
  if (!xc_tables_match() || xc_fu_total() != TOTAL_FU_COUNT || xc_mc_count() != N_MC
      || xc_kind_count(XC_K_ALU) != ALU_NUM
      || xc_kind_count(XC_K_BR) != BRU_NUM || xc_kind_count(XC_K_LD) != LSU_LDU_COUNT
      || xc_kind_count(XC_K_STA) != LSU_STA_COUNT || xc_kind_count(XC_K_STD) != LSU_SDU_COUNT
      || (FP_EN && xc_fp_count() != N_FPU) || xc_kind_count(XC_K_CSR) != 1 || xc_fu_kind(CSR_FU) != XC_K_CSR
      || xc_fu_port(CSR_FU) != CSR_PORT
      || LSU_LDU_COUNT != LSU_LOAD_WB_WIDTH || IQ_ALU_PORT_BASE != 0) begin : g_cfg_check
    $error("exu_ctrl_pkg FU tables do not match ttg_cfg_pkg");
  end

  xc_fu_res_t fu_res [N_FU];
  xc_lsu_wb_t ld_wb  [LSU_LOAD_WB_WIDTH];
  xc_lsu_wb_t sta_wb [LSU_STA_COUNT];
  for (genvar i = 0; i < LSU_LOAD_WB_WIDTH; i++) begin : g_ld_wb
    assign ld_wb[i] = '{
      valid:            lsu2exe_wb_req_valid[i],
      diag_val:         lsu2exe_wb_req_uop_diag_val[i],
      result:           lsu2exe_wb_req_uop_result[i],
      dest_preg:        lsu2exe_wb_req_uop_dest_preg[i],
      rob_idx:          lsu2exe_wb_req_uop_rob_idx[i],
      rob_flag:         lsu2exe_wb_req_uop_rob_flag[i],
      dest_en:          lsu2exe_wb_req_uop_dest_en[i],
      page_fault_load:  lsu2exe_wb_req_uop_page_fault_load[i],
      page_fault_store: lsu2exe_wb_req_uop_page_fault_store[i],
      rob_defer:        lsu2exe_wb_req_uop_rob_defer[i],
      flush_pipe:       lsu2exe_wb_req_uop_flush_pipe[i],
      is_w:             lsu2exe_wb_req_uop_is_w[i]
    };
  end
  for (genvar i = 0; i < LSU_STA_COUNT; i++) begin : g_sta_wb
    assign sta_wb[i] = '{
      valid:            lsu2exe_sta_wb_req_valid[i],
      diag_val:         lsu2exe_sta_wb_req_uop_diag_val[i],
      result:           lsu2exe_sta_wb_req_uop_result[i],
      dest_preg:        '0,
      rob_idx:          lsu2exe_sta_wb_req_uop_rob_idx[i],
      rob_flag:         lsu2exe_sta_wb_req_uop_rob_flag[i],
      dest_en:          1'b0,
      page_fault_load:  1'b0,
      page_fault_store: lsu2exe_sta_wb_req_uop_page_fault_store[i],
      rob_defer:        1'b0,
      flush_pipe:       1'b0,
      is_w:             1'b0
    };
  end

  logic [N_FU-1:0]          fu_en, fu_occ, fu_ready, consume;
  xc_inst_t                 fu_inst [N_FU];
  xc_done_t                 fu_done [N_FU];
  logic [CSR_IDX_WIDTH-1:0] csr_slot_idx;
  logic [ISSUE_WIDTH-1:0]   win_valid;
  logic [ALU_NUM-1:0]       win_is_csr;
  xc_done_t                 win [ISSUE_WIDTH];

  exu_ctrl_slot u_slot (
    .clk, .rst_n,
    .flush(rob_bcast_flush), .mispred(dec_bcast_mispred),
    .kill_rob_idx(dec_bcast_redirect_rob_idx), .kill_rob_flag(dec_bcast_redirect_rob_flag),
    .iss_valid(prf2exe_valid), .iss_inst(prf2exe_uop), .iss_csr_idx(prf2exe_csr_idx),
    .fu_ready, .fu_en, .fu_occ, .fu_inst, .csr_idx(csr_slot_idx)
  );
  exu_ctrl_fu_in u_fu_in (
    .fu_alu_result, .fu_agu_result, .fu_sdu_result, .fu_bru_diag_val, .fu_bru_mispred, .fu_bru_br_taken,
    .fu_mc_ready, .fu_mc_complete, .fu_mc_result, .fu_mc_dest_preg, .fu_mc_dest_en, .fu_mc_rob_idx, .fu_mc_rob_flag,
    .fu_fp_ready, .fu_fp_complete, .fu_fp_result, .fu_fp_fresult, .fu_fp_fflags, .fu_fp_illegal, .fu_fp_dest_preg,
    .fu_fp_dest_en, .fu_fp_rob_idx, .fu_fp_rob_flag, .fu_res
  );
  exu_ctrl_fu_view u_view (.fu_en, .fu_inst, .fu_res, .fu_done);
  exu_ctrl_port_arb u_arb (.fu_done, .consume, .win_valid, .win, .win_is_csr);
  exu_ctrl_ready u_ready (
    .flush(rob_bcast_flush), .div_wb_next(div_wb_next), .fu_en, .consume, .fu_res, .fu_ready,
    .fu_ready_mask(exe2iss_fu_ready_mask)
  );
  exu_ctrl_csr_req u_csr (
    .csr_en(fu_en[CSR_FU]), .func3(fu_inst[CSR_FU].func3), .imm(fu_inst[CSR_FU].imm),
    .dest_preg(fu_inst[CSR_FU].dest_preg), .src2_is_imm(fu_inst[CSR_FU].src2_is_imm),
    .src1_rdata(fu_inst[CSR_FU].src1_rdata), .csr_idx(csr_slot_idx),
    .we(exe2csr_we), .re(exe2csr_re), .idx(exe2csr_idx), .wdata(exe2csr_wdata), .wcmd(exe2csr_wcmd)
  );
  exu_ctrl_wb_prf u_wb_prf (
    .win_valid, .win, .win_is_csr, .csr_re(exe2csr_re), .csr_rdata(csr2exe_rdata), .ld_wb, .wb(exe2prf)
  );
  exu_ctrl_wb_rob u_wb_rob (
    .flush(rob_bcast_flush), .mispred(dec_bcast_mispred),
    .kill_rob_idx(dec_bcast_redirect_rob_idx), .kill_rob_flag(dec_bcast_redirect_rob_flag),
    .win_valid, .win, .ld_wb, .sta_wb, .wb(exu2rob)
  );
  exu_ctrl_br_arb u_br (
    .fu_done, .mispred(exu2id_mispred), .redirect_pc(exu2id_redirect_pc),
    .redirect_rob_idx(exu2id_redirect_rob_idx), .redirect_rob_flag(exu2id_redirect_rob_flag),
    .ftq_idx(exu2id_ftq_idx), .ftq_offset(exu2id_ftq_offset),
    .br_pc(exu2id_br_pc), .br_is_rvc(exu2id_br_is_rvc)
  );
  exu_ctrl_lsu_out u_lsu_out (
    .fu_done, .fu_occ, .exe2lsu_ldu_req_occ, .exe2lsu_sta_req_occ,
    .exe2lsu_ldu_req_valid, .exe2lsu_ldu_req_uop_result, .exe2lsu_ldu_req_uop_dest_preg, .exe2lsu_ldu_req_uop_func3,
    .exe2lsu_ldu_req_uop_is_atomic, .exe2lsu_ldu_req_uop_amo_op, .exe2lsu_ldu_req_uop_rob_idx,
    .exe2lsu_ldu_req_uop_rob_flag, .exe2lsu_ldu_req_uop_stq_idx, .exe2lsu_ldu_req_uop_stq_flag,
    .exe2lsu_ldu_req_uop_ldq_idx,
    .exe2lsu_sta_req_valid, .exe2lsu_sta_req_uop_result, .exe2lsu_sta_req_uop_dest_preg, .exe2lsu_sta_req_uop_func3,
    .exe2lsu_sta_req_uop_is_atomic, .exe2lsu_sta_req_uop_amo_op, .exe2lsu_sta_req_uop_rob_idx,
    .exe2lsu_sta_req_uop_rob_flag, .exe2lsu_sta_req_uop_stq_idx,
    .exe2lsu_sdu_req_valid, .exe2lsu_sdu_req_uop_result, .exe2lsu_sdu_req_uop_rob_idx,
    .exe2lsu_sdu_req_uop_rob_flag, .exe2lsu_sdu_req_uop_stq_idx
  );
  assign exu2fu_flush_all      = rob_bcast_flush;
  assign exu2fu_flush_br       = !rob_bcast_flush && dec_bcast_mispred;
  assign exu2fu_flush_rob_idx  = dec_bcast_redirect_rob_idx;
  assign exu2fu_flush_rob_flag = dec_bcast_redirect_rob_flag;
  exu_ctrl_fu_out u_fu_out (
    .fu_en, .fu_inst, .consume,
    .exu2fu_alu_en, .exu2fu_alu_op, .exu2fu_alu_func3, .exu2fu_alu_func7, .exu2fu_alu_src1_is_pc,
    .exu2fu_alu_src2_is_imm, .exu2fu_alu_is_word, .exu2fu_alu_pc, .exu2fu_alu_imm, .exu2fu_alu_src1_rdata,
    .exu2fu_alu_src2_rdata,
    .exu2fu_bru_en, .exu2fu_bru_op, .exu2fu_bru_func3, .exu2fu_bru_src1_en, .exu2fu_bru_src1_rdata,
    .exu2fu_bru_src2_rdata, .exu2fu_bru_pc, .exu2fu_bru_imm, .exu2fu_bru_ftq_pred_taken, .exu2fu_bru_ftq_is_rvc,
    .exu2fu_bru_ftq_next_pc,
    .exu2fu_agu_en, .exu2fu_agu_src1_rdata, .exu2fu_agu_imm,
    .exu2fu_sdu_en, .exu2fu_sdu_is_atomic, .exu2fu_sdu_func7, .exu2fu_sdu_amo_w,
    .exu2fu_sdu_src1_rdata, .exu2fu_sdu_src2_rdata,
    .exu2fu_mc_en, .exu2fu_mc_consume, .exu2fu_mc_func3, .exu2fu_mc_is_word,
    .exu2fu_mc_func7, .exu2fu_mc_op, .exu2fu_mc_imm,
    .exu2fu_mc_src1_rdata, .exu2fu_mc_src2_rdata, .exu2fu_mc_dest_preg, .exu2fu_mc_dest_en,
    .exu2fu_mc_rob_idx, .exu2fu_mc_rob_flag,
    .exu2fu_fp_en, .exu2fu_fp_consume, .exu2fu_fp_func3, .exu2fu_fp_func7, .exu2fu_fp_imm, .exu2fu_fp_src1_rdata,
    .exu2fu_fp_fsrc1, .exu2fu_fp_fsrc2, .exu2fu_fp_fsrc3, .exu2fu_fp_dest_preg, .exu2fu_fp_dest_en,
    .exu2fu_fp_rob_idx, .exu2fu_fp_rob_flag
  );
endmodule
`default_nettype wire
