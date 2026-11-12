// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (Lsu requests: agu 0..3 loads, 4..7 store-address)
`default_nettype none

// Lsu request ports of the Exu: the AGU results of the load / store-address FUs become the Lsu's ldu / sta requests,
// the SDU results its store-data requests (port adapter around exu_ctrl_lsu_req).
module exu_ctrl_lsu_out
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  xc_done_t fu_done [N_FU],
  output logic [LSU_LDU_COUNT-1:0] exe2lsu_ldu_req_valid,
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
  output logic [STQ_IDX_WIDTH-1:0] exe2lsu_sdu_req_uop_stq_idx [LSU_SDU_COUNT]
);

  // ---- Lsu requests: agu 0..3 loads, 4..7 store-address (the Lsu's ldu / sta ports) -----------------------------
  logic [N_AGU-1:0] agu_valid;
  logic [XLEN_BITS-1:0]              agu_result    [N_AGU];
  logic [PRF_IDX_WIDTH-1:0] agu_dest_preg [N_AGU];
  logic [2:0]               agu_func3     [N_AGU];
  logic [N_AGU-1:0] agu_is_atomic;
  logic [4:0]               agu_amo_op    [N_AGU];
  logic [ROB_IDX_WIDTH-1:0] agu_rob_idx   [N_AGU];
  logic [N_AGU-1:0] agu_rob_flag;
  logic [STQ_IDX_WIDTH-1:0] agu_stq_idx   [N_AGU];
  /* verilator lint_off UNUSEDSIGNAL */  // only the load lanes (the first LSU_LDU_COUNT AGUs) read the stq flag
  logic [N_AGU-1:0] agu_stq_flag;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [LDQ_IDX_WIDTH-1:0] agu_ldq_idx   [N_AGU];

  exu_ctrl_lsu_req u_lsu (
    .fu_done,
    .agu_valid, .agu_result, .agu_dest_preg, .agu_func3, .agu_is_atomic, .agu_amo_op, .agu_rob_idx, .agu_rob_flag,
    .agu_stq_idx, .agu_stq_flag, .agu_ldq_idx,
    .sdu_valid(exe2lsu_sdu_req_valid), .sdu_result(exe2lsu_sdu_req_uop_result),
    .sdu_rob_idx(exe2lsu_sdu_req_uop_rob_idx), .sdu_rob_flag(exe2lsu_sdu_req_uop_rob_flag),
    .sdu_stq_idx(exe2lsu_sdu_req_uop_stq_idx)
  );

  for (genvar i = 0; i < LSU_LDU_COUNT; i++) begin : g_ldu
    assign exe2lsu_ldu_req_valid[i]          = agu_valid[i];
    assign exe2lsu_ldu_req_uop_result[i]     = agu_result[i];
    assign exe2lsu_ldu_req_uop_dest_preg[i]  = agu_dest_preg[i];
    assign exe2lsu_ldu_req_uop_func3[i]      = agu_func3[i];
    assign exe2lsu_ldu_req_uop_is_atomic[i]  = agu_is_atomic[i];
    assign exe2lsu_ldu_req_uop_amo_op[i]     = agu_amo_op[i];
    assign exe2lsu_ldu_req_uop_rob_idx[i]    = agu_rob_idx[i];
    assign exe2lsu_ldu_req_uop_rob_flag[i]   = agu_rob_flag[i];
    assign exe2lsu_ldu_req_uop_stq_idx[i]    = agu_stq_idx[i];
    assign exe2lsu_ldu_req_uop_stq_flag[i]   = agu_stq_flag[i];
    assign exe2lsu_ldu_req_uop_ldq_idx[i]    = agu_ldq_idx[i];
  end

  for (genvar i = 0; i < LSU_STA_COUNT; i++) begin : g_sta
    assign exe2lsu_sta_req_valid[i]          = agu_valid[LSU_LDU_COUNT+i];
    assign exe2lsu_sta_req_uop_result[i]     = agu_result[LSU_LDU_COUNT+i];
    assign exe2lsu_sta_req_uop_dest_preg[i]  = agu_dest_preg[LSU_LDU_COUNT+i];
    assign exe2lsu_sta_req_uop_func3[i]      = agu_func3[LSU_LDU_COUNT+i];
    assign exe2lsu_sta_req_uop_is_atomic[i]  = agu_is_atomic[LSU_LDU_COUNT+i];
    assign exe2lsu_sta_req_uop_amo_op[i]     = agu_amo_op[LSU_LDU_COUNT+i];
    assign exe2lsu_sta_req_uop_rob_idx[i]    = agu_rob_idx[LSU_LDU_COUNT+i];
    assign exe2lsu_sta_req_uop_rob_flag[i]   = agu_rob_flag[LSU_LDU_COUNT+i];
    assign exe2lsu_sta_req_uop_stq_idx[i]    = agu_stq_idx[LSU_LDU_COUNT+i];
  end


endmodule

`default_nettype wire
