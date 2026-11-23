// Ref: back-end/Isu.cpp  class Isu  (comb_begin/ready/awake/calc_latency_next/enq/issue/flush/seq)
`default_nettype none

// Issue unit: issue queues (INT, INT1, LD, STA, STD, BR, FP) plus the wake-up network. Port adapter only; logic is in
// isu_iq (queue), isu_wake_src (wake channels, delayed wake-ups) and isu_wake_bus (preg map).
module isu
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  // dispatch -> issue queues (Isu::comb_enq)
  input  logic dis2iss_req_valid [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] dis2iss_req_uop_dest_preg [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] dis2iss_req_uop_src1_preg [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] dis2iss_req_uop_src2_preg [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [FTQ_IDX_WIDTH-1:0] dis2iss_req_uop_ftq_idx [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] dis2iss_req_uop_ftq_offset [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_is_atomic [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_dest_en [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src1_en [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src2_en [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src1_busy [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src2_busy [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] dis2iss_req_uop_src3_preg [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src3_en [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src3_busy [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_dest_fp [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src1_fp [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src2_fp [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src1_is_pc [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src2_is_imm [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_is_word [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [2:0] dis2iss_req_uop_func3 [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [6:0] dis2iss_req_uop_func7 [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [31:0] dis2iss_req_uop_imm [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [BR_TAG_WIDTH-1:0] dis2iss_req_uop_br_id [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [BR_MASK_WIDTH-1:0] dis2iss_req_uop_br_mask [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [CSR_IDX_WIDTH-1:0] dis2iss_req_uop_csr_idx [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [ROB_IDX_WIDTH-1:0] dis2iss_req_uop_rob_idx [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [STQ_IDX_WIDTH-1:0] dis2iss_req_uop_stq_idx [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_stq_flag [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [LDQ_IDX_WIDTH-1:0] dis2iss_req_uop_ldq_idx [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_rob_flag [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [OP_W-1:0] dis2iss_req_uop_op [IQ_NUM][IQ_DISPATCH_WIDTH],
  // wake-ups driven by the LSU ([p] L2 speculative, [LDU+p] L3 register) and the cancel of a wrong speculative one
  input  logic [2*LSU_LDU_COUNT-1:0] lsu2iss_wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0] lsu2iss_wake_preg [2*LSU_LDU_COUNT],
  input  logic [LSU_LDU_COUNT-1:0] lsu2iss_cancel_valid,
  input  logic [PRF_IDX_WIDTH-1:0] lsu2iss_cancel_preg [LSU_LDU_COUNT],
  // load write-back wake-ups, FU readiness, broadcasts
  input  logic [LSU_LOAD_WB_WIDTH-1:0] prf_awake_wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0] prf_awake_wake_preg [LSU_LOAD_WB_WIDTH],
  input  logic [OP_NUM-1:0] exe2iss_fu_ready_mask [ISSUE_WIDTH],
  input  logic exe2iss_div_wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0] exe2iss_div_wake_preg,
  input  logic rob_bcast_flush,
  input  logic dec_bcast_mispred,
  input  logic [BR_MASK_WIDTH-1:0] dec_bcast_br_mask,
  input  logic [BR_MASK_WIDTH-1:0] dec_bcast_clear_mask,
  // outputs
  output logic [READY_NUM_W-1:0] iss2dis_ready_num [IQ_NUM],
  output logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_valid,
  output logic [PRF_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_dest_preg [ISSUE_WIDTH],
  output logic [PRF_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_src1_preg [ISSUE_WIDTH],
  output logic [PRF_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_src2_preg [ISSUE_WIDTH],
  output logic [PRF_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_src3_preg [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src3_en,
  output logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_dest_fp,
  output logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src1_fp,
  output logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src2_fp,
  output logic [FTQ_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_ftq_idx [ISSUE_WIDTH],
  output logic [FTQ_OFFSET_WIDTH-1:0] iss2prf_iss_entry_uop_ftq_offset [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_is_atomic,
  output logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_dest_en,
  output logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src1_en,
  output logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src2_en,
  output logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src1_is_pc,
  output logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_src2_is_imm,
  output logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_is_word,
  output logic [2:0] iss2prf_iss_entry_uop_func3 [ISSUE_WIDTH],
  output logic [6:0] iss2prf_iss_entry_uop_func7 [ISSUE_WIDTH],
  output logic [31:0] iss2prf_iss_entry_uop_imm [ISSUE_WIDTH],
  output logic [BR_TAG_WIDTH-1:0] iss2prf_iss_entry_uop_br_id [ISSUE_WIDTH],
  output logic [BR_MASK_WIDTH-1:0] iss2prf_iss_entry_uop_br_mask [ISSUE_WIDTH],
  output logic [CSR_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_csr_idx [ISSUE_WIDTH],
  output logic [ROB_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_rob_idx [ISSUE_WIDTH],
  output logic [STQ_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_stq_idx [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_stq_flag,
  output logic [LDQ_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_ldq_idx [ISSUE_WIDTH],
  output logic [ISSUE_WIDTH-1:0] iss2prf_iss_entry_uop_rob_flag,
  output logic [OP_W-1:0] iss2prf_iss_entry_uop_op [ISSUE_WIDTH],
  output logic [ALU_NUM-1:0] iss2prf_iss_entry_uop_src1_byp [ISSUE_WIDTH],
  output logic [ALU_NUM-1:0] iss2prf_iss_entry_uop_src2_byp [ISSUE_WIDTH],
  output logic [WAKE_NUM-1:0] iss_awake_wake_valid,
  output logic [PRF_IDX_WIDTH-1:0] iss_awake_wake_preg [WAKE_NUM]
);

`ifndef SYNTHESIS
  // static layout per config.h: 5 queues (6 with F/D: the FP ports come last), the 6-port ALU cluster first
  // (ports 0..5), then LD/STA/STD/BR
  if (IQ_LD_PORT_BASE != 6 || WAKE_PORTS != ALU_NUM || FAST_WAKE_BASE + FAST_UNITS + FPW_CH != WAKE_NUM ||
      IQ_DISPATCH_WIDTH != 8) begin : g_cfg_check
    $error("isu: config.h layout changed, isu_pkg port tables need updating");
  end
`endif

  logic                     flush_br;       // misprediction that is not already covered by the global flush
  logic                     issue_block;
  logic [ISSUE_WIDTH-1:0]   grant_valid;
  isu_uop_t [ISSUE_WIDTH-1:0] grant_uop;
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: non-ALU/non-FP ports of cand_valid_all are not read
  logic [ISSUE_WIDTH-1:0]   cand_valid_all;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [ALU_NUM-1:0]       grant_src1_byp [ISSUE_WIDTH];
  logic [ALU_NUM-1:0]       grant_src2_byp [ISSUE_WIDTH];
  logic [WAKE_NUM-1:0]      wake_valid;
  logic [PRF_IDX_WIDTH-1:0] wake_preg [WAKE_NUM];
  localparam int FP_RAW_N = FP_REQ_UNITS * 5;
  logic [ALU_NUM-1:0]       slow_exu_valid;
  logic [$clog2(PRF_NUM)-1:0] slow_exu_preg [ALU_NUM];
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: unused when FP_EN == 0
  logic [FP_RAW_N-1:0]      fp_raw_valid;
  logic [PRF_IDX_WIDTH-1:0] fp_raw_preg [FP_RAW_N];
  /* verilator lint_on UNUSEDSIGNAL */

  logic [LSU_LOAD_WB_WIDTH-1:0] prf_wake_valid;
  for (genvar k = 0; k < LSU_LOAD_WB_WIDTH; k++) begin : g_prf_wake
    assign prf_wake_valid[k] = prf_awake_wake_valid[k];
  end

  assign flush_br    = dec_bcast_mispred && !rob_bcast_flush;
  assign issue_block = rob_bcast_flush || dec_bcast_mispred;

  isu_wake_src u_wake_src (
    .clk(clk), .rst_n(rst_n),
    .prf_wake_valid(prf_wake_valid), .prf_wake_preg(prf_awake_wake_preg),
    .exe_div_wake_valid(exe2iss_div_wake_valid), .exe_div_wake_preg(exe2iss_div_wake_preg),
    .cand_valid(cand_valid_all), .grant_valid(grant_valid), .grant_uop(grant_uop),
    .flush_all(rob_bcast_flush), .flush_br(flush_br),
    .flush_br_mask(dec_bcast_br_mask), .clear_mask(dec_bcast_clear_mask),
    .wake_valid(wake_valid), .wake_preg(wake_preg),
    .slow_exu_valid(slow_exu_valid), .slow_exu_preg(slow_exu_preg),
    .fp_raw_valid(fp_raw_valid), .fp_raw_preg(fp_raw_preg));

  // ---- Domain-split slow (registered) wake-up bitmaps + direct 7-bit fast ALU wake-ups ----
  localparam bit HAS_SPEC_WAKE = ((lp_pkg::LP_L2 & 8) != 0);
  localparam int LSU_W_N       = HAS_SPEC_WAKE ? (2 * LSU_LDU_COUNT) : LSU_LDU_COUNT;
  localparam int FP_TAGS       = FP_EN ? FPRF_NUM : 1;
  localparam int INT_W         = $clog2(PRF_NUM);
  localparam int SLOW_INT_N    = LSU_LOAD_WB_WIDTH + MUL_UNITS + DIV_UNITS + (FP_EN ? FP_RAW_N : 0) + LSU_W_N;
  localparam int SLOW_FP_N     = LSU_LOAD_WB_WIDTH + (FP_EN ? FP_RAW_N : 0) + LSU_W_N;

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
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: plain ALU lanes 4..5 have no delayed MUL/DIV wake-ups
  logic unused_slow_exu_hi;
  always_comb begin
    unused_slow_exu_hi = 1'b0;
    for (int l = 4; l < ALU_NUM; l++) unused_slow_exu_hi ^= slow_exu_valid[l] ^ (^slow_exu_preg[l]);
  end
  /* verilator lint_on UNUSEDSIGNAL */

  // Pack slow integer-capable channels: LD (PRF) + MUL + DIV + FP (FMISC writes int) + LSU
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
  if (FP_EN) begin : g_si_fp
    localparam int B = LSU_LOAD_WB_WIDTH + MUL_UNITS + DIV_UNITS;
    for (genvar k = 0; k < FP_RAW_N; k++) begin : g_k
      assign slow_int_valid[B + k] = fp_raw_valid[k];
      assign slow_int_preg[B + k]  = fp_raw_preg[k];
    end
  end
  for (genvar k = 0; k < LSU_W_N; k++) begin : g_si_lsu
    localparam int B = LSU_LOAD_WB_WIDTH + MUL_UNITS + DIV_UNITS + (FP_EN ? FP_RAW_N : 0);
    localparam int S = HAS_SPEC_WAKE ? k : (LSU_LDU_COUNT + k);
    assign slow_int_valid[B + k] = lsu2iss_wake_valid[S];
    assign slow_int_preg[B + k]  = lsu2iss_wake_preg[S];
  end
  isu_wake_bus #(.N(SLOW_INT_N), .BASE(0), .TAGS(PRF_NUM)) u_wake_int (
    .wake_valid(slow_int_valid), .wake_preg(slow_int_preg), .woken(woken_slow_int));

  if (FP_EN) begin : g_fp_wake_bus
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
      localparam int S = HAS_SPEC_WAKE ? k : (LSU_LDU_COUNT + k);
      assign slow_fp_valid[B + k] = lsu2iss_wake_valid[S];
      assign slow_fp_preg[B + k]  = lsu2iss_wake_preg[S];
    end
    isu_wake_bus #(.N(SLOW_FP_N), .BASE(FP_TAG_BASE), .TAGS(FP_TAGS)) u_wake_fp (
      .wake_valid(slow_fp_valid), .wake_preg(slow_fp_preg), .woken(woken_slow_fp));
  end else begin : g_no_fp_wake_bus
    assign woken_slow_fp = '0;
  end

  // LP_L2[3] (speculative load wake-up): the [p] wake-ups and 4-way direct cancel exist only then.
  if (!HAS_SPEC_WAKE) begin : g_nospec_wake
    /* verilator lint_off UNUSEDSIGNAL */
    logic [LSU_LDU_COUNT-1:0] unused_spec_valid;  // spec wake-up / cancel inputs have no consumer
    assign unused_spec_valid = lsu2iss_wake_valid[LSU_LDU_COUNT-1:0] | lsu2iss_cancel_valid;
    logic unused_spec_preg;
    always_comb begin
      unused_spec_preg = 1'b0;
      for (int p = 0; p < LSU_LDU_COUNT; p++) unused_spec_preg ^= ^{lsu2iss_cancel_preg[p], lsu2iss_wake_preg[p]};
    end
    /* verilator lint_on UNUSEDSIGNAL */
  end

  for (genvar k = 0; k < WAKE_NUM; k++) begin : g_awake_out
    assign iss_awake_wake_valid[k] = wake_valid[k];
    assign iss_awake_wake_preg[k]  = wake_preg[k];
  end

  // ---- F/D: FP register-file write-port gate over the candidates that write the FP file ----
  logic [ISSUE_WIDTH-1:0] gate_ok_all, fp_ok_all;

  // ---- completion-cycle reservation of every issue port (EXP-035) ----
  logic [WB_CLS_W-1:0] wb_cls [ISSUE_WIDTH];
  logic [WB_NCLS-1:0]  wb_cls_free [ISSUE_WIDTH];
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: the select already guarantees a free completion cycle (EXP-046); port_ok is for tests/wb_gate
  logic [ISSUE_WIDTH-1:0] wb_port_ok;
  /* verilator lint_on UNUSEDSIGNAL */
  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_wb_cls
    assign wb_cls[p] = wb_class(grant_uop[p].op, grant_uop[p].func7, grant_uop[p].is_word);
  end
  isu_wb_gate u_wb_gate (.clk(clk), .rst_n(rst_n), .flush_all(rob_bcast_flush), .cls(wb_cls), .reserve(grant_valid),
                         .port_ok(wb_port_ok), .cls_free(wb_cls_free));
  // shared AGUs (LSU_AGU_SHARED): the memory queue applies the sharing itself (isu_iq SH_*)
  assign gate_ok_all = fp_ok_all;   // the completion cycle is checked in the select (EXP-046)

  /* verilator lint_off UNUSEDSIGNAL */   // waiver: only FP-capable ports of grant_fpw / grant_fp_cls1h / f1 / f2 are read
  logic [ISSUE_WIDTH-1:0] grant_fpw_all, grant_fp_f1_all, grant_fp_f2_all;
  logic [WB_NCLS-1:0]     grant_fp_cls1h_all [ISSUE_WIDTH];
  logic [6:0]             fp_free1_cls, fp_free2_cls;
  /* verilator lint_on UNUSEDSIGNAL */
  if (FP_EN) begin : g_gate
    logic [FP_REQ_UNITS-1:0]   c_valid, c_fpw, c_f1, c_f2, c_ok;
    logic [WB_NCLS-1:0]        c_cls_1h [FP_REQ_UNITS];
    for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_port
      if (port_has(MASK_FPD, p)) begin : g_cand
        localparam int R = port_rank(MASK_FPD, p);
        assign c_valid[R]   = cand_valid_all[p];
        assign c_fpw[R]     = grant_fpw_all[p];
        assign c_f1[R]      = grant_fp_f1_all[p];
        assign c_f2[R]      = grant_fp_f2_all[p];
        assign c_cls_1h[R]  = grant_fp_cls1h_all[p];
        assign fp_ok_all[p] = c_ok[R];
      end else begin : g_free
        assign fp_ok_all[p] = 1'b1;
      end
    end
    isu_fp_gate #(.NC(FP_REQ_UNITS)) u_gate (
      .clk(clk), .rst_n(rst_n), .flush_all(rob_bcast_flush), .cand_valid(c_valid), .cand_fpw(c_fpw),
      .cand_cls_1h(c_cls_1h), .cand_f1(c_f1), .cand_f2(c_f2),
      .fp_free1_cls(fp_free1_cls), .fp_free2_cls(fp_free2_cls), .gate_ok(c_ok));
  end else begin : g_no_gate
    assign fp_ok_all    = '1;
    assign fp_free1_cls = '1;
    assign fp_free2_cls = '1;
  end

  // ---- one instance per issue queue ----
  for (genvar q = 0; q < IQ_NUM; q++) begin : g_iq
    localparam int SIZE = iq_size(q);
    localparam int NP   = iq_port_num(q);
    localparam int EW   = iq_enq_width(q);   // enqueue lanes actually present (<= IQ_DISPATCH_WIDTH)

    logic [EW-1:0]                enq_valid;
    isu_enq_t                     enq [EW];
    logic [READY_NUM_W-1:0]       free_slots;
    op_set_t                      fu_ready [NP];
    logic [NP-1:0]                g_valid, g_cand, g_gate_ok;
    logic [WB_NCLS-1:0]           g_cls_free [NP];
    isu_uop_t                     g_uop [NP];
    logic [ALU_NUM-1:0]           g_byp1 [NP];
    logic [ALU_NUM-1:0]           g_byp2 [NP];
    logic [NP-1:0]                g_fpw, g_fp_f1, g_fp_f2;
    logic [WB_NCLS-1:0]           g_fp_cls1h [NP];

    for (genvar w = 0; w < EW; w++) begin : g_enq
      assign enq_valid[w] = dis2iss_req_valid[q][w];
      assign enq[w] = '{
        uop: '{
          dest_preg: dis2iss_req_uop_dest_preg[q][w],
          src1_preg: dis2iss_req_uop_src1_preg[q][w],
          src2_preg: dis2iss_req_uop_src2_preg[q][w],
          src3_preg: dis2iss_req_uop_src3_preg[q][w],
          ftq_idx: dis2iss_req_uop_ftq_idx[q][w],
          ftq_offset: dis2iss_req_uop_ftq_offset[q][w],
          is_atomic: dis2iss_req_uop_is_atomic[q][w],
          dest_en: dis2iss_req_uop_dest_en[q][w],
          src1_en: dis2iss_req_uop_src1_en[q][w],
          src2_en: dis2iss_req_uop_src2_en[q][w],
          src3_en: dis2iss_req_uop_src3_en[q][w],
          dest_fp: dis2iss_req_uop_dest_fp[q][w],
          src1_fp: dis2iss_req_uop_src1_fp[q][w],
          src2_fp: dis2iss_req_uop_src2_fp[q][w],
          src1_is_pc: dis2iss_req_uop_src1_is_pc[q][w],
          src2_is_imm: dis2iss_req_uop_src2_is_imm[q][w],
          is_word: dis2iss_req_uop_is_word[q][w],
          func3: dis2iss_req_uop_func3[q][w],
          func7: dis2iss_req_uop_func7[q][w],
          imm: dis2iss_req_uop_imm[q][w],
          br_id: dis2iss_req_uop_br_id[q][w],
          br_mask: dis2iss_req_uop_br_mask[q][w],
          csr_idx: dis2iss_req_uop_csr_idx[q][w],
          rob_idx: dis2iss_req_uop_rob_idx[q][w],
          stq_idx: dis2iss_req_uop_stq_idx[q][w],
          stq_flag: dis2iss_req_uop_stq_flag[q][w],
          ldq_idx: dis2iss_req_uop_ldq_idx[q][w],
          rob_flag: dis2iss_req_uop_rob_flag[q][w],
          op: dis2iss_req_uop_op[q][w]
        },
        src1_busy: dis2iss_req_uop_src1_busy[q][w],
        src2_busy: dis2iss_req_uop_src2_busy[q][w],
        src3_busy: dis2iss_req_uop_src3_busy[q][w]
      };
    end

    for (genvar p = 0; p < NP; p++) begin : g_port
      localparam int PP = iq_port(q, p);   // physical issue port
      assign fu_ready[p]          = exe2iss_fu_ready_mask[PP];
      assign g_gate_ok[p]         = gate_ok_all[PP];
      assign g_cls_free[p]        = wb_cls_free[PP];
      assign grant_valid[PP]      = g_valid[p];
      assign cand_valid_all[PP]   = g_cand[p];
      assign grant_uop[PP]        = g_uop[p];
      assign grant_src1_byp[PP]     = g_byp1[p];
      assign grant_src2_byp[PP]     = g_byp2[p];
      assign grant_fpw_all[PP]      = g_fpw[p];
      assign grant_fp_f1_all[PP]    = g_fp_f1[p];
      assign grant_fp_f2_all[PP]    = g_fp_f2[p];
      assign grant_fp_cls1h_all[PP] = g_fp_cls1h[p];
    end

    // dispatch may place at most EW uops per cycle: report min(free entries, EW) (the model checks both limits)
    assign iss2dis_ready_num[q] = (free_slots > READY_NUM_W'(EW)) ? READY_NUM_W'(EW) : free_slots;

    isu_iq #(.SIZE(SIZE), .DW(EW), .NP(NP), .QID(q),
             .SH_N((q == IQ_MEM) ? LSU_AGU_SHARED : 0),
             .SH_LD_LO(LSU_LDU_COUNT - LSU_AGU_SHARED), .SH_STA_LO(LSU_LDU_COUNT + LSU_STA_COUNT - LSU_AGU_SHARED),
             .AGE_EN(q == IQ_MEM),
             .HAS_SRC2(q != IQ_MEM),
             .HAS_SRC3(FP_EN && (q == IQ_FP)),
             .HAS_CANCEL(HAS_SPEC_WAKE),
             .SRC1_DOM((q == IQ_FP) ? 1 : 0),
             .SRC2_DOM((q == IQ_FP) ? 1 : ((q == 2 && FP_EN) ? 2 : 0)),
             .FP_TAGS(FP_TAGS), .INT_W(INT_W)) u_iq (
      .clk(clk), .rst_n(rst_n), .enq_valid(enq_valid), .enq(enq),
      .woken_slow_int(woken_slow_int), .woken_slow_fp(woken_slow_fp),
      .slow_exu_valid(slow_exu_v4), .slow_exu_preg(slow_exu_p4),
      .fast_valid(fast_wake_valid), .fast_preg(fast_wake_preg),
      .fu_ready(fu_ready), .gate_ok(g_gate_ok), .cls_free(g_cls_free),
      .fp_free1_cls(fp_free1_cls), .fp_free2_cls(fp_free2_cls),
      .issue_block(issue_block), .flush_all(rob_bcast_flush), .flush_br(flush_br),
      .flush_br_mask(dec_bcast_br_mask), .clear_mask(dec_bcast_clear_mask),
      .cancel_valid(lsu2iss_cancel_valid), .cancel_preg(lsu2iss_cancel_preg),
      .free_slots(free_slots), .cand_valid(g_cand), .grant_valid(g_valid),
      .grant_uop(g_uop), .grant_src1_byp(g_byp1), .grant_src2_byp(g_byp2),
      .grant_fpw(g_fpw), .grant_fp_cls1h(g_fp_cls1h), .grant_fp_f1(g_fp_f1), .grant_fp_f2(g_fp_f2));
  end

  // ---- issue ports to the PRF ----
  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_prf
    assign iss2prf_iss_entry_valid[p] = grant_valid[p];
    assign iss2prf_iss_entry_uop_dest_preg[p] = grant_uop[p].dest_preg;
    assign iss2prf_iss_entry_uop_src1_preg[p] = grant_uop[p].src1_preg;
    assign iss2prf_iss_entry_uop_src2_preg[p] = grant_uop[p].src2_preg;
    assign iss2prf_iss_entry_uop_src3_preg[p] = grant_uop[p].src3_preg;
    assign iss2prf_iss_entry_uop_src3_en[p] = grant_uop[p].src3_en;
    assign iss2prf_iss_entry_uop_dest_fp[p] = grant_uop[p].dest_fp;
    assign iss2prf_iss_entry_uop_src1_fp[p] = grant_uop[p].src1_fp;
    assign iss2prf_iss_entry_uop_src2_fp[p] = grant_uop[p].src2_fp;
    assign iss2prf_iss_entry_uop_ftq_idx[p] = grant_uop[p].ftq_idx;
    assign iss2prf_iss_entry_uop_ftq_offset[p] = grant_uop[p].ftq_offset;
    assign iss2prf_iss_entry_uop_is_atomic[p] = grant_uop[p].is_atomic;
    assign iss2prf_iss_entry_uop_dest_en[p] = grant_uop[p].dest_en;
    assign iss2prf_iss_entry_uop_src1_en[p] = grant_uop[p].src1_en;
    assign iss2prf_iss_entry_uop_src2_en[p] = grant_uop[p].src2_en;
    assign iss2prf_iss_entry_uop_src1_is_pc[p] = grant_uop[p].src1_is_pc;
    assign iss2prf_iss_entry_uop_src2_is_imm[p] = grant_uop[p].src2_is_imm;
    assign iss2prf_iss_entry_uop_is_word[p] = grant_uop[p].is_word;
    assign iss2prf_iss_entry_uop_func3[p] = grant_uop[p].func3;
    assign iss2prf_iss_entry_uop_func7[p] = grant_uop[p].func7;
    assign iss2prf_iss_entry_uop_imm[p] = grant_uop[p].imm;
    assign iss2prf_iss_entry_uop_br_id[p] = grant_uop[p].br_id;
    assign iss2prf_iss_entry_uop_br_mask[p] = grant_uop[p].br_mask;
    assign iss2prf_iss_entry_uop_csr_idx[p] = grant_uop[p].csr_idx;
    assign iss2prf_iss_entry_uop_rob_idx[p] = grant_uop[p].rob_idx;
    assign iss2prf_iss_entry_uop_stq_idx[p] = grant_uop[p].stq_idx;
    assign iss2prf_iss_entry_uop_stq_flag[p] = grant_uop[p].stq_flag;
    assign iss2prf_iss_entry_uop_ldq_idx[p] = grant_uop[p].ldq_idx;
    assign iss2prf_iss_entry_uop_rob_flag[p] = grant_uop[p].rob_flag;
    assign iss2prf_iss_entry_uop_op[p] = grant_uop[p].op;
    assign iss2prf_iss_entry_uop_src1_byp[p] = grant_src1_byp[p];
    assign iss2prf_iss_entry_uop_src2_byp[p] = grant_src2_byp[p];
  end

endmodule

`default_nettype wire
