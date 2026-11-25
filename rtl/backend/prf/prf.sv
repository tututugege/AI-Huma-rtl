// Ref: back-end/Prf.cpp  class Prf  (reference model commit 2f31e8d)
`default_nettype none

// Physical register file: storage, write-back stage, operand read with bypass, FTQ PC read ports, load wake-up.
// Top level only adapts the flat spec ports to the sub-module interfaces (no logic of its own).
module prf import ttg_cfg_pkg::*; import fp_pkg::*; #(
  // UopType encoding width = ceil(log2(MAX_UOP_TYPE=18)) (base_types.h); not exported by ttg_cfg_pkg
  parameter int UOP_TYPE_WIDTH = 5
) (
  input  logic clk,
  input  logic rst_n,
  input  logic dec_bcast_mispred,
  input  logic [ROB_IDX_WIDTH-1:0] dec_bcast_redirect_rob_idx,
  input  logic dec_bcast_redirect_rob_flag,
  input  logic rob_bcast_flush,
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_valid,
  input  logic [PRF_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_dest_preg [ISSUE_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_src1_preg [ISSUE_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_src2_preg [ISSUE_WIDTH],
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: read only by the FP / store-data lanes
  input  logic [PRF_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_src3_preg [ISSUE_WIDTH],
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src3_en,
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src1_fp,
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src2_fp,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [FTQ_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_ftq_idx [ISSUE_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] iss2prf_iss_entry_uop_ftq_offset [ISSUE_WIDTH],
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_is_atomic,
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_dest_en,
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src1_en,
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src2_en,
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src1_is_pc,
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src2_is_imm,
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_is_word,
  input  logic [2:0] iss2prf_iss_entry_uop_func3 [ISSUE_WIDTH],
  input  logic [6:0] iss2prf_iss_entry_uop_func7 [ISSUE_WIDTH],
  input  logic [31:0] iss2prf_iss_entry_uop_imm [ISSUE_WIDTH],
  input  logic [CSR_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_csr_idx [ISSUE_WIDTH],
  input  logic [ROB_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_rob_idx [ISSUE_WIDTH],
  input  logic [STQ_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_stq_idx [ISSUE_WIDTH],
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_stq_flag,
  input  logic [LDQ_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_ldq_idx [ISSUE_WIDTH],
  input  logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_rob_flag,
  input  logic [UOP_TYPE_WIDTH-1:0] iss2prf_iss_entry_uop_op [ISSUE_WIDTH],
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: only integer-reading lanes use the 6-bit EXU bypass mask
  input  logic [ALU_NUM-1:0] iss2prf_iss_entry_uop_src1_byp [ISSUE_WIDTH],
  input  logic [ALU_NUM-1:0] iss2prf_iss_entry_uop_src2_byp [ISSUE_WIDTH],
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [WB_LANES-1:0] exe2prf_entry_valid,
  input  logic [PRF_IDX_WIDTH-1:0] exe2prf_entry_uop_dest_preg [WB_LANES],
  input  logic [XLEN_BITS-1:0] exe2prf_entry_uop_result [WB_LANES],
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: unused without F/D
  input  logic [FW-1:0] exe2prf_entry_uop_fresult [WB_LANES],
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [ROB_IDX_WIDTH-1:0] exe2prf_entry_uop_rob_idx [WB_LANES],
  input  logic [WB_LANES-1:0] exe2prf_entry_uop_rob_flag,
  input  logic [WB_LANES-1:0] exe2prf_entry_uop_dest_en,
  input  logic [UOP_TYPE_WIDTH-1:0] exe2prf_entry_uop_op [WB_LANES],
  // LSU write-back requests of this cycle as a bypass source (LP_L2 speculative wake-up: the consumer reads the load
  // result in the cycle of the write-back request); all zero otherwise
  input  logic [LSU_LOAD_WB_WIDTH-1:0] lsu_byp_valid,
  input  logic [PRF_IDX_WIDTH-1:0] lsu_byp_dest_preg [LSU_LOAD_WB_WIDTH],
  input  logic [XLEN_BITS-1:0] lsu_byp_result [LSU_LOAD_WB_WIDTH],
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: only the F/D load path reads it
  input  logic [LSU_LOAD_WB_WIDTH-1:0] lsu_byp_is_w,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [XLEN_BITS-1:0] ftq_prf_pc_resp_resp_pc [FTQ_PRF_PC_PORT_NUM],
  input  logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_resp_resp_pred_taken,
  input  logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_resp_resp_is_rvc,
  input  logic [XLEN_BITS-1:0] ftq_prf_pc_resp_resp_next_pc [FTQ_PRF_PC_PORT_NUM],
  output logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_req_req_valid,
  output logic [FTQ_IDX_WIDTH-1:0] ftq_prf_pc_req_req_ftq_idx [FTQ_PRF_PC_PORT_NUM],
  output logic [FTQ_OFFSET_WIDTH-1:0] ftq_prf_pc_req_req_ftq_offset [FTQ_PRF_PC_PORT_NUM],
  output logic [LSU_LOAD_WB_WIDTH-1:0] prf_awake_wake_valid,
  output logic [PRF_IDX_WIDTH-1:0] prf_awake_wake_preg [LSU_LOAD_WB_WIDTH],
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_valid,
  output logic [XLEN_BITS-1:0] prf2exe_iss_entry_uop_pc [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_ftq_pred_taken,
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_ftq_is_rvc,
  output logic [XLEN_BITS-1:0] prf2exe_iss_entry_uop_ftq_next_pc [ISSUE_WIDTH],
  output logic [XLEN_BITS-1:0] prf2exe_iss_entry_uop_src1_rdata [ISSUE_WIDTH],
  output logic [XLEN_BITS-1:0] prf2exe_iss_entry_uop_src2_rdata [ISSUE_WIDTH],
  output logic [FW-1:0] prf2exe_iss_entry_uop_fsrc1 [ISSUE_WIDTH],
  output logic [FW-1:0] prf2exe_iss_entry_uop_fsrc2 [ISSUE_WIDTH],
  output logic [FW-1:0] prf2exe_iss_entry_uop_fsrc3 [ISSUE_WIDTH],
  output logic [PRF_IDX_WIDTH-1:0] prf2exe_iss_entry_uop_dest_preg [ISSUE_WIDTH],
  output logic [FTQ_IDX_WIDTH-1:0] prf2exe_iss_entry_uop_ftq_idx [ISSUE_WIDTH],
  output logic [FTQ_OFFSET_WIDTH-1:0] prf2exe_iss_entry_uop_ftq_offset [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_is_atomic,
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_dest_en,
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_src1_en,
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_src1_is_pc,
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_src2_is_imm,
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_is_word,
  output logic [2:0] prf2exe_iss_entry_uop_func3 [ISSUE_WIDTH],
  output logic [6:0] prf2exe_iss_entry_uop_func7 [ISSUE_WIDTH],
  output logic [31:0] prf2exe_iss_entry_uop_imm [ISSUE_WIDTH],
  output logic [CSR_IDX_WIDTH-1:0] prf2exe_iss_entry_uop_csr_idx [ISSUE_WIDTH],
  output logic [ROB_IDX_WIDTH-1:0] prf2exe_iss_entry_uop_rob_idx [ISSUE_WIDTH],
  output logic [STQ_IDX_WIDTH-1:0] prf2exe_iss_entry_uop_stq_idx [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_stq_flag,
  output logic [LDQ_IDX_WIDTH-1:0] prf2exe_iss_entry_uop_ldq_idx [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0] prf2exe_iss_entry_uop_rob_flag,
  output logic [UOP_TYPE_WIDTH-1:0] prf2exe_iss_entry_uop_op [ISSUE_WIDTH]
);

  localparam int NIP = ISSUE_WIDTH;   // issue lanes
  localparam int WL  = WB_LANES;      // register write-back lanes (EXP-046, config.h WB_*): ALU, load, F/D lanes
  localparam logic [UOP_TYPE_WIDTH-1:0] UOP_LOAD = UOP_TYPE_WIDTH'(3);   // enum UopType: UOP_LOAD
  localparam bit HAS_LSU_BYP = ((lp_pkg::LP_L2 & 9) == 9);   // speculative load wake-up bypass (LP_L2[0] & LP_L2[3])

  // ---- adaptation: per-lane vectors ----
  logic [WL-1:0]             exe_valid_vec, exe_dest_en_vec, exe_is_load_vec;
  logic [WL-1:0]             wb_wen_q, wb_is_load_q;
  logic [PRF_IDX_WIDTH-1:0]  wb_dest_preg_q [WL];
  logic [XLEN_BITS-1:0]      wb_result_q    [WL];
  logic [ROB_IDX_WIDTH-1:0]  wb_rob_idx_q   [WL];
  logic [WL-1:0]             wb_rob_flag_q;
  logic [PRF_NUM-1:0]        reg_wr_en;
  logic [XLEN_BITS-1:0]      reg_wr_data  [PRF_NUM];
  logic [ALU_NUM-1:0]        alu_valid_vec, alu_src1_is_pc_vec;
  logic [BRU_NUM-1:0]        br_valid_vec;
  logic [UOP_TYPE_WIDTH-1:0] alu_op [ALU_NUM];
  logic [UOP_TYPE_WIDTH-1:0] br_op  [BRU_NUM];
  logic [FTQ_PRF_PC_PORT_NUM-1:0] req_valid_vec;
  logic [LSU_LOAD_WB_WIDTH-1:0]   wake_valid_vec;

  // Shared AGUs (LSU_AGU_SHARED): the last NSH STA lanes use the AGU of the last NSH load lanes, so they also share its src1 read
  // port (the base register). The load lane's read port takes the STA lane's address when that lane issues (a granted load wins in
  // the issue stage, so both never issue together); the STA lane's own read port is not used and its data is the load lane's.
  localparam int NSH       = LSU_AGU_SHARED;
  localparam int SH_LD_LO  = IQ_LD_PORT_BASE + LSU_LDU_COUNT - NSH;     // first shared load lane
  localparam int SH_STA_LO = IQ_STA_PORT_BASE + LSU_STA_COUNT - NSH;    // first shared STA lane
  function automatic bit lane_sh_ld(int i);
    return NSH > 0 && i >= SH_LD_LO && i < SH_LD_LO + NSH;
  endfunction
  function automatic bit lane_sh_sta(int i);
    return NSH > 0 && i >= SH_STA_LO && i < SH_STA_LO + NSH;
  endfunction
  function automatic bit lane_is_fp(int i);
    return FP_EN && (i >= IQ_FP_PORT_BASE);
  endfunction
  function automatic bit lane_is_agu(int i);
    return (i >= IQ_LD_PORT_BASE) && (i < IQ_STD_PORT_BASE);
  endfunction
  function automatic bit lane_is_std(int i);
    return FP_EN && (i >= IQ_STD_PORT_BASE) && (i < IQ_STD_PORT_BASE + LSU_SDU_COUNT);
  endfunction
  // Integer read ports actually needed:
  //   src1: every non-FP lane except shared STA lanes (which borrow their paired load lane's src1 port)
  //   src2: every non-FP, non-AGU lane (AGU uses src1 + imm only)
  function automatic bit int_rd_need(int s, int i);
    if (lane_is_fp(i)) return 1'b0;
    if (s == 0) return !lane_sh_sta(i);
    return !lane_is_agu(i);
  endfunction
  function automatic int int_rd_count();
    int n = 0;
    for (int s = 0; s < 2; s++)
      for (int i = 0; i < NIP; i++) n += int'(int_rd_need(s, i));
    return n;
  endfunction
  function automatic int int_rd_idx(int s, int i);
    int n = 0;
    for (int ss = 0; ss < 2; ss++)
      for (int ii = 0; ii < NIP; ii++) begin
        if (ss == s && ii == i) return n;
        n += int'(int_rd_need(ss, ii));
      end
    return n;
  endfunction

  localparam int N_INT_RD = int_rd_count();

  logic                      int_rd_en   [N_INT_RD];
  logic [PRF_IDX_WIDTH-1:0]  int_rd_preg [N_INT_RD];
  logic [ALU_NUM-1:0]        int_rd_byp  [N_INT_RD];
  logic [XLEN_BITS-1:0]      int_rf_data [N_INT_RD];
  logic [XLEN_BITS-1:0]      int_rdata   [N_INT_RD];
  logic [XLEN_BITS-1:0]      src_rdata   [2][NIP];

  for (genvar l = 0; l < WL; l++) begin : g_wl
    assign exe_valid_vec[l]   = exe2prf_entry_valid[l];
    assign exe_dest_en_vec[l] = exe2prf_entry_uop_dest_en[l];
    assign exe_is_load_vec[l] = exe2prf_entry_uop_op[l] == UOP_LOAD;
  end
  for (genvar i = 0; i < NIP; i++) begin : g_lane
    if (lane_sh_ld(i)) begin : g_sh_ld
      localparam int S = SH_STA_LO + (i - SH_LD_LO);   // the STA lane that shares this port
      localparam int R0 = int_rd_idx(0, i);
      assign int_rd_en[R0]   = iss2prf_iss_entry_valid[S] ? iss2prf_iss_entry_uop_src1_en[S] : iss2prf_iss_entry_uop_src1_en[i];
      assign int_rd_preg[R0] = iss2prf_iss_entry_valid[S] ? iss2prf_iss_entry_uop_src1_preg[S] : iss2prf_iss_entry_uop_src1_preg[i];
      assign int_rd_byp[R0]  = iss2prf_iss_entry_valid[S] ? iss2prf_iss_entry_uop_src1_byp[S] : iss2prf_iss_entry_uop_src1_byp[i];
      assign src_rdata[0][i] = int_rdata[R0];
      assign prf2exe_iss_entry_uop_src1_rdata[i] = src_rdata[0][i];
    end else if (lane_sh_sta(i)) begin : g_sh_sta
      localparam int L = SH_LD_LO + (i - SH_STA_LO);   // the load lane whose read port this lane uses
      assign src_rdata[0][i] = '0;
      assign prf2exe_iss_entry_uop_src1_rdata[i] = src_rdata[0][L];
    end else if (int_rd_need(0, i)) begin : g_own_s1
      localparam int R0 = int_rd_idx(0, i);
      assign int_rd_en[R0]   = iss2prf_iss_entry_uop_src1_en[i];
      assign int_rd_preg[R0] = iss2prf_iss_entry_uop_src1_preg[i];
      assign int_rd_byp[R0]  = iss2prf_iss_entry_uop_src1_byp[i];
      assign src_rdata[0][i] = int_rdata[R0];
      assign prf2exe_iss_entry_uop_src1_rdata[i] = src_rdata[0][i];
    end else begin : g_no_s1
      assign src_rdata[0][i] = '0;
      assign prf2exe_iss_entry_uop_src1_rdata[i] = '0;
    end
    if (int_rd_need(1, i)) begin : g_own_s2
      localparam int R1 = int_rd_idx(1, i);
      assign int_rd_en[R1]   = iss2prf_iss_entry_uop_src2_en[i];
      assign int_rd_preg[R1] = iss2prf_iss_entry_uop_src2_preg[i];
      assign int_rd_byp[R1]  = iss2prf_iss_entry_uop_src2_byp[i];
      assign src_rdata[1][i] = int_rdata[R1];
    end else begin : g_no_s2
      assign src_rdata[1][i] = '0;
    end
    assign prf2exe_iss_entry_valid[i]          = iss2prf_iss_entry_valid[i];
    assign prf2exe_iss_entry_uop_dest_preg[i] = iss2prf_iss_entry_uop_dest_preg[i];
    assign prf2exe_iss_entry_uop_ftq_idx[i] = iss2prf_iss_entry_uop_ftq_idx[i];
    assign prf2exe_iss_entry_uop_ftq_offset[i] = iss2prf_iss_entry_uop_ftq_offset[i];
    assign prf2exe_iss_entry_uop_is_atomic[i] = iss2prf_iss_entry_uop_is_atomic[i];
    assign prf2exe_iss_entry_uop_dest_en[i] = iss2prf_iss_entry_uop_dest_en[i];
    assign prf2exe_iss_entry_uop_src1_en[i] = iss2prf_iss_entry_uop_src1_en[i];
    assign prf2exe_iss_entry_uop_src1_is_pc[i] = iss2prf_iss_entry_uop_src1_is_pc[i];
    assign prf2exe_iss_entry_uop_src2_is_imm[i] = iss2prf_iss_entry_uop_src2_is_imm[i];
    assign prf2exe_iss_entry_uop_is_word[i] = iss2prf_iss_entry_uop_is_word[i];
    assign prf2exe_iss_entry_uop_func3[i] = iss2prf_iss_entry_uop_func3[i];
    assign prf2exe_iss_entry_uop_func7[i] = iss2prf_iss_entry_uop_func7[i];
    assign prf2exe_iss_entry_uop_imm[i] = iss2prf_iss_entry_uop_imm[i];
    assign prf2exe_iss_entry_uop_csr_idx[i] = iss2prf_iss_entry_uop_csr_idx[i];
    assign prf2exe_iss_entry_uop_rob_idx[i] = iss2prf_iss_entry_uop_rob_idx[i];
    assign prf2exe_iss_entry_uop_stq_idx[i] = iss2prf_iss_entry_uop_stq_idx[i];
    assign prf2exe_iss_entry_uop_stq_flag[i] = iss2prf_iss_entry_uop_stq_flag[i];
    assign prf2exe_iss_entry_uop_ldq_idx[i] = iss2prf_iss_entry_uop_ldq_idx[i];
    assign prf2exe_iss_entry_uop_rob_flag[i] = iss2prf_iss_entry_uop_rob_flag[i];
    assign prf2exe_iss_entry_uop_op[i] = iss2prf_iss_entry_uop_op[i];
  end

  // Integer EXU-stage bypass: directly reuses the 6 ALU-port write-back winners (ALU/MUL/DIV/CSR);
  // selected by the wakeup-driven 6-bit one-hot mask from ISU (zero EXU-stage tag comparators).
  logic [XLEN_BITS-1:0] int_exu_res [ALU_NUM];
  for (genvar k = 0; k < ALU_NUM; k++) begin : g_int_exu
    assign int_exu_res[k] = exe2prf_entry_uop_result[WB_ALU_BASE + k];
  end
  // Unused legacy per-FU bypass bus and unused AGU src2 inputs (kept on top-level port for interface compatibility)
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_pruned_in;
  always_comb begin
    unused_pruned_in = 1'b0;
    if (!HAS_LSU_BYP) begin
      for (int k = 0; k < LSU_LOAD_WB_WIDTH; k++)
        unused_pruned_in ^= lsu_byp_valid[k] ^ (^lsu_byp_dest_preg[k]) ^ (^lsu_byp_result[k]);
    end
    for (int i = 0; i < NIP; i++) begin
      if (!int_rd_need(1, i) && !lane_is_fp(i))
        unused_pruned_in ^= iss2prf_iss_entry_uop_src2_en[i] ^ (^iss2prf_iss_entry_uop_src2_preg[i]);
    end
  end
  /* verilator lint_on UNUSEDSIGNAL */

  for (genvar k = 0; k < LSU_LOAD_WB_WIDTH; k++) begin : g_wake
    assign prf_awake_wake_valid[k] = wake_valid_vec[k];
  end

  // ---- write-back stage ----
  prf_wb_pipe #(.LANES(WL)) u_wb_pipe (
    .clk, .rst_n,
    .flush            (rob_bcast_flush),
    .bcast_mispred    (dec_bcast_mispred),
    .bcast_rob_idx    (dec_bcast_redirect_rob_idx),
    .bcast_rob_flag   (dec_bcast_redirect_rob_flag),
    .exe_valid        (exe_valid_vec),
    .exe_dest_en      (exe_dest_en_vec),
    .exe_is_load      (exe_is_load_vec),
    .exe_dest_preg    (exe2prf_entry_uop_dest_preg),
    .exe_result       (exe2prf_entry_uop_result),
    .exe_rob_idx      (exe2prf_entry_uop_rob_idx),
    .exe_rob_flag     (exe2prf_entry_uop_rob_flag),
    .wb_wen_q, .wb_is_load_q, .wb_dest_preg_q, .wb_result_q, .wb_rob_idx_q, .wb_rob_flag_q
  );

  // ---- register file + write ports ----
  prf_write_arb #(.LANES(WL), .NREG(PRF_NUM)) u_write_arb (
    .wb_wen       (wb_wen_q),
    .wb_dest_preg (wb_dest_preg_q),
    .wb_result    (wb_result_q),
    .reg_wr_en, .reg_wr_data
  );

  prf_regfile #(.NREG(PRF_NUM), .NRD(N_INT_RD)) u_regfile (
    .clk, .rst_n, .reg_wr_en, .reg_wr_data,
    .rd_addr (int_rd_preg),
    .rd_data (int_rf_data)
  );

  // ---- operand read ports with wakeup-driven EXU bypass + LSU L2-spec bypass + registered WB bypass ----
  for (genvar r = 0; r < N_INT_RD; r++) begin : g_rd
    prf_bypass #(.WBL(WL), .EXU_N(ALU_NUM), .HAS_LSU_BYP(HAS_LSU_BYP)) u_bypass (
      .src_en         (int_rd_en[r]),
      .src_preg       (int_rd_preg[r]),
      .rf_data        (int_rf_data[r]),
      .wb_wen         (wb_wen_q),
      .wb_dest_preg   (wb_dest_preg_q),
      .wb_result      (wb_result_q),
      .fu_sel         (int_rd_byp[r]),
      .fu_result      (int_exu_res),
      .lsu_byp_valid  (lsu_byp_valid),
      .lsu_byp_preg   (lsu_byp_dest_preg),
      .lsu_byp_result (lsu_byp_result),
      .rdata          (int_rdata[r])
    );
  end

  // ---- F/D: FP register file. Read ports: the three sources of every FP issue lane, the data source (src2) of every
  // store-data lane (fsw / fsd); the integer src2 of a store-data lane is replaced by the FP value when src2 is FP ----
  localparam int FP_LANES = FP_EN ? (ISSUE_WIDTH - IQ_FP_PORT_BASE) : 0;
  localparam int NRD = FP_EN ? (3 * FP_LANES + LSU_SDU_COUNT) : 1;
  // write-back lanes that carry FP-unit / I2F results: the ALU lanes of the ports with I2F, and the F/D lanes
  function automatic bit wl_fpu(int l);
    return (l >= WB_FP_BASE) || (l < WB_LD_BASE && isu_pkg::port_has(isu_pkg::MASK_FPD, IQ_ALU_PORT_BASE + l));
  endfunction
  function automatic int wl_fpu_rank(int l);
    int n = 0;
    for (int k = 0; k < l; k++) n += int'(wl_fpu(k));
    return n;
  endfunction
  function automatic int fp_rd_base(int i);   // first FP read port of lane i
    int n = 0;
    for (int q = 0; q < i; q++) n += lane_is_fp(q) ? 3 : (lane_is_std(q) ? 1 : 0);
    return n;
  endfunction
  logic [FW-1:0] fsrc [3][NIP];
  if (FP_EN) begin : g_fp
    logic [NRD-1:0]           fp_rd_en;
    logic [PRF_IDX_WIDTH-1:0] fp_rd_preg [NRD];
    logic [FW-1:0]            fp_rd_data [NRD];
    for (genvar i = 0; i < NIP; i++) begin : g_lane
      if (lane_is_fp(i)) begin : g_fp_lane
        localparam int B = fp_rd_base(i);
        assign fp_rd_en[B]   = iss2prf_iss_entry_uop_src1_en[i] && iss2prf_iss_entry_uop_src1_fp[i];
        assign fp_rd_en[B+1] = iss2prf_iss_entry_uop_src2_en[i] && iss2prf_iss_entry_uop_src2_fp[i];
        assign fp_rd_en[B+2] = iss2prf_iss_entry_uop_src3_en[i];
        assign fp_rd_preg[B]   = iss2prf_iss_entry_uop_src1_preg[i];
        assign fp_rd_preg[B+1] = iss2prf_iss_entry_uop_src2_preg[i];
        assign fp_rd_preg[B+2] = iss2prf_iss_entry_uop_src3_preg[i];
        assign fsrc[0][i] = fp_rd_data[B];
        assign fsrc[1][i] = fp_rd_data[B+1];
        assign fsrc[2][i] = fp_rd_data[B+2];
      end else if (lane_is_std(i)) begin : g_std_lane
        localparam int B = fp_rd_base(i);
        assign fp_rd_en[B]   = iss2prf_iss_entry_uop_src2_en[i] && iss2prf_iss_entry_uop_src2_fp[i];
        assign fp_rd_preg[B] = iss2prf_iss_entry_uop_src2_preg[i];
        assign fsrc[0][i] = '0;
        assign fsrc[1][i] = fp_rd_data[B];
        assign fsrc[2][i] = '0;
      end else begin : g_other
        assign fsrc[0][i] = '0;
        assign fsrc[1][i] = '0;
        assign fsrc[2][i] = '0;
      end
    end
    // FP EXU-stage bypass: pipelined FP units (FMA/FMISC/I2F) wake in their completion cycle and are already
    // in wb_fres_q when their consumer issues; only iterative FDIV (last FP lane) finishes in the consumer's issue cycle.
    localparam int FDIV_LANE = WB_FP_BASE + FP_LANES - 1;
    localparam int FP_BYP_N  = 1 + (HAS_LSU_BYP ? LSU_LOAD_WB_WIDTH : 0);
    logic [FP_BYP_N-1:0]      fp_byp_wen;
    logic [PRF_IDX_WIDTH-1:0] fp_byp_preg [FP_BYP_N];
    logic [FW-1:0]            fp_byp_fres [FP_BYP_N];
    assign fp_byp_wen[0]  = exe2prf_entry_valid[FDIV_LANE] && exe2prf_entry_uop_dest_en[FDIV_LANE];
    assign fp_byp_preg[0] = exe2prf_entry_uop_dest_preg[FDIV_LANE];
    assign fp_byp_fres[0] = exe2prf_entry_uop_fresult[FDIV_LANE];
    if (HAS_LSU_BYP) begin : g_lsu_fres
      for (genvar k = 0; k < LSU_LOAD_WB_WIDTH; k++) begin : g_k
        assign fp_byp_wen[1 + k]  = lsu_byp_valid[k];
        assign fp_byp_preg[1 + k] = lsu_byp_dest_preg[k];
        assign fp_byp_fres[1 + k] = fp_load_data(lsu_byp_result[k], lsu_byp_is_w[k]);   // flw: NaN-boxed
      end
    end
`ifndef SYNTHESIS
    // EXP-046 check: FP-register writes of the FP units and I2F in the write-back stage never exceed the issue-time limit
    // isu_pkg::FP_WB_PORTS (isu_fp_gate); loads write through their own lanes and are not counted
    int fpu_writes;
    always_comb begin
      fpu_writes = 0;
      for (int l = 0; l < WL; l++)
        if (wl_fpu(l) && wb_wen_q[l] && wb_dest_preg_q[l] >= PRF_IDX_WIDTH'(FP_TAG_BASE)) fpu_writes++;
    end
    always_ff @(posedge clk)
      if (rst_n && fpu_writes > isu_pkg::FP_WB_PORTS) $display("[FPWB] %0d FP-unit register writes in one cycle (t=%0t)", fpu_writes, $time);
`endif
    // ---- FP write lanes (EXP-046): the load lanes, plus the FP-unit / I2F writes compacted into FP_WB_PORTS lanes. The issue stage
    // lets at most FP_WB_PORTS of these write the FP file per cycle (isu_fp_gate), so the first FP_WB_PORTS of them in lane order
    // are all of them (checked above in simulation). Results are staged only for these lanes. ----
    localparam int NLD = LSU_LOAD_WB_WIDTH;
    localparam int NU  = isu_pkg::port_count(isu_pkg::MASK_FPD);                        // FP-unit / I2F lanes
    localparam int NC  = (isu_pkg::FP_WB_PORTS == 0 || isu_pkg::FP_WB_PORTS > NU) ? NU : isu_pkg::FP_WB_PORTS;
    localparam int FPL = NLD + NC;
    logic [FW-1:0]            ld_fres_q [NLD];
    logic [FW-1:0]            u_fres_q  [NU];
    logic [NU-1:0]            u_w;                 // FP-unit lane writes an FP register this cycle
    logic [PRF_IDX_WIDTH-1:0] u_dest [NU];
    for (genvar k = 0; k < NLD; k++) begin : g_ldq
      always_ff @(posedge clk) ld_fres_q[k] <= !rst_n ? '0 : exe2prf_entry_uop_fresult[WB_LD_BASE + k];
    end
    for (genvar l = 0; l < WL; l++) begin : g_u
      if (wl_fpu(l)) begin : g_is
        localparam int K = wl_fpu_rank(l);
        always_ff @(posedge clk) u_fres_q[K] <= !rst_n ? '0 : exe2prf_entry_uop_fresult[l];
        assign u_w[K]    = wb_wen_q[l] && (wb_dest_preg_q[l] >= PRF_IDX_WIDTH'(FP_TAG_BASE));
        assign u_dest[K] = wb_dest_preg_q[l];
      end
    end
    logic [FPL-1:0]           fw_wen;
    logic [PRF_IDX_WIDTH-1:0] fw_dest [FPL];
    logic [FW-1:0]            fw_fres [FPL];
    for (genvar k = 0; k < NLD; k++) begin : g_ldw
      assign fw_wen[k]  = wb_wen_q[WB_LD_BASE + k];
      assign fw_dest[k] = wb_dest_preg_q[WB_LD_BASE + k];
      assign fw_fres[k] = ld_fres_q[k];
    end
    logic [NU-1:0] u_left [NC+1];               // FP-unit writes not yet given a compacted lane
    assign u_left[0] = u_w;
    for (genvar j = 0; j < NC; j++) begin : g_cw
      logic [NU-1:0] sel;
      ttg_first_set #(.N(NU)) u_pick (.req(u_left[j]), .onehot(sel), .any(fw_wen[NLD + j]));
      assign u_left[j+1] = u_left[j] & ~sel;
      ttg_onehot_mux #(.N(NU), .W(PRF_IDX_WIDTH)) u_md (.sel(sel), .data(u_dest), .out(fw_dest[NLD + j]));
      ttg_onehot_mux #(.N(NU), .W(FW)) u_mf (.sel(sel), .data(u_fres_q), .out(fw_fres[NLD + j]));
    end
    /* verilator lint_off UNUSEDSIGNAL */   // waiver: what is left after the last compacted lane is empty (issue-time limit)
    logic unused_u_left;
    assign unused_u_left = |u_left[NC];
    /* verilator lint_on UNUSEDSIGNAL */
    prf_fp #(.LANES(FPL), .BYP_NUM(FP_BYP_N), .NRD(NRD)) u_fp (
      .clk, .rst_n, .wb_wen(fw_wen), .wb_dest_preg(fw_dest), .wb_fres_q(fw_fres),
      .byp_wen(fp_byp_wen), .byp_dest_preg(fp_byp_preg), .byp_fresult(fp_byp_fres),
      .rd_en(fp_rd_en), .rd_preg(fp_rd_preg), .rd_data(fp_rd_data)
    );
  end else begin : g_no_fp
    for (genvar i = 0; i < NIP; i++) begin : g_zero
      assign fsrc[0][i] = '0;
      assign fsrc[1][i] = '0;
      assign fsrc[2][i] = '0;
    end
  end
  for (genvar i = 0; i < NIP; i++) begin : g_fsrc_out
    assign prf2exe_iss_entry_uop_fsrc1[i] = fsrc[0][i];
    assign prf2exe_iss_entry_uop_fsrc2[i] = fsrc[1][i];
    assign prf2exe_iss_entry_uop_fsrc3[i] = fsrc[2][i];
    // fsw / fsd data: the store-data lane's src2 is the FP register value (S4 widens the data path to 64 bits)
    if (lane_is_std(i)) begin : g_std_src2
      assign prf2exe_iss_entry_uop_src2_rdata[i] = iss2prf_iss_entry_uop_src2_fp[i] ? XLEN_BITS'(fsrc[1][i])
                                                                                    : src_rdata[1][i];
    end else begin : g_int_src2
      assign prf2exe_iss_entry_uop_src2_rdata[i] = src_rdata[1][i];
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
    assign prf2exe_iss_entry_uop_ftq_is_rvc[LANE] = ftq_prf_pc_resp_resp_is_rvc[p];
    assign prf2exe_iss_entry_uop_ftq_next_pc[LANE]    = ftq_prf_pc_resp_resp_next_pc[p];
  end
  // lanes without a PC port never receive a PC
  for (genvar i = 0; i < NIP; i++) begin : g_nopc
    if (!((i >= IQ_ALU_PORT_BASE && i < IQ_ALU_PORT_BASE + ALU_NUM) ||
          (i >= IQ_BR_PORT_BASE && i < IQ_BR_PORT_BASE + BRU_NUM))) begin : g_tie
      assign prf2exe_iss_entry_uop_pc[i]             = '0;
      assign prf2exe_iss_entry_uop_ftq_pred_taken[i] = 1'b0;
      assign prf2exe_iss_entry_uop_ftq_is_rvc[i] = 1'b0;
      assign prf2exe_iss_entry_uop_ftq_next_pc[i]    = '0;
    end
  end

  // ---- load wake-up ----
  prf_awake #(.LANES(WL), .WAKE_NUM(LSU_LOAD_WB_WIDTH)) u_awake (
    .wb_wen         (wb_wen_q),
    .wb_is_load     (wb_is_load_q),
    .wb_dest_preg   (wb_dest_preg_q),
    .wb_rob_idx     (wb_rob_idx_q),
    .wb_rob_flag    (wb_rob_flag_q),
    .bcast_mispred  (dec_bcast_mispred),
    .bcast_rob_idx  (dec_bcast_redirect_rob_idx),
    .bcast_rob_flag (dec_bcast_redirect_rob_flag),
    .wake_valid     (wake_valid_vec),
    .wake_preg      (prf_awake_wake_preg)
  );

endmodule

`default_nettype wire
