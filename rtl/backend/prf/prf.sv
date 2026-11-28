// Ref: back-end/Prf.cpp  class Prf  (reference model commit 2f31e8d)
`default_nettype none

// Physical register file: storage, write-back stage, operand read with bypass, FTQ PC read ports, load wake-up.
module prf
  import ttg_cfg_pkg::*;
  import fp_pkg::*;
  import isu_pkg::isu_uop_t;
  import exu_ctrl_pkg::xc_inst_t;
  import exu_ctrl_pkg::xc_prf_wb_t;
#(
  parameter int UOP_TYPE_WIDTH = 5
) (
  input  logic                          clk,
  input  logic                          rst_n,
  input  logic                          dec_bcast_mispred,
  input  logic [ROB_IDX_WIDTH-1:0]      dec_bcast_redirect_rob_idx,
  input  logic                          dec_bcast_redirect_rob_flag,
  input  logic                          rob_bcast_flush,
  input  logic [ISSUE_WIDTH-1:0]        iss2prf_valid,
  input  isu_uop_t                      iss2prf_uop      [ISSUE_WIDTH],
  input  logic [ALU_NUM-1:0]            iss2prf_src1_byp [ISSUE_WIDTH],
  input  logic [ALU_NUM-1:0]            iss2prf_src2_byp [ISSUE_WIDTH],
  input  xc_prf_wb_t                    exe2prf          [WB_LANES],
  // LSU write-back requests of this cycle as a bypass source (speculative L2 load wake-up)
  input  logic [LSU_LOAD_WB_WIDTH-1:0]  lsu_byp_valid,
  input  logic [PRF_IDX_WIDTH-1:0]      lsu_byp_dest_preg [LSU_LOAD_WB_WIDTH],
  input  logic [XLEN_BITS-1:0]          lsu_byp_result    [LSU_LOAD_WB_WIDTH],
  input  logic [LSU_LOAD_WB_WIDTH-1:0]  lsu_byp_is_w,
  input  logic [XLEN_BITS-1:0]          ftq_prf_pc_resp_resp_pc [FTQ_PRF_PC_PORT_NUM],
  input  logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_resp_resp_pred_taken,
  input  logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_resp_resp_is_rvc,
  input  logic [XLEN_BITS-1:0]          ftq_prf_pc_resp_resp_next_pc [FTQ_PRF_PC_PORT_NUM],
  output logic [FTQ_IDX_WIDTH-1:0]      ftq_prf_pc_req_req_ftq_idx [FTQ_PRF_PC_PORT_NUM],
  output logic [FTQ_OFFSET_WIDTH-1:0]   ftq_prf_pc_req_req_ftq_offset [FTQ_PRF_PC_PORT_NUM],
  output logic [LSU_LOAD_WB_WIDTH-1:0]  prf_awake_wake_valid,
  output logic [PRF_IDX_WIDTH-1:0]      prf_awake_wake_preg [LSU_LOAD_WB_WIDTH],
  output logic [ISSUE_WIDTH-1:0]        prf2exe_valid,
  output xc_inst_t                      prf2exe_uop [ISSUE_WIDTH],
  output logic [CSR_IDX_WIDTH-1:0]      prf2exe_csr_idx
);

  localparam int NIP = ISSUE_WIDTH;
  localparam int WL  = WB_LANES;
  localparam logic [UOP_TYPE_WIDTH-1:0] UOP_LOAD = UOP_TYPE_WIDTH'(3);

  logic [WL-1:0]             exe_valid_vec, exe_dest_en_vec, exe_is_load_vec, exe_rob_flag_vec;
  logic [PRF_IDX_WIDTH-1:0]  exe_dest_preg [WL];
  logic [XLEN_BITS-1:0]      exe_result    [WL];
  logic [ROB_IDX_WIDTH-1:0]  exe_rob_idx   [WL];
  logic [WL-1:0]             wb_wen_q, wb_is_load_q;
  logic [PRF_IDX_WIDTH-1:0]  wb_dest_preg_q [WL];
  logic [XLEN_BITS-1:0]      wb_result_q    [WL];
  logic [ROB_IDX_WIDTH-1:0]  wb_rob_idx_q   [WL];
  logic [WL-1:0]             wb_rob_flag_q;
  logic [PRF_NUM-1:0]        reg_wr_en;
  logic [XLEN_BITS-1:0]      reg_wr_data  [PRF_NUM];

  function automatic bit lane_is_fp(int i);
    return i >= IQ_FP_PORT_BASE;
  endfunction
  function automatic bit lane_is_agu(int i);
    return (i >= IQ_AGU_PORT_BASE) && (i < IQ_AGU_PORT_BASE + LSU_AGU_COUNT);
  endfunction
  function automatic bit lane_is_std(int i);
    return (i >= IQ_STD_PORT_BASE) && (i < IQ_STD_PORT_BASE + LSU_SDU_COUNT);
  endfunction
  function automatic bit int_rd_need(int s, int i);
    if (lane_is_fp(i)) return 1'b0;
    if (s == 0) return 1'b1;
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
  logic [XLEN_BITS-1:0]      lane_src1   [NIP];
  logic [XLEN_BITS-1:0]      lane_src2   [NIP];
  logic [FW-1:0]             fsrc        [3][NIP];
  logic [XLEN_BITS-1:0]      lane_pc     [NIP];
  logic [NIP-1:0]            lane_pred_taken;
  logic [NIP-1:0]            lane_is_rvc;
  logic [XLEN_BITS-1:0]      lane_next_pc [NIP];

  for (genvar l = 0; l < WL; l++) begin : g_wl
    assign exe_valid_vec[l]    = exe2prf[l].valid;
    assign exe_dest_en_vec[l]  = exe2prf[l].dest_en;
    assign exe_is_load_vec[l]  = exe2prf[l].op == UOP_LOAD;
    assign exe_dest_preg[l]    = exe2prf[l].dest_preg;
    assign exe_result[l]       = exe2prf[l].result;
    assign exe_rob_idx[l]      = exe2prf[l].rob_idx;
    assign exe_rob_flag_vec[l] = exe2prf[l].rob_flag;
  end

  assign prf2exe_valid   = iss2prf_valid;
  assign prf2exe_csr_idx = iss2prf_uop[IQ_ALU_PORT_BASE].csr_idx;

  for (genvar i = 0; i < NIP; i++) begin : g_lane
    if (int_rd_need(0, i)) begin : g_own_s1
      localparam int R0 = int_rd_idx(0, i);
      assign int_rd_en[R0]   = iss2prf_uop[i].src1_en;
      assign int_rd_preg[R0] = iss2prf_uop[i].src1_preg;
      assign int_rd_byp[R0]  = iss2prf_src1_byp[i];
      assign src_rdata[0][i] = int_rdata[R0];
      assign lane_src1[i]    = src_rdata[0][i];
    end else begin : g_no_s1
      assign src_rdata[0][i] = '0;
      assign lane_src1[i]    = '0;
    end
    if (int_rd_need(1, i)) begin : g_own_s2
      localparam int R1 = int_rd_idx(1, i);
      assign int_rd_en[R1]   = iss2prf_uop[i].src2_en;
      assign int_rd_preg[R1] = iss2prf_uop[i].src2_preg;
      assign int_rd_byp[R1]  = iss2prf_src2_byp[i];
      assign src_rdata[1][i] = int_rdata[R1];
    end else begin : g_no_s2
      assign src_rdata[1][i] = '0;
    end
    if (lane_is_std(i)) begin : g_std_src2
      assign lane_src2[i] = iss2prf_uop[i].src2_fp ? XLEN_BITS'(fsrc[1][i]) : src_rdata[1][i];
    end else begin : g_int_src2
      assign lane_src2[i] = src_rdata[1][i];
    end
    assign prf2exe_uop[i] = '{
      pc:             lane_pc[i],
      ftq_pred_taken: lane_pred_taken[i],
      ftq_is_rvc:     lane_is_rvc[i],
      ftq_next_pc:    lane_next_pc[i],
      dest_preg:      iss2prf_uop[i].dest_preg,
      src1_rdata:     lane_src1[i],
      src2_rdata:     lane_src2[i],
      fsrc1:          fsrc[0][i],
      fsrc2:          fsrc[1][i],
      fsrc3:          fsrc[2][i],
      ftq_idx:        iss2prf_uop[i].ftq_idx,
      ftq_offset:     iss2prf_uop[i].ftq_offset,
      is_atomic:      iss2prf_uop[i].is_atomic,
      dest_en:        iss2prf_uop[i].dest_en,
      src1_en:        iss2prf_uop[i].src1_en,
      src1_is_pc:     iss2prf_uop[i].src1_is_pc,
      src2_is_imm:    iss2prf_uop[i].src2_is_imm,
      is_word:        iss2prf_uop[i].is_word,
      func3:          iss2prf_uop[i].func3,
      func7:          iss2prf_uop[i].func7,
      imm:            iss2prf_uop[i].imm,
      rob_idx:        iss2prf_uop[i].rob_idx,
      stq_idx:        iss2prf_uop[i].stq_idx,
      stq_flag:       iss2prf_uop[i].stq_flag,
      ldq_idx:        iss2prf_uop[i].ldq_idx,
      rob_flag:       iss2prf_uop[i].rob_flag,
      op:             iss2prf_uop[i].op
    };
  end

  logic [XLEN_BITS-1:0] int_exu_res [ALU_NUM];
  for (genvar k = 0; k < ALU_NUM; k++) begin : g_int_exu
    assign int_exu_res[k] = exe2prf[WB_ALU_BASE + k].result;
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
    .exe_dest_preg    (exe_dest_preg),
    .exe_result       (exe_result),
    .exe_rob_idx      (exe_rob_idx),
    .exe_rob_flag     (exe_rob_flag_vec),
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

  for (genvar r = 0; r < N_INT_RD; r++) begin : g_rd
    prf_bypass #(.WBL(WL), .EXU_N(ALU_NUM)) u_bypass (
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

  // ---- F/D: FP register file ----
  localparam int FP_LANES = ISSUE_WIDTH - IQ_FP_PORT_BASE;
  localparam int NRD      = 3 * FP_LANES + LSU_SDU_COUNT;
  function automatic bit wl_fpu(int l);
    return (l >= WB_FP_BASE) || (l < WB_LD_BASE && isu_pkg::port_has(isu_pkg::MASK_FPD, IQ_ALU_PORT_BASE + l));
  endfunction
  function automatic int wl_fpu_rank(int l);
    int n = 0;
    for (int k = 0; k < l; k++) n += int'(wl_fpu(k));
    return n;
  endfunction
  function automatic int fp_rd_base(int i);
    int n = 0;
    for (int q = 0; q < i; q++) n += lane_is_fp(q) ? 3 : (lane_is_std(q) ? 1 : 0);
    return n;
  endfunction

  logic [NRD-1:0]           fp_rd_en;
  logic [PRF_IDX_WIDTH-1:0] fp_rd_preg [NRD];
  logic [FW-1:0]            fp_rd_data [NRD];
  for (genvar i = 0; i < NIP; i++) begin : g_fp_rd
    if (lane_is_fp(i)) begin : g_fp_lane
      localparam int B = fp_rd_base(i);
      assign fp_rd_en[B]     = iss2prf_uop[i].src1_en && iss2prf_uop[i].src1_fp;
      assign fp_rd_en[B+1]   = iss2prf_uop[i].src2_en && iss2prf_uop[i].src2_fp;
      assign fp_rd_en[B+2]   = iss2prf_uop[i].src3_en;
      assign fp_rd_preg[B]   = iss2prf_uop[i].src1_preg;
      assign fp_rd_preg[B+1] = iss2prf_uop[i].src2_preg;
      assign fp_rd_preg[B+2] = iss2prf_uop[i].src3_preg;
      assign fsrc[0][i]      = fp_rd_data[B];
      assign fsrc[1][i]      = fp_rd_data[B+1];
      assign fsrc[2][i]      = fp_rd_data[B+2];
    end else if (lane_is_std(i)) begin : g_std_lane
      localparam int B = fp_rd_base(i);
      assign fp_rd_en[B]   = iss2prf_uop[i].src2_en && iss2prf_uop[i].src2_fp;
      assign fp_rd_preg[B] = iss2prf_uop[i].src2_preg;
      assign fsrc[0][i]    = '0;
      assign fsrc[1][i]    = fp_rd_data[B];
      assign fsrc[2][i]    = '0;
    end else begin : g_other
      assign fsrc[0][i] = '0;
      assign fsrc[1][i] = '0;
      assign fsrc[2][i] = '0;
    end
  end
  localparam int FDIV_LANE = WB_FP_BASE + FP_LANES - 1;
  localparam int FP_BYP_N  = 1 + LSU_LOAD_WB_WIDTH;
  logic [FP_BYP_N-1:0]      fp_byp_wen;
  logic [PRF_IDX_WIDTH-1:0] fp_byp_preg [FP_BYP_N];
  logic [FW-1:0]            fp_byp_fres [FP_BYP_N];
  assign fp_byp_wen[0]  = exe2prf[FDIV_LANE].valid && exe2prf[FDIV_LANE].dest_en;
  assign fp_byp_preg[0] = exe2prf[FDIV_LANE].dest_preg;
  assign fp_byp_fres[0] = exe2prf[FDIV_LANE].fresult;
  for (genvar k = 0; k < LSU_LOAD_WB_WIDTH; k++) begin : g_lsu_fres
    assign fp_byp_wen[1 + k]  = lsu_byp_valid[k];
    assign fp_byp_preg[1 + k] = lsu_byp_dest_preg[k];
    assign fp_byp_fres[1 + k] = fp_load_data(lsu_byp_result[k], lsu_byp_is_w[k]);
  end
`ifndef SYNTHESIS
  int fpu_writes;
  always_comb begin
    fpu_writes = 0;
    for (int l = 0; l < WL; l++)
      if (wl_fpu(l) && wb_wen_q[l] && wb_dest_preg_q[l] >= PRF_IDX_WIDTH'(FP_TAG_BASE)) fpu_writes++;
  end
  always_ff @(posedge clk)
    if (rst_n && fpu_writes > isu_pkg::FP_WB_PORTS)
      $display("[FPWB] %0d FP-unit register writes in one cycle (t=%0t)", fpu_writes, $time);
`endif
  localparam int NLD = LSU_LOAD_WB_WIDTH;
  localparam int NU  = isu_pkg::port_count(isu_pkg::MASK_FPD);
  localparam int NC  = (isu_pkg::FP_WB_PORTS > NU) ? NU : isu_pkg::FP_WB_PORTS;
  localparam int FPL = NLD + NC;
  logic [FW-1:0]            ld_fres_q [NLD];
  logic [FW-1:0]            u_fres_q  [NU];
  logic [NU-1:0]            u_w;
  logic [PRF_IDX_WIDTH-1:0] u_dest [NU];
  for (genvar k = 0; k < NLD; k++) begin : g_ldq
    always_ff @(posedge clk) ld_fres_q[k] <= !rst_n ? '0 : exe2prf[WB_LD_BASE + k].fresult;
  end
  for (genvar l = 0; l < WL; l++) begin : g_u
    if (wl_fpu(l)) begin : g_is
      localparam int K = wl_fpu_rank(l);
      always_ff @(posedge clk) u_fres_q[K] <= !rst_n ? '0 : exe2prf[l].fresult;
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
  logic [NU-1:0] u_left [NC+1];
  assign u_left[0] = u_w;
  for (genvar j = 0; j < NC; j++) begin : g_cw
    logic [NU-1:0] sel;
    ttg_first_set #(.N(NU)) u_pick (.req(u_left[j]), .onehot(sel), .any(fw_wen[NLD + j]));
    assign u_left[j+1] = u_left[j] & ~sel;
    ttg_onehot_mux #(.N(NU), .W(PRF_IDX_WIDTH)) u_md (.sel(sel), .data(u_dest), .out(fw_dest[NLD + j]));
    ttg_onehot_mux #(.N(NU), .W(FW)) u_mf (.sel(sel), .data(u_fres_q), .out(fw_fres[NLD + j]));
  end
  logic unused_u_left;
  assign unused_u_left = |u_left[NC];
  prf_fp #(.LANES(FPL), .BYP_NUM(FP_BYP_N), .NRD(NRD)) u_fp (
    .clk, .rst_n, .wb_wen(fw_wen), .wb_dest_preg(fw_dest), .wb_fres_q(fw_fres),
    .byp_wen(fp_byp_wen), .byp_dest_preg(fp_byp_preg), .byp_fresult(fp_byp_fres),
    .rd_en(fp_rd_en), .rd_preg(fp_rd_preg), .rd_data(fp_rd_data)
  );

  // ---- FTQ PC read: 2 PC-ALU lanes (Port 0, Port 2) + BRU lanes -> FTQ_PRF_PC_PORT_NUM ports; the FTQ reads every
  // port every cycle (no request valid), a lane uses the answer only when its uop needs the PC ----
  localparam int NPC_ALU = FTQ_PRF_PC_PORT_NUM - BRU_NUM;

  for (genvar p = 0; p < FTQ_PRF_PC_PORT_NUM; p++) begin : g_port
    localparam int LANE = (p == 0) ? IQ_ALU_PORT_BASE
                        : (p == 1) ? (IQ_ALU_PORT_BASE + 2)
                                   : (IQ_BR_PORT_BASE + (p - NPC_ALU));
    assign ftq_prf_pc_req_req_ftq_idx[p]    = iss2prf_uop[LANE].ftq_idx;
    assign ftq_prf_pc_req_req_ftq_offset[p] = iss2prf_uop[LANE].ftq_offset;
    assign lane_pc[LANE]                    = ftq_prf_pc_resp_resp_pc[p];
    assign lane_pred_taken[LANE]            = ftq_prf_pc_resp_resp_pred_taken[p];
    assign lane_is_rvc[LANE]                = ftq_prf_pc_resp_resp_is_rvc[p];
    assign lane_next_pc[LANE]               = ftq_prf_pc_resp_resp_next_pc[p];
  end
  for (genvar i = 0; i < NIP; i++) begin : g_nopc
    if (!((i == IQ_ALU_PORT_BASE) || (i == IQ_ALU_PORT_BASE + 2) ||
          (i >= IQ_BR_PORT_BASE && i < IQ_BR_PORT_BASE + BRU_NUM))) begin : g_tie
      assign lane_pc[i]         = '0;
      assign lane_pred_taken[i] = 1'b0;
      assign lane_is_rvc[i]     = 1'b0;
      assign lane_next_pc[i]    = '0;
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
    .wake_valid     (prf_awake_wake_valid),
    .wake_preg      (prf_awake_wake_preg)
  );

endmodule

`default_nettype wire
