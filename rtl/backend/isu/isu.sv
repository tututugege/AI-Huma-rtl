// Ref: back-end/Isu.cpp  class Isu  (comb_begin/ready/awake/calc_latency_next/enq/issue/flush/seq)
`default_nettype none

// Issue unit: issue queues (INT0, INT1, MEM, STD, BR, FP) plus the wake-up network.
// Top level adapts packed dis2iss / iss2prf structs to isu_iq, isu_wake_src and isu_wake_bus.
module isu
  import ttg_cfg_pkg::*;
  import isu_pkg::*, ttg_util_pkg::ttg_rob_younger;
  import dis_pkg::dis_iss_uop_t;
(
  input  logic                      clk,
  input  logic                      rst_n,
  // dispatch -> issue queues (Isu::comb_enq)
  input  logic                      dis2iss_req_valid [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  dis_iss_uop_t              dis2iss_req_uop   [IQ_NUM][IQ_DISPATCH_WIDTH],
  // wake-ups driven by the LSU ([0..LDU-1] L1 spec, [LDU..2*LDU-1] L3, [2*LDU..3*LDU-1] L2b/L2a, [3*LDU..] WBP)
  input  logic [3*LSU_LDU_COUNT+1:0] lsu2iss_wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0]   lsu2iss_wake_preg [3*LSU_LDU_COUNT+2],
  input  logic [LSU_LDU_COUNT-1:0]   lsu2iss_cancel_valid,
  input  logic [PRF_IDX_WIDTH-1:0]   lsu2iss_cancel_preg [LSU_LDU_COUNT],
  // load write-back wake-ups, DIV write-back notice, broadcasts
  input  logic [LSU_LOAD_WB_WIDTH-1:0] prf_awake_wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0]     prf_awake_wake_preg [LSU_LOAD_WB_WIDTH],
  input  logic                         exe2iss_div_wb_in2,
  input  logic                         exe2iss_div_wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0]     exe2iss_div_wake_preg,
  input  logic                         rob_bcast_flush,
  input  logic                         dec_bcast_mispred,
  input  logic [ROB_IDX_WIDTH-1:0]     dec_bcast_redirect_rob_idx,
  input  logic                         dec_bcast_redirect_rob_flag,
  // outputs
  output logic [READY_NUM_W-1:0]       iss2dis_ready_num [IQ_NUM],
  output logic [ISSUE_WIDTH-1:0]       iss2prf_valid,
  output isu_uop_t                     iss2prf_uop       [ISSUE_WIDTH],
  output logic [ALU_NUM-1:0]           iss2prf_src1_byp  [ISSUE_WIDTH],
  output logic [ALU_NUM-1:0]           iss2prf_src2_byp  [ISSUE_WIDTH],
  output logic [LSU_LDU_COUNT-1:0]     iss2prf_spec_mask [ISSUE_WIDTH],
  output logic [WAKE_NUM-1:0]          iss_awake_wake_valid,
  output logic [PRF_IDX_WIDTH-1:0]     iss_awake_wake_preg [WAKE_NUM],
  output logic [ALU_NUM-1:0]           iss_awake_cancel_valid,
  output logic [PRF_IDX_WIDTH-1:0]     iss_awake_cancel_preg [ALU_NUM]
);

`ifndef SYNTHESIS
  if (IQ_AGU_PORT_BASE != 6 || WAKE_PORTS != ALU_NUM || FAST_WAKE_BASE + FAST_UNITS + FPW_CH != WAKE_NUM ||
      IQ_DISPATCH_WIDTH != 8) begin : g_cfg_check
    $error("isu: config.h layout changed, isu_pkg port tables need updating");
  end
`endif

  localparam int CANCEL_N = LSU_LDU_COUNT;

  logic                       flush_br;
  logic                       issue_block;
  logic [ISSUE_WIDTH-1:0]     grant_valid;
  isu_uop_t [ISSUE_WIDTH-1:0] grant_uop;
  logic [ISSUE_WIDTH-1:0]     cand_valid_all;
  logic [ALU_NUM-1:0]         grant_src1_byp [ISSUE_WIDTH];
  logic [ALU_NUM-1:0]         grant_src2_byp [ISSUE_WIDTH];
  logic [LSU_LDU_COUNT-1:0]   grant_spec_mask_all [ISSUE_WIDTH];
  logic [WAKE_NUM-1:0]        wake_valid;
  logic [PRF_IDX_WIDTH-1:0]   wake_preg [WAKE_NUM];
  logic [ALU_NUM-1:0]         fast_cancel_raw, fast_cancel_valid;
  logic [PRF_IDX_WIDTH-1:0]   fast_cancel_preg [ALU_NUM];
  logic [LSU_LDU_COUNT-1:0]   lsu_l1_wake_valid;
  logic [PRF_IDX_WIDTH-1:0]   lsu_l1_wake_preg [LSU_LDU_COUNT];
  localparam int FP_RAW_N = FP_REQ_UNITS * 5;
  logic [ALU_NUM-1:0]         slow_exu_valid;
  logic [$clog2(PRF_NUM)-1:0] slow_exu_preg [ALU_NUM];
  logic [FP_RAW_N-1:0]        fp_raw_valid;
  logic [PRF_IDX_WIDTH-1:0]   fp_raw_preg [FP_RAW_N];

  assign flush_br    = dec_bcast_mispred && !rob_bcast_flush;
  assign issue_block = rob_bcast_flush || dec_bcast_mispred;
  assign lsu_l1_wake_valid = lsu2iss_wake_valid[LSU_LDU_COUNT-1:0];
  for (genvar k = 0; k < LSU_LDU_COUNT; k++) begin : g_l1wk
    assign lsu_l1_wake_preg[k] = lsu2iss_wake_preg[k];
  end

  isu_wake_src u_wake_src (
    .clk(clk), .rst_n(rst_n),
    .prf_wake_valid(prf_awake_wake_valid), .prf_wake_preg(prf_awake_wake_preg),
    .exe_div_wake_valid(exe2iss_div_wake_valid), .exe_div_wake_preg(exe2iss_div_wake_preg),
    .cn_port_mask(lsu2iss_cancel_valid),
    .cand_valid(cand_valid_all), .grant_valid(grant_valid), .grant_uop(grant_uop),
    .grant_spec_mask(grant_spec_mask_all),
    .flush_all(rob_bcast_flush), .flush_br(flush_br),
    .flush_rob_idx(dec_bcast_redirect_rob_idx), .flush_rob_flag(dec_bcast_redirect_rob_flag),
    .wake_valid(wake_valid), .wake_preg(wake_preg),
    .fast_cancel_raw(fast_cancel_raw),
    .fast_cancel_valid(fast_cancel_valid), .fast_cancel_preg(fast_cancel_preg),
    .slow_exu_valid(slow_exu_valid), .slow_exu_preg(slow_exu_preg),
    .fp_raw_valid(fp_raw_valid), .fp_raw_preg(fp_raw_preg));

  // ---- Domain-split slow (registered) wake-up bitmaps + direct 7-bit fast ALU wake-ups ----
  localparam int LSU_W_N    = 3 * LSU_LDU_COUNT + 2;
  localparam int FP_TAGS    = FPRF_NUM;
  localparam int INT_W      = $clog2(PRF_NUM);
  localparam int SLOW_INT_N = LSU_LOAD_WB_WIDTH + MUL_UNITS + DIV_UNITS + FP_RAW_N + LSU_W_N;
  localparam int SLOW_FP_N  = LSU_LOAD_WB_WIDTH + FP_RAW_N + LSU_W_N;

  logic [FAST_UNITS-1:0]    fast_wake_valid;
  logic [INT_W-1:0]         fast_wake_preg [FAST_UNITS];
  for (genvar k = 0; k < FAST_UNITS; k++) begin : g_fast_out
    assign fast_wake_valid[k] = wake_valid[FAST_WAKE_BASE + k];
    assign fast_wake_preg[k]  = wake_preg[FAST_WAKE_BASE + k][INT_W-1:0];
  end

  logic [SLOW_INT_N-1:0]    slow_int_valid;
  logic [PRF_IDX_WIDTH-1:0] slow_int_preg [SLOW_INT_N];
  logic [PRF_NUM-1:0]       woken_slow_int;
  logic [FP_TAGS-1:0]       woken_slow_fp;

  // Only ALU lanes 0..3 have delayed MUL/DIV EXU bypass wake-ups (lanes 4..5 are plain ALU)
  logic [3:0]       slow_exu_v4;
  logic [INT_W-1:0] slow_exu_p4 [4];
  for (genvar l = 0; l < 4; l++) begin : g_se4
    assign slow_exu_v4[l] = slow_exu_valid[l];
    assign slow_exu_p4[l] = slow_exu_preg[l];
  end
  logic unused_slow_exu_hi;
  always_comb begin
    unused_slow_exu_hi = 1'b0;
    for (int l = 4; l < ALU_NUM; l++) unused_slow_exu_hi ^= slow_exu_valid[l] ^ (^slow_exu_preg[l]);
  end

  for (genvar k = 0; k < LSU_LOAD_WB_WIDTH; k++) begin : g_si_ld
    assign slow_int_valid[k] = wake_valid[LD_WAKE_BASE + k];
    assign slow_int_preg[k]  = wake_preg[LD_WAKE_BASE + k];
  end
  for (genvar k = 0; k < MUL_UNITS; k++) begin : g_si_mul
    localparam int B = LSU_LOAD_WB_WIDTH;
    assign slow_int_valid[B + k] = wake_valid[MUL_WAKE_BASE + k];
    assign slow_int_preg[B + k]  = wake_preg[MUL_WAKE_BASE + k];
  end
  for (genvar k = 0; k < DIV_UNITS; k++) begin : g_si_div
    localparam int B = LSU_LOAD_WB_WIDTH + MUL_UNITS;
    assign slow_int_valid[B + k] = wake_valid[DIV_WAKE_BASE + k];
    assign slow_int_preg[B + k]  = wake_preg[DIV_WAKE_BASE + k];
  end
  for (genvar k = 0; k < FP_RAW_N; k++) begin : g_si_fp
    localparam int B = LSU_LOAD_WB_WIDTH + MUL_UNITS + DIV_UNITS;
    assign slow_int_valid[B + k] = fp_raw_valid[k];
    assign slow_int_preg[B + k]  = fp_raw_preg[k];
  end
  for (genvar k = 0; k < LSU_W_N; k++) begin : g_si_lsu
    localparam int B = LSU_LOAD_WB_WIDTH + MUL_UNITS + DIV_UNITS + FP_RAW_N;
    assign slow_int_valid[B + k] = lsu2iss_wake_valid[k];
    assign slow_int_preg[B + k]  = lsu2iss_wake_preg[k];
  end
  isu_wake_bus #(.N(SLOW_INT_N), .BASE(0), .TAGS(PRF_NUM)) u_wake_int (
    .wake_valid(slow_int_valid), .wake_preg(slow_int_preg), .woken(woken_slow_int));

  logic [SLOW_FP_N-1:0]     slow_fp_valid;
  logic [PRF_IDX_WIDTH-1:0] slow_fp_preg [SLOW_FP_N];
  for (genvar k = 0; k < LSU_LOAD_WB_WIDTH; k++) begin : g_sf_ld
    assign slow_fp_valid[k] = wake_valid[LD_WAKE_BASE + k];
    assign slow_fp_preg[k]  = wake_preg[LD_WAKE_BASE + k];
  end
  for (genvar k = 0; k < FP_RAW_N; k++) begin : g_sf_fp
    assign slow_fp_valid[LSU_LOAD_WB_WIDTH + k] = fp_raw_valid[k];
    assign slow_fp_preg[LSU_LOAD_WB_WIDTH + k]  = fp_raw_preg[k];
  end
  for (genvar k = 0; k < LSU_W_N; k++) begin : g_sf_lsu
    localparam int B = LSU_LOAD_WB_WIDTH + FP_RAW_N;
    assign slow_fp_valid[B + k] = lsu2iss_wake_valid[k];
    assign slow_fp_preg[B + k]  = lsu2iss_wake_preg[k];
  end
  isu_wake_bus #(.N(SLOW_FP_N), .BASE(FP_TAG_BASE), .TAGS(FP_TAGS)) u_wake_fp (
    .wake_valid(slow_fp_valid), .wake_preg(slow_fp_preg), .woken(woken_slow_fp));

  assign iss_awake_wake_valid = wake_valid;
  assign iss_awake_wake_preg  = wake_preg;

  // ---- F/D: FP register-file write-port gate + completion-cycle reservation ----
  logic [ISSUE_WIDTH-1:0] gate_ok_all, fp_ok_all;
  logic [WB_NCLS-1:0]     grant_wb_cls1h_all [ISSUE_WIDTH];
  logic [WB_NCLS-1:0]     wb_cls_free [ISSUE_WIDTH];
  isu_wb_gate u_wb_gate (
    .clk(clk), .rst_n(rst_n), .flush_all(rob_bcast_flush), .cancel_valid(lsu2iss_cancel_valid),
    .cls_1h(grant_wb_cls1h_all), .reserve(grant_valid), .reserve_spec_mask(grant_spec_mask_all),
    .cls_free(wb_cls_free));
  assign gate_ok_all = fp_ok_all;

  /* verilator lint_off UNUSEDSIGNAL */   // waiver: only FP-capable ports of grant_fpw / grant_fp_cls1h / f1 are read
  logic [ISSUE_WIDTH-1:0] grant_fpw_all, grant_fp_f1_all;
  logic [WB_NCLS-1:0]     grant_fp_cls1h_all [ISSUE_WIDTH];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [6:0]               fp_free1_cls;
  logic [FP_REQ_UNITS-1:0]  c_valid, c_fpw, c_f1, c_ok;
  logic [LSU_LDU_COUNT-1:0] c_spec_mask [FP_REQ_UNITS];
  logic [WB_NCLS-1:0]       c_cls_1h [FP_REQ_UNITS];
  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_fp_cand
    if (port_has(MASK_FPD, p)) begin : g_cand
      localparam int R = port_rank(MASK_FPD, p);
      assign c_valid[R]     = cand_valid_all[p];
      assign c_fpw[R]       = grant_fpw_all[p];
      assign c_spec_mask[R] = grant_spec_mask_all[p];
      assign c_f1[R]        = grant_fp_f1_all[p];
      assign c_cls_1h[R]    = grant_fp_cls1h_all[p];
      assign fp_ok_all[p]   = c_ok[R];
    end else begin : g_free
      assign fp_ok_all[p] = 1'b1;
    end
  end
  isu_fp_gate #(.NC(FP_REQ_UNITS)) u_gate (
    .clk(clk), .rst_n(rst_n), .flush_all(rob_bcast_flush), .cancel_valid(lsu2iss_cancel_valid),
    .cand_valid(c_valid), .cand_fpw(c_fpw), .cand_spec_mask(c_spec_mask),
    .cand_cls_1h(c_cls_1h), .cand_f1(c_f1),
    .fp_free1_cls(fp_free1_cls), .gate_ok(c_ok));

  // ---- iterative FU occupancy (DIV on port 1, FDIV on port ISSUE_WIDTH - 1) ----
  logic                     div_busy_q, div_busy_d, div_busy_eff;
  logic [LSU_LDU_COUNT-1:0] div_spec_mask_q, div_spec_mask_d;
  logic [ROB_IDX_WIDTH-1:0] div_rob_idx_q, div_rob_idx_d;
  logic                     div_rob_flag_q, div_rob_flag_d;
  logic                     div_iss, div_keep;
  always_comb begin
    div_busy_eff    = div_busy_q && !(|(div_spec_mask_q & lsu2iss_cancel_valid));
    div_iss         = grant_valid[1] && (grant_uop[1].op == op_t'(dis_pkg::UOP_DIV));
    div_keep        = div_busy_eff && !exe2iss_div_wb_in2 &&
                      !(flush_br && ttg_rob_younger(div_rob_idx_q, div_rob_flag_q,
                                                    dec_bcast_redirect_rob_idx, dec_bcast_redirect_rob_flag));
    div_busy_d      = rob_bcast_flush ? 1'b0 : (div_iss || div_keep);
    div_spec_mask_d = rob_bcast_flush ? '0   : (div_iss ? grant_spec_mask_all[1] : '0);
    div_rob_idx_d   = rob_bcast_flush ? '0   : (div_iss ? grant_uop[1].rob_idx  : (div_keep ? div_rob_idx_q  : '0));
    div_rob_flag_d  = rob_bcast_flush ? 1'b0 : (div_iss ? grant_uop[1].rob_flag : (div_keep ? div_rob_flag_q : 1'b0));
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      div_busy_q      <= 1'b0;
      div_spec_mask_q <= '0;
      div_rob_idx_q   <= '0;
      div_rob_flag_q  <= 1'b0;
    end else begin
      div_busy_q      <= div_busy_d;
      div_spec_mask_q <= div_spec_mask_d;
      div_rob_idx_q   <= div_rob_idx_d;
      div_rob_flag_q  <= div_rob_flag_d;
    end
  end

  localparam int FP_LAST = ISSUE_WIDTH - 1;
  logic                     fdiv_iss, fdiv_keep;
  logic [FP_COUNT_W:0]      fdiv_cnt_q, fdiv_cnt_eff, fdiv_cnt_d, fdiv_lat;
  logic [LSU_LDU_COUNT-1:0] fdiv_spec_mask_q, fdiv_spec_mask_d;
  logic [ROB_IDX_WIDTH-1:0] fdiv_rob_idx_q, fdiv_rob_idx_d;
  logic                     fdiv_rob_flag_q, fdiv_rob_flag_d;
  always_comb begin
    fdiv_cnt_eff     = (|(fdiv_spec_mask_q & lsu2iss_cancel_valid)) ? '0 : fdiv_cnt_q;
    fdiv_iss         = grant_valid[FP_LAST] && (grant_uop[FP_LAST].op == op_t'(dis_pkg::UOP_FDIV));
    fdiv_lat         = fp_latency(op_t'(dis_pkg::UOP_FDIV), grant_uop[FP_LAST].func7);
    fdiv_keep        = (fdiv_cnt_eff > (FP_COUNT_W+1)'(1)) &&
                       !(flush_br && ttg_rob_younger(fdiv_rob_idx_q, fdiv_rob_flag_q,
                                                     dec_bcast_redirect_rob_idx, dec_bcast_redirect_rob_flag));
    fdiv_cnt_d       = rob_bcast_flush ? '0
                     : fdiv_iss        ? fdiv_lat
                     : fdiv_keep       ? (fdiv_cnt_eff - (FP_COUNT_W+1)'(1)) : '0;
    fdiv_spec_mask_d = rob_bcast_flush ? '0 : (fdiv_iss ? grant_spec_mask_all[FP_LAST] : '0);
    fdiv_rob_idx_d   = rob_bcast_flush ? '0
                     : fdiv_iss        ? grant_uop[FP_LAST].rob_idx
                     : fdiv_keep       ? fdiv_rob_idx_q : '0;
    fdiv_rob_flag_d  = rob_bcast_flush ? 1'b0
                     : fdiv_iss        ? grant_uop[FP_LAST].rob_flag
                     : fdiv_keep       ? fdiv_rob_flag_q : 1'b0;
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fdiv_cnt_q       <= '0;
      fdiv_spec_mask_q <= '0;
      fdiv_rob_idx_q   <= '0;
      fdiv_rob_flag_q  <= 1'b0;
    end else begin
      fdiv_cnt_q       <= fdiv_cnt_d;
      fdiv_spec_mask_q <= fdiv_spec_mask_d;
      fdiv_rob_idx_q   <= fdiv_rob_idx_d;
      fdiv_rob_flag_q  <= fdiv_rob_flag_d;
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && (fdiv_cnt_eff != '0) && fdiv_iss) $error("isu: FDIV re-issued while busy");
`endif

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && div_busy_eff && div_iss) $error("isu: DIV re-issued while busy");
`endif

  logic [WB_NCLS-1:0] iss_cls_free [ISSUE_WIDTH];
  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_icf
    for (genvar c = 0; c < WB_NCLS; c++) begin : g_c
      if (p == 1 && c == 0) begin : g_div_alu
        assign iss_cls_free[p][c] = wb_cls_free[p][c] && !exe2iss_div_wb_in2;
      end else if (p == 1 && (c == 2 || c == 3)) begin : g_div_busy
        assign iss_cls_free[p][c] = wb_cls_free[p][c] && !div_busy_eff;
      end else if ((p == ISSUE_WIDTH - 1) && (c >= 4 && c <= 7)) begin : g_fdiv_busy
        assign iss_cls_free[p][c] = wb_cls_free[p][c] && (fdiv_cnt_eff == '0);
      end else begin : g_pass
        assign iss_cls_free[p][c] = wb_cls_free[p][c];
      end
    end
  end

  // ---- one instance per issue queue ----
  for (genvar q = 0; q < IQ_NUM; q++) begin : g_iq
    localparam int SIZE = iq_size(q);
    localparam int NP   = iq_port_num(q);
    localparam int EW   = iq_enq_width(q);

    logic [EW-1:0]            enq_valid;
    isu_enq_t                 enq [EW];
    logic [READY_NUM_W-1:0]   iq_ready_num;
    logic [NP-1:0]            g_valid, g_cand, g_gate_ok;
    logic [WB_NCLS-1:0]       g_cls_free [NP];
    isu_uop_t                 g_uop [NP];
    logic [ALU_NUM-1:0]       g_byp1 [NP];
    logic [ALU_NUM-1:0]       g_byp2 [NP];
    logic [LSU_LDU_COUNT-1:0] g_spec_mask [NP];
    logic [NP-1:0]            g_fpw, g_fp_f1;
    logic [WB_NCLS-1:0]       g_fp_cls1h [NP], g_wb_cls1h [NP];

    for (genvar w = 0; w < EW; w++) begin : g_enq
      assign enq_valid[w] = dis2iss_req_valid[q][w];
      assign enq[w] = '{
        uop: '{
          dest_preg:   dis2iss_req_uop[q][w].dest_preg,
          src1_preg:   dis2iss_req_uop[q][w].src1_preg,
          src2_preg:   dis2iss_req_uop[q][w].src2_preg,
          src3_preg:   dis2iss_req_uop[q][w].src3_preg,
          ftq_idx:     dis2iss_req_uop[q][w].ftq_idx,
          ftq_offset:  dis2iss_req_uop[q][w].ftq_offset,
          is_atomic:   dis2iss_req_uop[q][w].is_atomic,
          dest_en:     dis2iss_req_uop[q][w].dest_en,
          src1_en:     dis2iss_req_uop[q][w].src1_en,
          src2_en:     dis2iss_req_uop[q][w].src2_en,
          src3_en:     dis2iss_req_uop[q][w].src3_en,
          dest_fp:     dis2iss_req_uop[q][w].dest_fp,
          src1_fp:     dis2iss_req_uop[q][w].src1_fp,
          src2_fp:     dis2iss_req_uop[q][w].src2_fp,
          src1_is_pc:  dis2iss_req_uop[q][w].src1_is_pc,
          src2_is_imm: dis2iss_req_uop[q][w].src2_is_imm,
          is_word:     dis2iss_req_uop[q][w].is_word,
          func3:       dis2iss_req_uop[q][w].func3,
          func7:       dis2iss_req_uop[q][w].func7,
          imm:         dis2iss_req_uop[q][w].imm,
          csr_idx:     dis2iss_req_uop[q][w].csr_idx,
          rob_idx:     dis2iss_req_uop[q][w].rob_idx,
          stq_idx:     dis2iss_req_uop[q][w].stq_idx,
          stq_flag:    dis2iss_req_uop[q][w].stq_flag,
          ldq_idx:     dis2iss_req_uop[q][w].ldq_idx,
          rob_flag:    dis2iss_req_uop[q][w].rob_flag,
          op:          dis2iss_req_uop[q][w].op
        },
        src1_busy: dis2iss_req_uop[q][w].src1_busy,
        src2_busy: dis2iss_req_uop[q][w].src2_busy,
        src3_busy: dis2iss_req_uop[q][w].src3_busy
      };
    end

    for (genvar p = 0; p < NP; p++) begin : g_port
      localparam int PP = iq_port(q, p);
      assign g_gate_ok[p]           = gate_ok_all[PP];
      assign g_cls_free[p]          = iss_cls_free[PP];
      assign grant_valid[PP]        = g_valid[p];
      assign cand_valid_all[PP]     = g_cand[p];
      assign grant_uop[PP]          = g_uop[p];
      assign grant_src1_byp[PP]     = g_byp1[p];
      assign grant_src2_byp[PP]     = g_byp2[p];
      assign grant_spec_mask_all[PP] = g_spec_mask[p];
      assign grant_fpw_all[PP]      = g_fpw[p];
      assign grant_fp_f1_all[PP]    = g_fp_f1[p];
      assign grant_fp_cls1h_all[PP] = g_fp_cls1h[p];
      assign grant_wb_cls1h_all[PP] = g_wb_cls1h[p];
    end

    assign iss2dis_ready_num[q] = iq_ready_num;

    isu_iq #(.SIZE(SIZE), .DW(EW), .NP(NP), .QID(q),
             .AGE_EN(q == IQ_MEM),
             .HAS_SRC2(q != IQ_MEM),
             .HAS_SRC3(q == IQ_FP),
             .HAS_CANCEL(1'b1),
             .SRC1_DOM((q == IQ_FP) ? 1 : 0),
             .SRC2_DOM((q == IQ_FP) ? 1 : ((q == IQ_STD) ? 2 : 0)),
             .FP_TAGS(FP_TAGS), .INT_W(INT_W), .CANCEL_N(CANCEL_N)) u_iq (
      .clk(clk), .rst_n(rst_n), .enq_valid(enq_valid), .enq(enq),
      .woken_slow_int(woken_slow_int), .woken_slow_fp(woken_slow_fp),
      .lsu_l1_wake_valid(lsu_l1_wake_valid), .lsu_l1_wake_preg(lsu_l1_wake_preg),
      .slow_exu_valid(slow_exu_v4), .slow_exu_preg(slow_exu_p4),
      .fast_valid(fast_wake_valid), .fast_preg(fast_wake_preg),
      .gate_ok(g_gate_ok), .cls_free(g_cls_free),
      .fp_free1_cls(fp_free1_cls),
      .issue_block(issue_block), .flush_all(rob_bcast_flush), .flush_br(flush_br),
      .flush_rob_idx(dec_bcast_redirect_rob_idx), .flush_rob_flag(dec_bcast_redirect_rob_flag),
      .cancel_valid(lsu2iss_cancel_valid), .cancel_preg(lsu2iss_cancel_preg),
      .fast_cancel_raw(fast_cancel_raw),
      .fast_cancel_valid_chk(fast_cancel_valid), .fast_cancel_preg_chk(fast_cancel_preg),
      .ready_num(iq_ready_num), .cand_valid(g_cand), .grant_valid(g_valid),
      .grant_uop(g_uop), .grant_src1_byp(g_byp1), .grant_src2_byp(g_byp2), .grant_spec_mask(g_spec_mask),
      .grant_fpw(g_fpw), .grant_fp_cls1h(g_fp_cls1h), .grant_wb_cls1h(g_wb_cls1h), .grant_fp_f1(g_fp_f1));
  end

  assign iss2prf_valid          = grant_valid;
  assign iss2prf_src1_byp       = grant_src1_byp;
  assign iss2prf_src2_byp       = grant_src2_byp;
  assign iss2prf_spec_mask      = grant_spec_mask_all;
  assign iss_awake_cancel_valid = fast_cancel_valid;
  assign iss_awake_cancel_preg  = fast_cancel_preg;
  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_prf
    assign iss2prf_uop[p] = grant_uop[p];
  end

endmodule

`default_nettype wire
