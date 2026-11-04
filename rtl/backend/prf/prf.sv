// Ref: back-end/Prf.cpp  class Prf  (reference model commit 2f31e8d)
`default_nettype none

// Physical register file: storage, write-back stage, operand read with bypass, FTQ PC read ports, load wake-up.
// Top level only adapts the flat spec ports to the sub-module interfaces (no logic of its own).
module prf import ttg_cfg_pkg::*; #(
  // UopType encoding width = ceil(log2(MAX_UOP_TYPE=18)) (base_types.h); not exported by ttg_cfg_pkg
  parameter int UOP_TYPE_WIDTH = 5
) (
  input  logic clk,
  input  logic rst_n,
  input  logic dec_bcast_mispred,
  input  logic [BR_MASK_WIDTH-1:0] dec_bcast_br_mask,
  input  logic [BR_MASK_WIDTH-1:0] dec_bcast_clear_mask,
  input  logic rob_bcast_flush,
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_valid,
  input  logic [PRF_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_dest_preg [ISSUE_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_src1_preg [ISSUE_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_src2_preg [ISSUE_WIDTH],
  input  logic [FTQ_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_ftq_idx [ISSUE_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] iss2prf_iss_entry_uop_ftq_offset [ISSUE_WIDTH],
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_is_atomic,
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_dest_en,
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src1_en,
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src2_en,
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src1_is_pc,
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src2_is_imm,
  input  logic [2:0] iss2prf_iss_entry_uop_func3 [ISSUE_WIDTH],
  input  logic [6:0] iss2prf_iss_entry_uop_func7 [ISSUE_WIDTH],
  input  logic [31:0] iss2prf_iss_entry_uop_imm [ISSUE_WIDTH],
  input  logic [BR_TAG_WIDTH-1:0] iss2prf_iss_entry_uop_br_id [ISSUE_WIDTH],
  input  logic [BR_MASK_WIDTH-1:0] iss2prf_iss_entry_uop_br_mask [ISSUE_WIDTH],
  input  logic [CSR_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_csr_idx [ISSUE_WIDTH],
  input  logic [ROB_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_rob_idx [ISSUE_WIDTH],
  input  logic [STQ_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_stq_idx [ISSUE_WIDTH],
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_stq_flag,
  input  logic [LDQ_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_ldq_idx [ISSUE_WIDTH],
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_rob_flag,
  input  logic [UOP_TYPE_WIDTH-1:0] iss2prf_iss_entry_uop_op [ISSUE_WIDTH],
  input  logic [ISSUE_WIDTH-1:0] exe2prf_entry_valid,
  input  logic [PRF_IDX_WIDTH-1:0] exe2prf_entry_uop_dest_preg [ISSUE_WIDTH],
  input  logic [31:0] exe2prf_entry_uop_result [ISSUE_WIDTH],
  input  logic [BR_MASK_WIDTH-1:0] exe2prf_entry_uop_br_mask [ISSUE_WIDTH],
  input  logic [ISSUE_WIDTH-1:0] exe2prf_entry_uop_dest_en,
  input  logic [UOP_TYPE_WIDTH-1:0] exe2prf_entry_uop_op [ISSUE_WIDTH],
  input  logic [TOTAL_FU_COUNT-1:0] exe2prf_bypass_valid,
  input  logic [PRF_IDX_WIDTH-1:0] exe2prf_bypass_uop_dest_preg [TOTAL_FU_COUNT],
  input  logic [31:0] exe2prf_bypass_uop_result [TOTAL_FU_COUNT],
  input  logic [TOTAL_FU_COUNT-1:0] exe2prf_bypass_uop_dest_en,
  input  logic [31:0] ftq_prf_pc_resp_resp_pc [FTQ_PRF_PC_PORT_NUM],
  input  logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_resp_resp_pred_taken,
  input  logic [31:0] ftq_prf_pc_resp_resp_next_pc [FTQ_PRF_PC_PORT_NUM],
  output logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_req_req_valid,
  output logic [FTQ_IDX_WIDTH-1:0] ftq_prf_pc_req_req_ftq_idx [FTQ_PRF_PC_PORT_NUM],
  output logic [FTQ_OFFSET_WIDTH-1:0] ftq_prf_pc_req_req_ftq_offset [FTQ_PRF_PC_PORT_NUM],
  output logic [LSU_LOAD_WB_WIDTH-1:0] prf_awake_wake_valid,
  output logic [PRF_IDX_WIDTH-1:0] prf_awake_wake_preg [LSU_LOAD_WB_WIDTH],
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_valid,
  output logic [31:0] prf2exe_iss_entry_uop_pc [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_ftq_pred_taken,
  output logic [31:0] prf2exe_iss_entry_uop_ftq_next_pc [ISSUE_WIDTH],
  output logic [31:0] prf2exe_iss_entry_uop_src1_rdata [ISSUE_WIDTH],
  output logic [31:0] prf2exe_iss_entry_uop_src2_rdata [ISSUE_WIDTH],
  output logic [PRF_IDX_WIDTH-1:0] prf2exe_iss_entry_uop_dest_preg [ISSUE_WIDTH],
  output logic [FTQ_IDX_WIDTH-1:0] prf2exe_iss_entry_uop_ftq_idx [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_is_atomic,
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_dest_en,
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_src1_en,
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_src1_is_pc,
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_src2_is_imm,
  output logic [2:0] prf2exe_iss_entry_uop_func3 [ISSUE_WIDTH],
  output logic [6:0] prf2exe_iss_entry_uop_func7 [ISSUE_WIDTH],
  output logic [31:0] prf2exe_iss_entry_uop_imm [ISSUE_WIDTH],
  output logic [BR_TAG_WIDTH-1:0] prf2exe_iss_entry_uop_br_id [ISSUE_WIDTH],
  output logic [BR_MASK_WIDTH-1:0] prf2exe_iss_entry_uop_br_mask [ISSUE_WIDTH],
  output logic [CSR_IDX_WIDTH-1:0] prf2exe_iss_entry_uop_csr_idx [ISSUE_WIDTH],
  output logic [ROB_IDX_WIDTH-1:0] prf2exe_iss_entry_uop_rob_idx [ISSUE_WIDTH],
  output logic [STQ_IDX_WIDTH-1:0] prf2exe_iss_entry_uop_stq_idx [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_stq_flag,
  output logic [LDQ_IDX_WIDTH-1:0] prf2exe_iss_entry_uop_ldq_idx [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_rob_flag,
  output logic [UOP_TYPE_WIDTH-1:0] prf2exe_iss_entry_uop_op [ISSUE_WIDTH]
);

  localparam int LANES = ISSUE_WIDTH;
  localparam logic [UOP_TYPE_WIDTH-1:0] UOP_LOAD = UOP_TYPE_WIDTH'(3);   // enum UopType: UOP_LOAD

  // ---- adaptation: per-lane vectors and [src][lane] arrays ----
  logic [LANES-1:0]          exe_valid_vec, exe_dest_en_vec, exe_is_load_vec;
  logic [LANES-1:0]          wb_wen_q, wb_is_load_q;
  logic [PRF_IDX_WIDTH-1:0]  wb_dest_preg_q [LANES];
  logic [31:0]               wb_result_q    [LANES];
  logic [BR_MASK_WIDTH-1:0]  wb_br_mask_q   [LANES];
  logic [TOTAL_FU_COUNT-1:0] fu_wen_vec;
  logic                      src_en_arr   [2][LANES];
  logic [PRF_IDX_WIDTH-1:0]  src_preg_arr [2][LANES];
  logic [31:0]               rf_rdata     [2][LANES];
  logic [31:0]               src_rdata    [2][LANES];
  logic [PRF_NUM-1:0]        reg_wr_en;
  logic [31:0]               reg_wr_data  [PRF_NUM];
  logic [ALU_NUM-1:0]        alu_valid_vec, alu_src1_is_pc_vec;
  logic [BRU_NUM-1:0]        br_valid_vec;
  logic [UOP_TYPE_WIDTH-1:0] alu_op [ALU_NUM];
  logic [UOP_TYPE_WIDTH-1:0] br_op  [BRU_NUM];
  logic [FTQ_PRF_PC_PORT_NUM-1:0] req_valid_vec;
  logic [LSU_LOAD_WB_WIDTH-1:0]   wake_valid_vec;

  for (genvar i = 0; i < LANES; i++) begin : g_lane
    assign exe_valid_vec[i]   = exe2prf_entry_valid[i];
    assign exe_dest_en_vec[i] = exe2prf_entry_uop_dest_en[i];
    assign exe_is_load_vec[i] = exe2prf_entry_uop_op[i] == UOP_LOAD;
    assign src_en_arr[0][i]   = iss2prf_iss_entry_uop_src1_en[i];
    assign src_en_arr[1][i]   = iss2prf_iss_entry_uop_src2_en[i];
    assign src_preg_arr[0][i] = iss2prf_iss_entry_uop_src1_preg[i];
    assign src_preg_arr[1][i] = iss2prf_iss_entry_uop_src2_preg[i];
    assign prf2exe_iss_entry_valid[i]          = iss2prf_iss_entry_valid[i];
    assign prf2exe_iss_entry_uop_src1_rdata[i] = src_rdata[0][i];
    assign prf2exe_iss_entry_uop_src2_rdata[i] = src_rdata[1][i];
    assign prf2exe_iss_entry_uop_dest_preg[i] = iss2prf_iss_entry_uop_dest_preg[i];
    assign prf2exe_iss_entry_uop_ftq_idx[i] = iss2prf_iss_entry_uop_ftq_idx[i];
    assign prf2exe_iss_entry_uop_is_atomic[i] = iss2prf_iss_entry_uop_is_atomic[i];
    assign prf2exe_iss_entry_uop_dest_en[i] = iss2prf_iss_entry_uop_dest_en[i];
    assign prf2exe_iss_entry_uop_src1_en[i] = iss2prf_iss_entry_uop_src1_en[i];
    assign prf2exe_iss_entry_uop_src1_is_pc[i] = iss2prf_iss_entry_uop_src1_is_pc[i];
    assign prf2exe_iss_entry_uop_src2_is_imm[i] = iss2prf_iss_entry_uop_src2_is_imm[i];
    assign prf2exe_iss_entry_uop_func3[i] = iss2prf_iss_entry_uop_func3[i];
    assign prf2exe_iss_entry_uop_func7[i] = iss2prf_iss_entry_uop_func7[i];
    assign prf2exe_iss_entry_uop_imm[i] = iss2prf_iss_entry_uop_imm[i];
    assign prf2exe_iss_entry_uop_br_id[i] = iss2prf_iss_entry_uop_br_id[i];
    assign prf2exe_iss_entry_uop_br_mask[i] = iss2prf_iss_entry_uop_br_mask[i];
    assign prf2exe_iss_entry_uop_csr_idx[i] = iss2prf_iss_entry_uop_csr_idx[i];
    assign prf2exe_iss_entry_uop_rob_idx[i] = iss2prf_iss_entry_uop_rob_idx[i];
    assign prf2exe_iss_entry_uop_stq_idx[i] = iss2prf_iss_entry_uop_stq_idx[i];
    assign prf2exe_iss_entry_uop_stq_flag[i] = iss2prf_iss_entry_uop_stq_flag[i];
    assign prf2exe_iss_entry_uop_ldq_idx[i] = iss2prf_iss_entry_uop_ldq_idx[i];
    assign prf2exe_iss_entry_uop_rob_flag[i] = iss2prf_iss_entry_uop_rob_flag[i];
    assign prf2exe_iss_entry_uop_op[i] = iss2prf_iss_entry_uop_op[i];
  end
  for (genvar k = 0; k < TOTAL_FU_COUNT; k++) begin : g_fu
    assign fu_wen_vec[k] = exe2prf_bypass_valid[k] && exe2prf_bypass_uop_dest_en[k];
  end
  for (genvar k = 0; k < LSU_LOAD_WB_WIDTH; k++) begin : g_wake
    assign prf_awake_wake_valid[k] = wake_valid_vec[k];
  end

  // ---- write-back stage ----
  prf_wb_pipe #(.LANES(LANES)) u_wb_pipe (
    .clk, .rst_n,
    .flush            (rob_bcast_flush),
    .bcast_mispred    (dec_bcast_mispred),
    .bcast_br_mask    (dec_bcast_br_mask),
    .bcast_clear_mask (dec_bcast_clear_mask),
    .exe_valid        (exe_valid_vec),
    .exe_dest_en      (exe_dest_en_vec),
    .exe_is_load      (exe_is_load_vec),
    .exe_dest_preg    (exe2prf_entry_uop_dest_preg),
    .exe_result       (exe2prf_entry_uop_result),
    .exe_br_mask      (exe2prf_entry_uop_br_mask),
    .wb_wen_q, .wb_is_load_q, .wb_dest_preg_q, .wb_result_q, .wb_br_mask_q
  );

  // ---- register file + write ports ----
  prf_write_arb #(.LANES(LANES), .NREG(PRF_NUM)) u_write_arb (
    .wb_wen       (wb_wen_q),
    .wb_dest_preg (wb_dest_preg_q),
    .wb_result    (wb_result_q),
    .reg_wr_en, .reg_wr_data
  );

  prf_regfile #(.NREG(PRF_NUM), .LANES(LANES)) u_regfile (
    .clk, .rst_n, .reg_wr_en, .reg_wr_data,
    .rd_addr (src_preg_arr),
    .rd_data (rf_rdata)
  );

  // ---- operand read ports with bypass: 2 per issue lane ----
  for (genvar s = 0; s < 2; s++) begin : g_src
    for (genvar i = 0; i < LANES; i++) begin : g_rd
      prf_bypass #(.WB_LANES(LANES), .FU_NUM(TOTAL_FU_COUNT)) u_bypass (
        .src_en       (src_en_arr[s][i]),
        .src_preg     (src_preg_arr[s][i]),
        .rf_data      (rf_rdata[s][i]),
        .wb_wen       (wb_wen_q),
        .wb_dest_preg (wb_dest_preg_q),
        .wb_result    (wb_result_q),
        .fu_wen       (fu_wen_vec),
        .fu_dest_preg (exe2prf_bypass_uop_dest_preg),
        .fu_result    (exe2prf_bypass_uop_result),
        .rdata        (src_rdata[s][i])
      );
    end
  end

  // ---- FTQ PC read: ALU lanes -> ports 0.., branch lanes -> next ports; answers go straight back to the lane ----
  for (genvar i = 0; i < ALU_NUM; i++) begin : g_alu_pc
    assign alu_valid_vec[i]      = iss2prf_iss_entry_valid[IQ_ALU_PORT_BASE+i];
    assign alu_src1_is_pc_vec[i] = iss2prf_iss_entry_uop_src1_is_pc[IQ_ALU_PORT_BASE+i];
    assign alu_op[i]             = iss2prf_iss_entry_uop_op[IQ_ALU_PORT_BASE+i];
  end
  for (genvar i = 0; i < BRU_NUM; i++) begin : g_br_pc
    assign br_valid_vec[i] = iss2prf_iss_entry_valid[IQ_BR_PORT_BASE+i];
    assign br_op[i]        = iss2prf_iss_entry_uop_op[IQ_BR_PORT_BASE+i];
  end

  prf_pc_port #(.UOP_TYPE_WIDTH(UOP_TYPE_WIDTH), .NALU(ALU_NUM), .NBR(BRU_NUM)) u_pc_port (
    .alu_valid (alu_valid_vec), .alu_op, .alu_src1_is_pc (alu_src1_is_pc_vec),
    .br_valid  (br_valid_vec),  .br_op,
    .req_valid (req_valid_vec)
  );

  for (genvar p = 0; p < FTQ_PRF_PC_PORT_NUM; p++) begin : g_port
    localparam int LANE = (p < ALU_NUM) ? IQ_ALU_PORT_BASE + p : IQ_BR_PORT_BASE + (p - ALU_NUM);
    assign ftq_prf_pc_req_req_valid[p]      = req_valid_vec[p];
    assign ftq_prf_pc_req_req_ftq_idx[p]    = iss2prf_iss_entry_uop_ftq_idx[LANE];
    assign ftq_prf_pc_req_req_ftq_offset[p] = iss2prf_iss_entry_uop_ftq_offset[LANE];
    assign prf2exe_iss_entry_uop_pc[LANE]             = ftq_prf_pc_resp_resp_pc[p];
    assign prf2exe_iss_entry_uop_ftq_pred_taken[LANE] = ftq_prf_pc_resp_resp_pred_taken[p];
    assign prf2exe_iss_entry_uop_ftq_next_pc[LANE]    = ftq_prf_pc_resp_resp_next_pc[p];
  end
  // lanes without a PC port never receive a PC
  for (genvar i = 0; i < LANES; i++) begin : g_nopc
    if (!((i >= IQ_ALU_PORT_BASE && i < IQ_ALU_PORT_BASE + ALU_NUM) ||
          (i >= IQ_BR_PORT_BASE && i < IQ_BR_PORT_BASE + BRU_NUM))) begin : g_tie
      assign prf2exe_iss_entry_uop_pc[i]             = '0;
      assign prf2exe_iss_entry_uop_ftq_pred_taken[i] = 1'b0;
      assign prf2exe_iss_entry_uop_ftq_next_pc[i]    = '0;
    end
  end

  // ---- load wake-up ----
  prf_awake #(.LANES(LANES), .WAKE_NUM(LSU_LOAD_WB_WIDTH)) u_awake (
    .wb_wen         (wb_wen_q),
    .wb_is_load     (wb_is_load_q),
    .wb_dest_preg   (wb_dest_preg_q),
    .wb_br_mask     (wb_br_mask_q),
    .bcast_mispred  (dec_bcast_mispred),
    .bcast_br_mask  (dec_bcast_br_mask),
    .wake_valid     (wake_valid_vec),
    .wake_preg      (prf_awake_wake_preg)
  );

endmodule

`default_nettype wire
