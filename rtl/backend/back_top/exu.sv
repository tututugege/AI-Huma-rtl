// Ref: back-end/Exu/Exu.cpp  class Exu  (exu_ctrl + the functional units)
// Exu composite: exu_ctrl (Exu::comb_* without the functional units) + the 27 functional units (the CSR FU needs no
// hardware, see below); docs/modules/back_top.md has the contract with each FU.
`default_nettype none

module exu
  import ttg_cfg_pkg::*;
  import exu_fu_pkg::*;
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
  input  logic [2:0] csr2exe_frm,
  input  logic [ISSUE_WIDTH-1:0] prf2exe_valid,
  input  xc_inst_t prf2exe_uop [ISSUE_WIDTH],
  input  logic [CSR_IDX_WIDTH-1:0] prf2exe_csr_idx,
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
  output logic [11:0] exe2csr_idx,
  output logic [XLEN_BITS-1:0] exe2csr_wdata,
  output logic [1:0] exe2csr_wcmd,
  output logic exe2iss_div_wb_in2,
  output logic exe2iss_div_wake_valid,
  output logic [PRF_IDX_WIDTH-1:0] exe2iss_div_wake_preg,
  output xc_prf_wb_t exe2prf [WB_LANES],
  output xc_rob_wb_t exu2rob [ROB_WB_WIDTH],
  output xc_agu_req_t exe2lsu_agu [LSU_AGU_COUNT],
  output logic [LSU_SDU_COUNT-1:0] exe2lsu_sdu_req_valid,
  output logic [XLEN_BITS-1:0] exe2lsu_sdu_req_uop_result [LSU_SDU_COUNT],
  output logic [ROB_IDX_WIDTH-1:0] exe2lsu_sdu_req_uop_rob_idx [LSU_SDU_COUNT],
  output logic [LSU_SDU_COUNT-1:0] exe2lsu_sdu_req_uop_rob_flag,
  output logic [5:0] exe2lsu_sdu_req_uop_stq_idx [LSU_SDU_COUNT],
  output logic exu2id_mispred,
  output logic [XLEN_BITS-1:0] exu2id_redirect_pc,
  output logic [ROB_IDX_WIDTH-1:0] exu2id_redirect_rob_idx,
  output logic exu2id_redirect_rob_flag,
  output logic [5:0] exu2id_ftq_idx,
  output logic [FTQ_OFFSET_WIDTH-1:0] exu2id_ftq_offset,
  output logic [XLEN_BITS-1:0] exu2id_br_pc,
  output logic exu2id_br_is_rvc
);

  // ---- functional-unit side of exu_ctrl
  logic [XLEN_BITS-1:0] fu_alu_result [ALU_NUM];
  logic [XLEN_BITS-1:0] fu_agu_result [LSU_AGU_COUNT];
  logic [XLEN_BITS-1:0] fu_sdu_result [LSU_SDU_COUNT];
  logic [XLEN_BITS-1:0] fu_bru_diag_val [BRU_NUM];
  logic fu_bru_mispred [BRU_NUM];
  logic fu_bru_br_taken [BRU_NUM];
  logic div_wb_in2 [DIV_NUM];
  logic [N_MC-1:0] fu_mc_complete;
  logic [XLEN_BITS-1:0] fu_mc_result [N_MC];
  logic [PRF_IDX_WIDTH-1:0] fu_mc_dest_preg [N_MC];
  logic [N_MC-1:0] fu_mc_dest_en;
  logic [ROB_IDX_WIDTH-1:0] fu_mc_rob_idx [N_MC];
  logic [N_MC-1:0] fu_mc_rob_flag;
  logic [N_FPU-1:0] fu_fp_complete;
  logic [XLEN_BITS-1:0] fu_fp_result [N_FPU];
  logic [FW-1:0] fu_fp_fresult [N_FPU];
  logic [FFLAGS_W-1:0] fu_fp_fflags [N_FPU];
  logic [N_FPU-1:0] fu_fp_illegal;
  logic [PRF_IDX_WIDTH-1:0] fu_fp_dest_preg [N_FPU];
  logic [N_FPU-1:0] fu_fp_dest_en;
  logic [ROB_IDX_WIDTH-1:0] fu_fp_rob_idx [N_FPU];
  logic [N_FPU-1:0] fu_fp_rob_flag;

  logic exu2fu_flush_all;
  logic exu2fu_flush_br;
  logic [ROB_IDX_WIDTH-1:0] exu2fu_flush_rob_idx;
  logic exu2fu_flush_rob_flag;
  logic [XC_OP_W-1:0] exu2fu_alu_op [ALU_NUM];
  logic [2:0] exu2fu_alu_func3 [ALU_NUM];
  logic [6:0] exu2fu_alu_func7 [ALU_NUM];
  logic exu2fu_alu_src1_is_pc [ALU_NUM];
  logic exu2fu_alu_src2_is_imm [ALU_NUM];
  logic exu2fu_alu_is_word [ALU_NUM];
  logic [XLEN_BITS-1:0] exu2fu_alu_pc [ALU_NUM];
  logic [31:0] exu2fu_alu_imm [ALU_NUM];
  logic [XLEN_BITS-1:0] exu2fu_alu_src1_rdata [ALU_NUM];
  logic [XLEN_BITS-1:0] exu2fu_alu_src2_rdata [ALU_NUM];
  logic [XC_OP_W-1:0] exu2fu_bru_op [BRU_NUM];
  logic [2:0] exu2fu_bru_func3 [BRU_NUM];
  logic exu2fu_bru_src1_en [BRU_NUM];
  logic [XLEN_BITS-1:0] exu2fu_bru_src1_rdata [BRU_NUM];
  logic [XLEN_BITS-1:0] exu2fu_bru_src2_rdata [BRU_NUM];
  logic [XLEN_BITS-1:0] exu2fu_bru_pc [BRU_NUM];
  logic [31:0] exu2fu_bru_imm [BRU_NUM];
  logic exu2fu_bru_ftq_pred_taken [BRU_NUM];
  logic exu2fu_bru_ftq_is_rvc [BRU_NUM];
  logic [XLEN_BITS-1:0] exu2fu_bru_ftq_next_pc [BRU_NUM];
  logic [XLEN_BITS-1:0] exu2fu_agu_src1_rdata [LSU_AGU_COUNT];
  logic [31:0] exu2fu_agu_imm [LSU_AGU_COUNT];
  logic exu2fu_sdu_is_atomic [LSU_SDU_COUNT];
  logic [6:0] exu2fu_sdu_func7 [LSU_SDU_COUNT];
  logic exu2fu_sdu_amo_w [LSU_SDU_COUNT];
  logic [XLEN_BITS-1:0] exu2fu_sdu_src1_rdata [LSU_SDU_COUNT];
  logic [XLEN_BITS-1:0] exu2fu_sdu_src2_rdata [LSU_SDU_COUNT];
  logic [N_MC-1:0] exu2fu_mc_en;
  logic [2:0] exu2fu_mc_func3 [N_MC];
  logic exu2fu_mc_is_word [N_MC];
  logic [XLEN_BITS-1:0] exu2fu_mc_src1_rdata [N_MC];
  logic [XLEN_BITS-1:0] exu2fu_mc_src2_rdata [N_MC];
  logic [PRF_IDX_WIDTH-1:0] exu2fu_mc_dest_preg [N_MC];
  logic [N_MC-1:0] exu2fu_mc_dest_en;
  logic [ROB_IDX_WIDTH-1:0] exu2fu_mc_rob_idx [N_MC];
  logic [N_MC-1:0] exu2fu_mc_rob_flag;
  logic [N_FPU-1:0] exu2fu_fp_en;
  logic [2:0] exu2fu_fp_func3 [N_FPU];
  logic [6:0] exu2fu_fp_func7 [N_FPU];
  logic [31:0] exu2fu_fp_imm [N_FPU];
  logic [XLEN_BITS-1:0] exu2fu_fp_src1_rdata [N_FPU];
  logic [FW-1:0] exu2fu_fp_fsrc1 [N_FPU];
  logic [FW-1:0] exu2fu_fp_fsrc2 [N_FPU];
  logic [FW-1:0] exu2fu_fp_fsrc3 [N_FPU];
  logic [PRF_IDX_WIDTH-1:0] exu2fu_fp_dest_preg [N_FPU];
  logic [N_FPU-1:0] exu2fu_fp_dest_en;
  logic [ROB_IDX_WIDTH-1:0] exu2fu_fp_rob_idx [N_FPU];
  logic [N_FPU-1:0] exu2fu_fp_rob_flag;

  // ---- exu_ctrl: slots, port arbitration, write-back / bypass / ROB / LSU / CSR / branch outputs
  exu_ctrl u_ctrl (
    .clk(clk), .rst_n(rst_n),
    .rob_bcast_flush(rob_bcast_flush),
    .dec_bcast_mispred(dec_bcast_mispred),
    .dec_bcast_redirect_rob_idx(dec_bcast_redirect_rob_idx),
    .dec_bcast_redirect_rob_flag(dec_bcast_redirect_rob_flag),
    .csr2exe_rdata(csr2exe_rdata),
    .prf2exe_valid(prf2exe_valid),
    .prf2exe_uop(prf2exe_uop),
    .prf2exe_csr_idx(prf2exe_csr_idx),
    .lsu2exe_wb_req_uop_diag_val(lsu2exe_wb_req_uop_diag_val),
    .lsu2exe_wb_req_uop_result(lsu2exe_wb_req_uop_result),
    .lsu2exe_wb_req_uop_dest_preg(lsu2exe_wb_req_uop_dest_preg),
    .lsu2exe_wb_req_uop_rob_idx(lsu2exe_wb_req_uop_rob_idx),
    .lsu2exe_wb_req_uop_rob_flag(lsu2exe_wb_req_uop_rob_flag),
    .lsu2exe_wb_req_uop_dest_en(lsu2exe_wb_req_uop_dest_en),
    .lsu2exe_wb_req_uop_page_fault_load(lsu2exe_wb_req_uop_page_fault_load),
    .lsu2exe_wb_req_uop_rob_defer(lsu2exe_wb_req_uop_rob_defer),
    .lsu2exe_wb_req_uop_flush_pipe(lsu2exe_wb_req_uop_flush_pipe),
    .lsu2exe_wb_req_uop_is_w(lsu2exe_wb_req_uop_is_w),
    .lsu2exe_wb_req_uop_page_fault_store(lsu2exe_wb_req_uop_page_fault_store),
    .lsu2exe_wb_req_valid(lsu2exe_wb_req_valid),
    .lsu2exe_sta_wb_req_valid(lsu2exe_sta_wb_req_valid),
    .lsu2exe_sta_wb_req_uop_diag_val(lsu2exe_sta_wb_req_uop_diag_val),
    .lsu2exe_sta_wb_req_uop_result(lsu2exe_sta_wb_req_uop_result),
    .lsu2exe_sta_wb_req_uop_rob_idx(lsu2exe_sta_wb_req_uop_rob_idx),
    .lsu2exe_sta_wb_req_uop_rob_flag(lsu2exe_sta_wb_req_uop_rob_flag),
    .lsu2exe_sta_wb_req_uop_page_fault_store(lsu2exe_sta_wb_req_uop_page_fault_store),
    .exe2csr_we(exe2csr_we),
    .exe2csr_idx(exe2csr_idx),
    .exe2csr_wdata(exe2csr_wdata),
    .exe2csr_wcmd(exe2csr_wcmd),
    .exe2prf(exe2prf),
    .exu2rob(exu2rob),
    .exe2lsu_agu(exe2lsu_agu),
    .exe2lsu_sdu_req_valid(exe2lsu_sdu_req_valid),
    .exe2lsu_sdu_req_uop_result(exe2lsu_sdu_req_uop_result),
    .exe2lsu_sdu_req_uop_rob_idx(exe2lsu_sdu_req_uop_rob_idx),
    .exe2lsu_sdu_req_uop_rob_flag(exe2lsu_sdu_req_uop_rob_flag),
    .exe2lsu_sdu_req_uop_stq_idx(exe2lsu_sdu_req_uop_stq_idx),
    .exu2id_mispred(exu2id_mispred),
    .exu2id_redirect_pc(exu2id_redirect_pc),
    .exu2id_redirect_rob_idx(exu2id_redirect_rob_idx),
    .exu2id_redirect_rob_flag(exu2id_redirect_rob_flag),
    .exu2id_ftq_idx(exu2id_ftq_idx),
    .exu2id_ftq_offset(exu2id_ftq_offset),
    .exu2id_br_pc(exu2id_br_pc),
    .exu2id_br_is_rvc(exu2id_br_is_rvc),
    .fu_alu_result(fu_alu_result),
    .fu_agu_result(fu_agu_result),
    .fu_sdu_result(fu_sdu_result),
    .fu_bru_diag_val(fu_bru_diag_val),
    .fu_bru_mispred(fu_bru_mispred),
    .fu_bru_br_taken(fu_bru_br_taken),
    .fu_mc_complete(fu_mc_complete),
    .fu_mc_result(fu_mc_result),
    .fu_mc_dest_preg(fu_mc_dest_preg),
    .fu_mc_dest_en(fu_mc_dest_en),
    .fu_mc_rob_idx(fu_mc_rob_idx),
    .fu_mc_rob_flag(fu_mc_rob_flag),
    .fu_fp_complete(fu_fp_complete),
    .fu_fp_result(fu_fp_result),
    .fu_fp_fresult(fu_fp_fresult),
    .fu_fp_fflags(fu_fp_fflags),
    .fu_fp_illegal(fu_fp_illegal),
    .fu_fp_dest_preg(fu_fp_dest_preg),
    .fu_fp_dest_en(fu_fp_dest_en),
    .fu_fp_rob_idx(fu_fp_rob_idx),
    .fu_fp_rob_flag(fu_fp_rob_flag),
    .exu2fu_flush_all(exu2fu_flush_all),
    .exu2fu_flush_br(exu2fu_flush_br),
    .exu2fu_flush_rob_idx(exu2fu_flush_rob_idx),
    .exu2fu_flush_rob_flag(exu2fu_flush_rob_flag),
    .exu2fu_alu_op(exu2fu_alu_op),
    .exu2fu_alu_func3(exu2fu_alu_func3),
    .exu2fu_alu_func7(exu2fu_alu_func7),
    .exu2fu_alu_src1_is_pc(exu2fu_alu_src1_is_pc),
    .exu2fu_alu_src2_is_imm(exu2fu_alu_src2_is_imm),
    .exu2fu_alu_is_word(exu2fu_alu_is_word),
    .exu2fu_alu_pc(exu2fu_alu_pc),
    .exu2fu_alu_imm(exu2fu_alu_imm),
    .exu2fu_alu_src1_rdata(exu2fu_alu_src1_rdata),
    .exu2fu_alu_src2_rdata(exu2fu_alu_src2_rdata),
    .exu2fu_bru_op(exu2fu_bru_op),
    .exu2fu_bru_func3(exu2fu_bru_func3),
    .exu2fu_bru_src1_en(exu2fu_bru_src1_en),
    .exu2fu_bru_src1_rdata(exu2fu_bru_src1_rdata),
    .exu2fu_bru_src2_rdata(exu2fu_bru_src2_rdata),
    .exu2fu_bru_pc(exu2fu_bru_pc),
    .exu2fu_bru_imm(exu2fu_bru_imm),
    .exu2fu_bru_ftq_pred_taken(exu2fu_bru_ftq_pred_taken),
    .exu2fu_bru_ftq_is_rvc(exu2fu_bru_ftq_is_rvc),
    .exu2fu_bru_ftq_next_pc(exu2fu_bru_ftq_next_pc),
    .exu2fu_agu_src1_rdata(exu2fu_agu_src1_rdata),
    .exu2fu_agu_imm(exu2fu_agu_imm),
    .exu2fu_sdu_is_atomic(exu2fu_sdu_is_atomic),
    .exu2fu_sdu_func7(exu2fu_sdu_func7),
    .exu2fu_sdu_amo_w(exu2fu_sdu_amo_w),
    .exu2fu_sdu_src1_rdata(exu2fu_sdu_src1_rdata),
    .exu2fu_sdu_src2_rdata(exu2fu_sdu_src2_rdata),
    .exu2fu_mc_en(exu2fu_mc_en),
    .exu2fu_mc_func3(exu2fu_mc_func3),
    .exu2fu_mc_is_word(exu2fu_mc_is_word),
    .exu2fu_mc_src1_rdata(exu2fu_mc_src1_rdata),
    .exu2fu_mc_src2_rdata(exu2fu_mc_src2_rdata),
    .exu2fu_mc_dest_preg(exu2fu_mc_dest_preg),
    .exu2fu_mc_dest_en(exu2fu_mc_dest_en),
    .exu2fu_mc_rob_idx(exu2fu_mc_rob_idx),
    .exu2fu_mc_rob_flag(exu2fu_mc_rob_flag),
    .exu2fu_fp_en(exu2fu_fp_en),
    .exu2fu_fp_func3(exu2fu_fp_func3),
    .exu2fu_fp_func7(exu2fu_fp_func7),
    .exu2fu_fp_imm(exu2fu_fp_imm),
    .exu2fu_fp_src1_rdata(exu2fu_fp_src1_rdata),
    .exu2fu_fp_fsrc1(exu2fu_fp_fsrc1),
    .exu2fu_fp_fsrc2(exu2fu_fp_fsrc2),
    .exu2fu_fp_fsrc3(exu2fu_fp_fsrc3),
    .exu2fu_fp_dest_preg(exu2fu_fp_dest_preg),
    .exu2fu_fp_dest_en(exu2fu_fp_dest_en),
    .exu2fu_fp_rob_idx(exu2fu_fp_rob_idx),
    .exu2fu_fp_rob_flag(exu2fu_fp_rob_flag)
  );

  // ---- single-cycle FUs (combinational, no ready/consume) ----
  alu_bank u_alu (
    .op(exu2fu_alu_op), .func3(exu2fu_alu_func3),
    .func7(exu2fu_alu_func7), .src1_is_pc(exu2fu_alu_src1_is_pc), .src2_is_imm(exu2fu_alu_src2_is_imm),
    .is_word(exu2fu_alu_is_word),
    .pc(exu2fu_alu_pc), .imm(exu2fu_alu_imm), .src1_rdata(exu2fu_alu_src1_rdata), .src2_rdata(exu2fu_alu_src2_rdata),
    .result(fu_alu_result)
  );

  bru_bank u_bru (
    .op(exu2fu_bru_op), .func3(exu2fu_bru_func3),
    .src1_en(exu2fu_bru_src1_en), .src1_rdata(exu2fu_bru_src1_rdata), .src2_rdata(exu2fu_bru_src2_rdata),
    .pc(exu2fu_bru_pc), .imm(exu2fu_bru_imm), .ftq_pred_taken(exu2fu_bru_ftq_pred_taken),
    .ftq_is_rvc(exu2fu_bru_ftq_is_rvc),
    .ftq_next_pc(exu2fu_bru_ftq_next_pc), .br_taken(fu_bru_br_taken),
    .mispred(fu_bru_mispred), .diag_val(fu_bru_diag_val)
  );

  agu_bank u_agu (
    .src1_rdata(exu2fu_agu_src1_rdata), .imm(exu2fu_agu_imm),
    .result(fu_agu_result)
  );

  logic [4:0] sdu_amo_op [LSU_SDU_COUNT];
  for (genvar i = 0; i < LSU_SDU_COUNT; i++) begin : g_sdu_amo
    assign sdu_amo_op[i] = exu2fu_sdu_func7[i][6:2];  // Fu.h SduUnit reads func7 >> 2
  end
  sdu_bank u_sdu (
    .is_atomic(exu2fu_sdu_is_atomic),
    .amo_op(sdu_amo_op), .amo_w(exu2fu_sdu_amo_w),
    .src1_rdata(exu2fu_sdu_src1_rdata), .src2_rdata(exu2fu_sdu_src2_rdata),
    .result(fu_sdu_result)
  );

  // The CSR FU (fu_idx 2) has no data path (impl_compute is empty, result 0, read data is muxed in by exu_ctrl)
  // and is handled directly by exu_ctrl: csr_fu is therefore not instantiated.

  // ---- multi-cycle FUs. exu_ctrl numbers them in Exu::units order {MUL(0), DIV(3), MUL(5)}.
  localparam int MC_MUL [MUL_NUM] = '{0, 2};
  localparam int MC_DIV [DIV_NUM] = '{1};

  // MUL: result/dest/rob come back from the FU's own pipeline (it keeps the instruction in flight).
  logic mul_flush_all [MUL_NUM];
  logic mul_flush_br [MUL_NUM];
  logic [ROB_IDX_WIDTH-1:0] mul_flush_rob_idx [MUL_NUM];
  logic mul_flush_rob_flag [MUL_NUM];
  logic [1:0] mul_func3 [MUL_NUM];
  logic mul_is_word [MUL_NUM];
  logic mul_complete [MUL_NUM];
  logic [XLEN_BITS-1:0] mul_result [MUL_NUM];
  logic [ROB_IDX_WIDTH-1:0] mul_done_rob_idx [MUL_NUM];
  logic mul_done_rob_flag [MUL_NUM];
  logic [PRF_IDX_WIDTH-1:0] mul_done_dest_preg [MUL_NUM];
  logic mul_done_dest_en [MUL_NUM];
  logic mul_en [MUL_NUM];
  logic [XLEN_BITS-1:0] mul_src1_rdata [MUL_NUM];
  logic [XLEN_BITS-1:0] mul_src2_rdata [MUL_NUM];
  logic [ROB_IDX_WIDTH-1:0] mul_rob_idx [MUL_NUM];
  logic mul_rob_flag [MUL_NUM];
  logic [PRF_IDX_WIDTH-1:0] mul_dest_preg [MUL_NUM];
  logic mul_dest_en [MUL_NUM];
  for (genvar i = 0; i < MUL_NUM; i++) begin : g_mul
    assign mul_en[i] = exu2fu_mc_en[MC_MUL[i]];
    assign mul_flush_all[i] = exu2fu_flush_all;
    assign mul_flush_br[i] = exu2fu_flush_br;
    assign mul_flush_rob_idx[i] = exu2fu_flush_rob_idx;
    assign mul_flush_rob_flag[i] = exu2fu_flush_rob_flag;
    assign mul_func3[i] = exu2fu_mc_func3[MC_MUL[i]][1:0];
    assign mul_is_word[i] = exu2fu_mc_is_word[MC_MUL[i]];
    assign mul_src1_rdata[i] = exu2fu_mc_src1_rdata[MC_MUL[i]];
    assign mul_src2_rdata[i] = exu2fu_mc_src2_rdata[MC_MUL[i]];
    assign mul_rob_idx[i] = exu2fu_mc_rob_idx[MC_MUL[i]];
    assign mul_rob_flag[i] = exu2fu_mc_rob_flag[MC_MUL[i]];
    assign mul_dest_preg[i] = exu2fu_mc_dest_preg[MC_MUL[i]];
    assign mul_dest_en[i] = exu2fu_mc_dest_en[MC_MUL[i]];
    assign fu_mc_complete[MC_MUL[i]] = mul_complete[i];
    assign fu_mc_result[MC_MUL[i]] = mul_result[i];
    assign fu_mc_dest_preg[MC_MUL[i]] = mul_done_dest_preg[i];
    assign fu_mc_dest_en[MC_MUL[i]] = mul_done_dest_en[i];
    assign fu_mc_rob_idx[MC_MUL[i]] = mul_done_rob_idx[i];
    assign fu_mc_rob_flag[MC_MUL[i]] = mul_done_rob_flag[i];
  end
  mul_bank u_mul (
    .clk(clk), .rst_n(rst_n), .en(mul_en),
    .flush_all(mul_flush_all), .flush_br(mul_flush_br),
    .flush_rob_idx(mul_flush_rob_idx), .flush_rob_flag(mul_flush_rob_flag),
    .func3(mul_func3), .is_word(mul_is_word),
    .src1_rdata(mul_src1_rdata), .src2_rdata(mul_src2_rdata),
    .rob_idx(mul_rob_idx), .rob_flag(mul_rob_flag), .dest_preg(mul_dest_preg), .dest_en(mul_dest_en),
    .complete(mul_complete), .result(mul_result),
    .done_rob_idx(mul_done_rob_idx), .done_rob_flag(mul_done_rob_flag),
    .done_dest_preg(mul_done_dest_preg), .done_dest_en(mul_done_dest_en)
  );

  logic div_flush_all [DIV_NUM];
  logic div_flush_br [DIV_NUM];
  logic [ROB_IDX_WIDTH-1:0] div_flush_rob_idx [DIV_NUM];
  logic div_flush_rob_flag [DIV_NUM];
  logic [1:0] div_func3 [DIV_NUM];
  logic div_is_word [DIV_NUM];
  logic div_complete [DIV_NUM];
  logic div_wake_valid [DIV_NUM];
  logic [PRF_IDX_WIDTH-1:0] div_wake_preg [DIV_NUM];
  logic [XLEN_BITS-1:0] div_result [DIV_NUM];
  logic [ROB_IDX_WIDTH-1:0] div_done_rob_idx [DIV_NUM];
  logic div_done_rob_flag [DIV_NUM];
  logic [PRF_IDX_WIDTH-1:0] div_done_dest_preg [DIV_NUM];
  logic div_done_dest_en [DIV_NUM];
  logic div_en [DIV_NUM];
  logic [XLEN_BITS-1:0] div_src1_rdata [DIV_NUM];
  logic [XLEN_BITS-1:0] div_src2_rdata [DIV_NUM];
  logic [ROB_IDX_WIDTH-1:0] div_rob_idx [DIV_NUM];
  logic div_rob_flag [DIV_NUM];
  logic [PRF_IDX_WIDTH-1:0] div_dest_preg [DIV_NUM];
  logic div_dest_en [DIV_NUM];
  for (genvar i = 0; i < DIV_NUM; i++) begin : g_div
    assign div_en[i] = exu2fu_mc_en[MC_DIV[i]];
    assign div_flush_all[i] = exu2fu_flush_all;
    assign div_flush_br[i] = exu2fu_flush_br;
    assign div_flush_rob_idx[i] = exu2fu_flush_rob_idx;
    assign div_flush_rob_flag[i] = exu2fu_flush_rob_flag;
    assign div_func3[i] = exu2fu_mc_func3[MC_DIV[i]][1:0];
    assign div_is_word[i] = exu2fu_mc_is_word[MC_DIV[i]];
    assign div_src1_rdata[i] = exu2fu_mc_src1_rdata[MC_DIV[i]];
    assign div_src2_rdata[i] = exu2fu_mc_src2_rdata[MC_DIV[i]];
    assign div_rob_idx[i] = exu2fu_mc_rob_idx[MC_DIV[i]];
    assign div_rob_flag[i] = exu2fu_mc_rob_flag[MC_DIV[i]];
    assign div_dest_preg[i] = exu2fu_mc_dest_preg[MC_DIV[i]];
    assign div_dest_en[i] = exu2fu_mc_dest_en[MC_DIV[i]];
    assign fu_mc_complete[MC_DIV[i]] = div_complete[i];
    assign fu_mc_result[MC_DIV[i]] = div_result[i];
    assign fu_mc_dest_preg[MC_DIV[i]] = div_done_dest_preg[i];
    assign fu_mc_dest_en[MC_DIV[i]] = div_done_dest_en[i];
    assign fu_mc_rob_idx[MC_DIV[i]] = div_done_rob_idx[i];
    assign fu_mc_rob_flag[MC_DIV[i]] = div_done_rob_flag[i];
  end
  div_bank u_div (
    .clk(clk), .rst_n(rst_n), .en(div_en),
    .flush_all(div_flush_all), .flush_br(div_flush_br),
    .flush_rob_idx(div_flush_rob_idx), .flush_rob_flag(div_flush_rob_flag),
    .func3(div_func3), .is_word(div_is_word),
    .src1_rdata(div_src1_rdata), .src2_rdata(div_src2_rdata),
    .rob_idx(div_rob_idx), .rob_flag(div_rob_flag), .dest_preg(div_dest_preg), .dest_en(div_dest_en),
    .complete(div_complete),
    .wb_in2(div_wb_in2), .wake_valid(div_wake_valid), .wake_preg(div_wake_preg),
    .result(div_result), .done_rob_idx(div_done_rob_idx), .done_rob_flag(div_done_rob_flag),
    .done_dest_preg(div_done_dest_preg), .done_dest_en(div_done_dest_en)
  );
  assign exe2iss_div_wb_in2     = !rob_bcast_flush && div_wb_in2[0];
  assign exe2iss_div_wake_valid = !rob_bcast_flush && div_wake_valid[0];
  assign exe2iss_div_wake_preg  = div_wake_preg[0];

  for (genvar r = 0; r < N_FPU; r++) begin : g_unit
    localparam int KIND = xc_fu_kind(xc_fp_fu(r));
    logic [63:0] fresult;
    assign fu_fp_result[r] = XLEN_BITS'(fresult);
    assign fu_fp_fresult[r] = fresult;
    if (KIND == XC_K_FDIV) begin : g_div
      fp_div_unit u_fp (
        .clk(clk), .rst_n(rst_n), .en(exu2fu_fp_en[r]),
        .flush_all(exu2fu_flush_all), .flush_br(exu2fu_flush_br),
        .flush_rob_idx(exu2fu_flush_rob_idx), .flush_rob_flag(exu2fu_flush_rob_flag),
        .func3(exu2fu_fp_func3[r]),
        .func7(exu2fu_fp_func7[r]), .imm(exu2fu_fp_imm[r]), .src1_rdata(exu2fu_fp_src1_rdata[r]),
        .fsrc1(exu2fu_fp_fsrc1[r]), .fsrc2(exu2fu_fp_fsrc2[r]), .fsrc3(exu2fu_fp_fsrc3[r]), .frm(csr2exe_frm),
        .rob_idx(exu2fu_fp_rob_idx[r]), .rob_flag(exu2fu_fp_rob_flag[r]),
        .dest_preg(exu2fu_fp_dest_preg[r]), .dest_en(exu2fu_fp_dest_en[r]),
        .complete(fu_fp_complete[r]), .fresult(fresult),
        .fflags(fu_fp_fflags[r]), .illegal(fu_fp_illegal[r]),
        .done_rob_idx(fu_fp_rob_idx[r]), .done_rob_flag(fu_fp_rob_flag[r]),
        .done_dest_preg(fu_fp_dest_preg[r]), .done_dest_en(fu_fp_dest_en[r])
      );
    end else begin : g_pipe
      fp_pipe_unit #(
        .LAT((KIND == XC_K_FMA) ? FP_FMA_LAT : (KIND == XC_K_FMISC) ? FP_MISC_LAT : FP_I2F_LAT),
        .MODE((KIND == XC_K_FMA) ? 0 : (KIND == XC_K_FMISC) ? 1 : 2)
      ) u_fp (
        .clk(clk), .rst_n(rst_n), .en(exu2fu_fp_en[r]),
        .flush_all(exu2fu_flush_all), .flush_br(exu2fu_flush_br),
        .flush_rob_idx(exu2fu_flush_rob_idx), .flush_rob_flag(exu2fu_flush_rob_flag),
        .func3(exu2fu_fp_func3[r]),
        .imm(exu2fu_fp_imm[r]), .src1_rdata(exu2fu_fp_src1_rdata[r]),
        .fsrc1(exu2fu_fp_fsrc1[r]), .fsrc2(exu2fu_fp_fsrc2[r]), .fsrc3(exu2fu_fp_fsrc3[r]), .frm(csr2exe_frm),
        .rob_idx(exu2fu_fp_rob_idx[r]), .rob_flag(exu2fu_fp_rob_flag[r]),
        .dest_preg(exu2fu_fp_dest_preg[r]), .dest_en(exu2fu_fp_dest_en[r]),
        .complete(fu_fp_complete[r]), .fresult(fresult),
        .fflags(fu_fp_fflags[r]), .illegal(fu_fp_illegal[r]),
        .done_rob_idx(fu_fp_rob_idx[r]), .done_rob_flag(fu_fp_rob_flag[r]),
        .done_dest_preg(fu_fp_dest_preg[r]), .done_dest_en(fu_fp_dest_en[r])
      );
    end
  end

endmodule

`default_nettype wire
