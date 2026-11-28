// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (exe2lsu agu_req / sdu_req)
`default_nettype none

// Address-generation (unified 5 physical AGUs) and store-data results go to the Lsu.
module exu_ctrl_lsu_req
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  logic [N_FU-1:0]          fu_occ,
  input  xc_done_t                 fu_done [N_FU],
  output xc_agu_req_t              exe2lsu_agu [N_AGU],
  output logic [N_SDU-1:0]         sdu_valid,
  output logic [XLEN_BITS-1:0]     sdu_result    [N_SDU],
  output logic [ROB_IDX_WIDTH-1:0] sdu_rob_idx   [N_SDU],
  output logic [N_SDU-1:0]         sdu_rob_flag,
  output logic [STQ_IDX_WIDTH-1:0] sdu_stq_idx   [N_SDU]
);

  for (genvar i = 0; i < N_AGU; i++) begin : g_agu
    localparam int FU = xc_agu_fu(i);
    assign exe2lsu_agu[i] = '{
      valid:     fu_done[FU].complete,
      raw:       fu_occ[FU],
      op:        fu_done[FU].op,
      result:    fu_done[FU].result,
      dest_preg: fu_done[FU].dest_preg,
      func3:     fu_done[FU].func3,
      is_atomic: fu_done[FU].is_atomic,
      amo_op:    fu_done[FU].amo_op,
      rob_idx:   fu_done[FU].rob_idx,
      rob_flag:  fu_done[FU].rob_flag,
      stq_idx:   fu_done[FU].stq_idx,
      stq_flag:  fu_done[FU].stq_flag,
      ldq_idx:   fu_done[FU].ldq_idx
    };
  end

  for (genvar i = 0; i < N_SDU; i++) begin : g_sdu
    localparam int FU = xc_kind_fu(XC_K_STD, i);
    assign sdu_valid[i]    = fu_done[FU].complete;
    assign sdu_result[i]   = fu_done[FU].result;
    assign sdu_rob_idx[i]  = fu_done[FU].rob_idx;
    assign sdu_rob_flag[i] = fu_done[FU].rob_flag;
    assign sdu_stq_idx[i]  = fu_done[FU].stq_idx;
  end

endmodule

`default_nettype wire
