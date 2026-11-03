// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (exe2lsu agu_req / sdu_req)
`default_nettype none

// Address-generation and store-data results go to the Lsu: AGU i of the LSU agu ports (loads 0..3, store-address 4..7)
// and SDU i. Each of these FUs is alone on its issue port, so its completion is the request.
module exu_ctrl_lsu_req
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  xc_done_t                  fu_done [N_FU],
  output logic                      agu_valid     [N_AGU],
  output logic [31:0]               agu_result    [N_AGU],
  output logic [PRF_IDX_WIDTH-1:0]  agu_dest_preg [N_AGU],
  output logic [2:0]                agu_func3     [N_AGU],
  output logic                      agu_is_atomic [N_AGU],
  output logic [4:0]                agu_amo_op    [N_AGU],
  output logic [ROB_IDX_WIDTH-1:0]  agu_rob_idx   [N_AGU],
  output logic                      agu_rob_flag  [N_AGU],
  output logic [STQ_IDX_WIDTH-1:0]  agu_stq_idx   [N_AGU],
  output logic                      agu_stq_flag  [N_AGU],
  output logic [LDQ_IDX_WIDTH-1:0]  agu_ldq_idx   [N_AGU],
  output logic                      sdu_valid     [N_SDU],
  output logic [31:0]               sdu_result    [N_SDU],
  output logic [ROB_IDX_WIDTH-1:0]  sdu_rob_idx   [N_SDU],
  output logic                      sdu_rob_flag  [N_SDU],
  output logic [STQ_IDX_WIDTH-1:0]  sdu_stq_idx   [N_SDU]
);

  for (genvar i = 0; i < N_AGU; i++) begin : g_agu
    localparam int FU = xc_agu_fu(i);
    assign agu_valid[i]     = fu_done[FU].complete;
    assign agu_result[i]    = fu_done[FU].result;
    assign agu_dest_preg[i] = fu_done[FU].dest_preg;
    assign agu_func3[i]     = fu_done[FU].func3;
    assign agu_is_atomic[i] = fu_done[FU].is_atomic;
    assign agu_amo_op[i]    = fu_done[FU].amo_op;
    assign agu_rob_idx[i]   = fu_done[FU].rob_idx;
    assign agu_rob_flag[i]  = fu_done[FU].rob_flag;
    assign agu_stq_idx[i]   = fu_done[FU].stq_idx;
    assign agu_stq_flag[i]  = fu_done[FU].stq_flag;
    assign agu_ldq_idx[i]   = fu_done[FU].ldq_idx;
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
