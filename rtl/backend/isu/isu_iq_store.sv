// Ref: back-end/include/IssueQueue.h  IssueQueue (entry, enqueue, comb_wakeup, flush_br, clear_br, commit_issue)
`default_nettype none

// Issue-queue storage: per slot a valid bit, the uop, per-source "still waiting" bits, and per-source 6-bit
// wakeup-driven one-hot EXU bypass masks (slot_byp1 / slot_byp2). When a waiting integer source is woken by one
// of the 6 ALU/MUL/DIV execution lanes, the corresponding bit in byp*_q is set for the next cycle and auto-clears
// the cycle after (once the result has moved to the WB stage), eliminating all EXU-stage tag comparators in PRF.
module isu_iq_store
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
#(
  parameter int SIZE       = 64,
  parameter int DW         = IQ_DISPATCH_WIDTH,
  parameter bit HAS_DEST   = 1'b1,
  parameter bit HAS_SRC2   = 1'b1,
  parameter bit HAS_SRC3   = 1'b0,
  parameter bit HAS_FTQ    = 1'b1,
  parameter bit HAS_STQ    = 1'b1,
  parameter bit HAS_LDQ    = 1'b1,
  parameter bit HAS_CSR    = 1'b1,
  parameter bit HAS_ATOMIC = 1'b1,
  parameter bit HAS_FUNC7  = 1'b1,
  parameter bit HAS_ALU_FL = 1'b1,
  parameter bit HAS_FP_FL  = 1'b1,
  parameter int IMM_W      = 32,
  parameter bit IMM_SEXT   = 1'b0,
  parameter bit HAS_CANCEL = 1'b0,
  // 0 = integer domain only, 1 = FP domain only, 2 = both domains (STD src2)
  parameter int SRC1_DOM   = 0,
  parameter int SRC2_DOM   = 0,
  parameter int FP_TAGS    = FPRF_NUM,
  parameter int INT_W      = $clog2(PRF_NUM),
  parameter int CANCEL_N   = LSU_LDU_COUNT
) (
  input  logic                     clk,
  input  logic                     rst_n,
  // enqueue: slot_onehot[w] is the slot written by lane w (zero when lane w is idle)
  input  logic [SIZE-1:0]          enq_slot [DW],
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: per-IQ disabled payload fields and unused domain/cancel inputs
  input  isu_uop_t                 enq_uop  [DW],
  input  logic [DW-1:0]            enq_wait1,
  input  logic [DW-1:0]            enq_wait2,
  input  logic [DW-1:0]            enq_wait3,
  input  logic [ALU_NUM-1:0]       enq_byp1 [DW],
  input  logic [ALU_NUM-1:0]       enq_byp2 [DW],
  input  logic [1:0]               enq_mul1 [DW],
  input  logic [1:0]               enq_mul2 [DW],
  input  logic [LSU_LDU_COUNT-1:0] enq_spec_t1 [DW],
  input  logic [PRF_NUM-1:0]       woken_slow_int,
  input  logic [FP_TAGS-1:0]       woken_slow_fp,
  input  logic [LSU_LDU_COUNT-1:0] lsu_l1_wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0] lsu_l1_wake_preg [LSU_LDU_COUNT],
  input  logic [3:0]               slow_exu_valid,
  input  logic [INT_W-1:0]         slow_exu_preg [4],
  input  logic [FAST_UNITS-1:0]    fast_valid,
  input  logic [INT_W-1:0]         fast_preg [FAST_UNITS],
  input  logic [CANCEL_N-1:0]      cancel_valid,          // wrong L1-spec load
  input  logic [PRF_IDX_WIDTH-1:0] cancel_preg [CANCEL_N],
  input  logic [ALU_NUM-1:0]       fast_cancel_raw,       // ALU grandchild cancel (fast-only byp match)
  input  logic [ALU_NUM-1:0]       fast_cancel_valid_chk, // simulation SVA oracle only
  input  logic [PRF_IDX_WIDTH-1:0] fast_cancel_preg_chk [ALU_NUM],
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [SIZE-1:0]          issue_clear,    // slots granted this cycle
  input  logic                     flush_all,
  input  logic                     flush_br,       // misprediction without a global flush
  input  logic [ROB_IDX_WIDTH-1:0] flush_rob_idx,
  input  logic                     flush_rob_flag,
  // registered & occupancy-tracking views
  output logic [SIZE-1:0]          slot_valid,
  output logic [SIZE-1:0]          slot_rr_ret,
  output logic [SIZE-1:0]          slot_surv_br,
  output logic [SIZE-1:0]          slot_ready,
  output isu_uop_t                 slot_uop  [SIZE],
  output logic [ALU_NUM-1:0]       slot_byp1 [SIZE],
  output logic [ALU_NUM-1:0]       slot_byp2 [SIZE],
  output logic [LSU_LDU_COUNT-1:0] slot_spec_t1 [SIZE]
);

  localparam int FP_W = (FP_TAGS > 1) ? $clog2(FP_TAGS) : 1;

  // Common payload fields stored in every IQ
  typedef struct packed {
    logic [PRF_IDX_WIDTH-1:0] src1_preg;
    logic                     src1_en;
    logic [2:0]               func3;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    logic                     rob_flag;
    op_t                      op;
  } iq_core_t;
  localparam int CORE_W = $bits(iq_core_t);

  function automatic logic match_cancel(
    input logic [CANCEL_N-1:0]      cn_v,
    input logic [PRF_IDX_WIDTH-1:0] cn_p [CANCEL_N],
    input logic [PRF_IDX_WIDTH-1:0] preg
  );
    logic m;
    m = 1'b0;
    for (int k = 0; k < CANCEL_N; k++)
      m = m || (cn_v[k] && (cn_p[k] == preg));
    return m;
  endfunction

  function automatic logic lookup_int_map(input logic [PRF_NUM-1:0] m, input logic [PRF_IDX_WIDTH-1:0] preg);
    return (preg < PRF_IDX_WIDTH'(PRF_NUM)) ? m[preg[INT_W-1:0]] : 1'b0;
  endfunction

  function automatic logic lookup_fp_map(input logic [FP_TAGS-1:0] m, input logic [PRF_IDX_WIDTH-1:0] preg);
    logic [PRF_IDX_WIDTH-1:0] idx;
    idx = preg - PRF_IDX_WIDTH'(FP_TAG_BASE);
    return (preg >= PRF_IDX_WIDTH'(FP_TAG_BASE)) && (idx < PRF_IDX_WIDTH'(FP_TAGS)) ? m[idx[FP_W-1:0]] : 1'b0;
  endfunction

  logic [CORE_W-1:0] enq_core [DW];
  logic [DW-1:0]     enq_killed;
  for (genvar w = 0; w < DW; w++) begin : g_pack
    assign enq_core[w]   = iq_core_t'{
      src1_preg: enq_uop[w].src1_preg,
      src1_en:   enq_uop[w].src1_en,
      func3:     enq_uop[w].func3,
      rob_idx:   enq_uop[w].rob_idx,
      rob_flag:  enq_uop[w].rob_flag,
      op:        enq_uop[w].op
    };
    assign enq_killed[w] = flush_br && isu_rob_younger(enq_uop[w].rob_idx, enq_uop[w].rob_flag, flush_rob_idx, flush_rob_flag);
  end

  for (genvar i = 0; i < SIZE; i++) begin : g_slot
    logic [DW-1:0]     hit;              // enqueue lane that writes this slot
    logic              write;
    logic [CORE_W-1:0] new_core;
    logic              valid_q, valid_d;
    iq_core_t          core_q;
    isu_uop_t          uop_q;
    logic              wait1_q, wait1_d, wait1_c;
    logic              wait2_c, wait3_c;
    logic              old_killed;

    for (genvar w = 0; w < DW; w++) begin : g_hit
      assign hit[w] = enq_slot[w][i];
    end
    assign write = |hit;
    ttg_onehot_mux #(.N(DW), .W(CORE_W)) u_new_core (.sel(hit), .data(enq_core), .out(new_core));

    // ---- Per-IQ optional payload fields (compiled out when unused by this IQ) ----
    logic [PRF_IDX_WIDTH-1:0]    f_dest_preg, f_src2_preg, f_src3_preg;
    logic                        f_dest_en, f_src2_en, f_src3_en;
    logic [FTQ_IDX_WIDTH-1:0]    f_ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] f_ftq_offset;
    logic [STQ_IDX_WIDTH-1:0]    f_stq_idx;
    logic                        f_stq_flag;
    logic [LDQ_IDX_WIDTH-1:0]    f_ldq_idx;
    logic [CSR_IDX_WIDTH-1:0]    f_csr_idx;
    logic                        f_is_atomic;
    logic [6:0]                  f_func7;
    logic                        f_src1_is_pc, f_src2_is_imm, f_is_word;
    logic                        f_dest_fp, f_src1_fp, f_src2_fp;
    logic [31:0]                 f_imm;

    if (HAS_DEST) begin : g_dest
      localparam int W = PRF_IDX_WIDTH + 1;
      logic [W-1:0] e [DW], sel, q;
      for (genvar w = 0; w < DW; w++) begin : g_w
        assign e[w] = {enq_uop[w].dest_preg, enq_uop[w].dest_en};
      end
      ttg_onehot_mux #(.N(DW), .W(W)) u_m (.sel(hit), .data(e), .out(sel));
      always_ff @(posedge clk) begin
        if (!rst_n)     q <= '0;
        else if (write) q <= sel;
      end
      assign {f_dest_preg, f_dest_en} = q;
    end else begin : g_no_dest
      assign f_dest_preg = '0;
      assign f_dest_en   = 1'b0;
    end

    if (HAS_SRC2) begin : g_src2_f
      localparam int W = PRF_IDX_WIDTH + 1;
      logic [W-1:0] e [DW], sel, q;
      for (genvar w = 0; w < DW; w++) begin : g_w
        assign e[w] = {enq_uop[w].src2_preg, enq_uop[w].src2_en};
      end
      ttg_onehot_mux #(.N(DW), .W(W)) u_m (.sel(hit), .data(e), .out(sel));
      always_ff @(posedge clk) begin
        if (!rst_n)     q <= '0;
        else if (write) q <= sel;
      end
      assign {f_src2_preg, f_src2_en} = q;
    end else begin : g_no_src2_f
      assign f_src2_preg = '0;
      assign f_src2_en   = 1'b0;
    end

    if (HAS_SRC3) begin : g_src3_f
      localparam int W = PRF_IDX_WIDTH + 1;
      logic [W-1:0] e [DW], sel, q;
      for (genvar w = 0; w < DW; w++) begin : g_w
        assign e[w] = {enq_uop[w].src3_preg, enq_uop[w].src3_en};
      end
      ttg_onehot_mux #(.N(DW), .W(W)) u_m (.sel(hit), .data(e), .out(sel));
      always_ff @(posedge clk) begin
        if (!rst_n)     q <= '0;
        else if (write) q <= sel;
      end
      assign {f_src3_preg, f_src3_en} = q;
    end else begin : g_no_src3_f
      assign f_src3_preg = '0;
      assign f_src3_en   = 1'b0;
    end

    if (HAS_FTQ) begin : g_ftq_f
      localparam int W = FTQ_IDX_WIDTH + FTQ_OFFSET_WIDTH;
      logic [W-1:0] e [DW], sel, q;
      for (genvar w = 0; w < DW; w++) begin : g_w
        assign e[w] = {enq_uop[w].ftq_idx, enq_uop[w].ftq_offset};
      end
      ttg_onehot_mux #(.N(DW), .W(W)) u_m (.sel(hit), .data(e), .out(sel));
      always_ff @(posedge clk) begin
        if (!rst_n)     q <= '0;
        else if (write) q <= sel;
      end
      assign {f_ftq_idx, f_ftq_offset} = q;
    end else begin : g_no_ftq_f
      assign f_ftq_idx    = '0;
      assign f_ftq_offset = '0;
    end

    if (HAS_STQ) begin : g_stq_f
      localparam int W = STQ_IDX_WIDTH + 1;
      logic [W-1:0] e [DW], sel, q;
      for (genvar w = 0; w < DW; w++) begin : g_w
        assign e[w] = {enq_uop[w].stq_idx, enq_uop[w].stq_flag};
      end
      ttg_onehot_mux #(.N(DW), .W(W)) u_m (.sel(hit), .data(e), .out(sel));
      always_ff @(posedge clk) begin
        if (!rst_n)     q <= '0;
        else if (write) q <= sel;
      end
      assign {f_stq_idx, f_stq_flag} = q;
    end else begin : g_no_stq_f
      assign f_stq_idx  = '0;
      assign f_stq_flag = 1'b0;
    end

    if (HAS_LDQ) begin : g_ldq_f
      logic [LDQ_IDX_WIDTH-1:0] e [DW], sel, q;
      for (genvar w = 0; w < DW; w++) begin : g_w
        assign e[w] = enq_uop[w].ldq_idx;
      end
      ttg_onehot_mux #(.N(DW), .W(LDQ_IDX_WIDTH)) u_m (.sel(hit), .data(e), .out(sel));
      always_ff @(posedge clk) begin
        if (!rst_n)     q <= '0;
        else if (write) q <= sel;
      end
      assign f_ldq_idx = q;
    end else begin : g_no_ldq_f
      assign f_ldq_idx = '0;
    end

    if (HAS_CSR) begin : g_csr_f
      logic [CSR_IDX_WIDTH-1:0] e [DW], sel, q;
      for (genvar w = 0; w < DW; w++) begin : g_w
        assign e[w] = enq_uop[w].csr_idx;
      end
      ttg_onehot_mux #(.N(DW), .W(CSR_IDX_WIDTH)) u_m (.sel(hit), .data(e), .out(sel));
      always_ff @(posedge clk) begin
        if (!rst_n)     q <= '0;
        else if (write) q <= sel;
      end
      assign f_csr_idx = q;
    end else begin : g_no_csr_f
      assign f_csr_idx = '0;
    end

    if (HAS_ATOMIC) begin : g_atom_f
      logic [DW-1:0] e;
      logic q;
      for (genvar w = 0; w < DW; w++) begin : g_w
        assign e[w] = enq_uop[w].is_atomic;
      end
      always_ff @(posedge clk) begin
        if (!rst_n)     q <= 1'b0;
        else if (write) q <= |(hit & e);
      end
      assign f_is_atomic = q;
    end else begin : g_no_atom_f
      assign f_is_atomic = 1'b0;
    end

    if (HAS_FUNC7) begin : g_f7_f
      logic [6:0] e [DW], sel, q;
      for (genvar w = 0; w < DW; w++) begin : g_w
        assign e[w] = enq_uop[w].func7;
      end
      ttg_onehot_mux #(.N(DW), .W(7)) u_m (.sel(hit), .data(e), .out(sel));
      always_ff @(posedge clk) begin
        if (!rst_n)     q <= '0;
        else if (write) q <= sel;
      end
      assign f_func7 = q;
    end else begin : g_no_f7_f
      assign f_func7 = '0;
    end

    if (HAS_ALU_FL) begin : g_alu_fl
      logic [2:0] e [DW], sel, q;
      for (genvar w = 0; w < DW; w++) begin : g_w
        assign e[w] = {enq_uop[w].src1_is_pc, enq_uop[w].src2_is_imm, enq_uop[w].is_word};
      end
      ttg_onehot_mux #(.N(DW), .W(3)) u_m (.sel(hit), .data(e), .out(sel));
      always_ff @(posedge clk) begin
        if (!rst_n)     q <= '0;
        else if (write) q <= sel;
      end
      assign {f_src1_is_pc, f_src2_is_imm, f_is_word} = q;
    end else begin : g_no_alu_fl
      assign {f_src1_is_pc, f_src2_is_imm, f_is_word} = 3'b0;
    end

    if (HAS_FP_FL) begin : g_fp_fl
      logic [2:0] e [DW], sel, q;
      for (genvar w = 0; w < DW; w++) begin : g_w
        assign e[w] = {enq_uop[w].dest_fp, enq_uop[w].src1_fp, enq_uop[w].src2_fp};
      end
      ttg_onehot_mux #(.N(DW), .W(3)) u_m (.sel(hit), .data(e), .out(sel));
      always_ff @(posedge clk) begin
        if (!rst_n)     q <= '0;
        else if (write) q <= sel;
      end
      assign {f_dest_fp, f_src1_fp, f_src2_fp} = q;
    end else begin : g_no_fp_fl
      assign {f_dest_fp, f_src1_fp, f_src2_fp} = 3'b0;
    end

    if (IMM_W > 0) begin : g_imm_f
      localparam int IW = (IMM_W > 0) ? IMM_W : 1;
      logic [IW-1:0] e [DW], sel, q;
      for (genvar w = 0; w < DW; w++) begin : g_w
        assign e[w] = enq_uop[w].imm[IW-1:0];
      end
      ttg_onehot_mux #(.N(DW), .W(IW)) u_m (.sel(hit), .data(e), .out(sel));
      always_ff @(posedge clk) begin
        if (!rst_n)     q <= '0;
        else if (write) q <= sel;
      end
      if (IW == 32) begin : g_i32
        assign f_imm = q;
      end else if (IMM_SEXT) begin : g_isext
        assign f_imm = {{(32 - IW){q[IW-1]}}, q};
      end else begin : g_izext
        assign f_imm = {{(32 - IW){1'b0}}, q};
      end
    end else begin : g_no_imm_f
      assign f_imm = 32'd0;
    end

    assign uop_q = '{
      dest_preg:   f_dest_preg,
      src1_preg:   core_q.src1_preg,
      src2_preg:   f_src2_preg,
      src3_preg:   f_src3_preg,
      ftq_idx:     f_ftq_idx,
      ftq_offset:  f_ftq_offset,
      is_atomic:   f_is_atomic,
      dest_en:     f_dest_en,
      src1_en:     core_q.src1_en,
      src2_en:     f_src2_en,
      src3_en:     f_src3_en,
      dest_fp:     f_dest_fp,
      src1_fp:     f_src1_fp,
      src2_fp:     f_src2_fp,
      src1_is_pc:  f_src1_is_pc,
      src2_is_imm: f_src2_is_imm,
      is_word:     f_is_word,
      func3:       core_q.func3,
      func7:       f_func7,
      imm:         f_imm,
      csr_idx:     f_csr_idx,
      rob_idx:     core_q.rob_idx,
      stq_idx:     f_stq_idx,
      stq_flag:    f_stq_flag,
      ldq_idx:     f_ldq_idx,
      rob_flag:    core_q.rob_flag,
      op:          core_q.op
    };

    // ---- src1 wait, wake, and EXU bypass mask ----
    logic s1_cancel, s1_slow, s1_fast, s1_after_slow;
    if (SRC1_DOM == 1) begin : g_s1_fp
      assign s1_cancel    = HAS_CANCEL ? match_cancel(cancel_valid, cancel_preg, uop_q.src1_preg) : 1'b0;
      assign s1_slow      = lookup_fp_map(woken_slow_fp, uop_q.src1_preg);
      assign s1_fast      = 1'b0;
      assign slot_byp1[i] = '0;
    end else begin : g_s1_int
      logic [ALU_NUM-1:0] s1_fast_match, s1_slow_exu_match, enq_byp1_sel, byp1_q, byp1_d, fast_only_byp1;
      logic [1:0]         enq_mul1_sel, mul_byp1_q, mul_byp1_d;
      logic               s1_fast_cancel;
      assign s1_slow   = lookup_int_map(woken_slow_int, uop_q.src1_preg);
      always_comb begin
        s1_slow_exu_match = '0;
        for (int k = 0; k < ALU_NUM; k++)
          s1_fast_match[k] = fast_valid[k] && (fast_preg[k] == uop_q.src1_preg[INT_W-1:0]);
        for (int k = 0; k < 4; k++)
          s1_slow_exu_match[k] = slow_exu_valid[k] && (slow_exu_preg[k] == uop_q.src1_preg[INT_W-1:0]);
      end
      assign s1_fast = |s1_fast_match;
      ttg_onehot_mux #(.N(DW), .W(ALU_NUM)) u_eb1 (.sel(hit), .data(enq_byp1), .out(enq_byp1_sel));
      ttg_onehot_mux #(.N(DW), .W(2))       u_em1 (.sel(hit), .data(enq_mul1), .out(enq_mul1_sel));
      assign byp1_d = write ? enq_byp1_sel
                            : ((wait1_c && uop_q.src1_en && (uop_q.src1_preg != '0))
                               ? (s1_slow_exu_match | s1_fast_match) : '0);
      assign mul_byp1_d = write ? enq_mul1_sel
                                : ((wait1_c && uop_q.src1_en && (uop_q.src1_preg != '0))
                                   ? {s1_slow_exu_match[2], s1_slow_exu_match[0]} : 2'b00);
      always_ff @(posedge clk) begin
        if (!rst_n) begin
          byp1_q     <= '0;
          mul_byp1_q <= 2'b00;
        end else begin
          byp1_q     <= byp1_d;
          mul_byp1_q <= mul_byp1_d;
        end
      end
      assign fast_only_byp1 = byp1_q & ~{{(ALU_NUM-3){1'b0}}, mul_byp1_q[1], 1'b0, mul_byp1_q[0]};
      assign s1_fast_cancel = |(fast_only_byp1 & fast_cancel_raw);
      assign s1_cancel      = HAS_CANCEL ? (match_cancel(cancel_valid, cancel_preg, uop_q.src1_preg) || s1_fast_cancel) : 1'b0;
      assign slot_byp1[i]   = byp1_q;
    end
    assign wait1_c       = HAS_CANCEL ? (wait1_q || (uop_q.src1_en && s1_cancel)) : wait1_q;
    assign s1_after_slow = wait1_c & ~s1_slow;
    assign wait1_d       = write ? |(hit & enq_wait1) : (s1_after_slow & ~s1_fast);

    // ---- src2 wait, wake, and EXU bypass mask (compiled out for IQ_MEM) ----
    if (HAS_SRC2) begin : g_s2
      logic wait2_q, wait2_d;
      logic s2_cancel, s2_slow, s2_fast, s2_after_slow;
      if (SRC2_DOM == 1) begin : g_s2_fp
        assign s2_cancel    = HAS_CANCEL ? match_cancel(cancel_valid, cancel_preg, uop_q.src2_preg) : 1'b0;
        assign s2_slow      = lookup_fp_map(woken_slow_fp, uop_q.src2_preg);
        assign s2_fast      = 1'b0;
        assign slot_byp2[i] = '0;
      end else if (SRC2_DOM == 2) begin : g_s2_both
        logic s2_is_int, s2_fast_cancel;
        logic [ALU_NUM-1:0] s2_fast_match, s2_slow_exu_match, enq_byp2_sel, byp2_q, byp2_d, fast_only_byp2;
        logic [1:0]         enq_mul2_sel, mul_byp2_q, mul_byp2_d;
        assign s2_is_int = uop_q.src2_preg < PRF_IDX_WIDTH'(PRF_NUM);
        assign s2_slow   = s2_is_int ? lookup_int_map(woken_slow_int, uop_q.src2_preg)
                                     : lookup_fp_map(woken_slow_fp, uop_q.src2_preg);
        always_comb begin
          s2_slow_exu_match = '0;
          for (int k = 0; k < ALU_NUM; k++)
            s2_fast_match[k] = s2_is_int && fast_valid[k] && (fast_preg[k] == uop_q.src2_preg[INT_W-1:0]);
          for (int k = 0; k < 4; k++)
            s2_slow_exu_match[k] = s2_is_int && slow_exu_valid[k] && (slow_exu_preg[k] == uop_q.src2_preg[INT_W-1:0]);
        end
        assign s2_fast = |s2_fast_match;
        ttg_onehot_mux #(.N(DW), .W(ALU_NUM)) u_eb2 (.sel(hit), .data(enq_byp2), .out(enq_byp2_sel));
        ttg_onehot_mux #(.N(DW), .W(2))       u_em2 (.sel(hit), .data(enq_mul2), .out(enq_mul2_sel));
        assign byp2_d = write ? enq_byp2_sel
                              : ((wait2_c && uop_q.src2_en && (uop_q.src2_preg != '0))
                                 ? (s2_slow_exu_match | s2_fast_match) : '0);
        assign mul_byp2_d = write ? enq_mul2_sel
                                  : ((wait2_c && uop_q.src2_en && (uop_q.src2_preg != '0))
                                     ? {s2_slow_exu_match[2], s2_slow_exu_match[0]} : 2'b00);
        always_ff @(posedge clk) begin
          if (!rst_n) begin
            byp2_q     <= '0;
            mul_byp2_q <= 2'b00;
          end else begin
            byp2_q     <= byp2_d;
            mul_byp2_q <= mul_byp2_d;
          end
        end
        assign fast_only_byp2 = byp2_q & ~{{(ALU_NUM-3){1'b0}}, mul_byp2_q[1], 1'b0, mul_byp2_q[0]};
        assign s2_fast_cancel = |(fast_only_byp2 & fast_cancel_raw);
        assign s2_cancel      = HAS_CANCEL ? (match_cancel(cancel_valid, cancel_preg, uop_q.src2_preg) || s2_fast_cancel) : 1'b0;
        assign slot_byp2[i]   = byp2_q;
      end else begin : g_s2_int
        logic [ALU_NUM-1:0] s2_fast_match, s2_slow_exu_match, enq_byp2_sel, byp2_q, byp2_d, fast_only_byp2;
        logic [1:0]         enq_mul2_sel, mul_byp2_q, mul_byp2_d;
        logic               s2_fast_cancel;
        assign s2_slow   = lookup_int_map(woken_slow_int, uop_q.src2_preg);
        always_comb begin
          s2_slow_exu_match = '0;
          for (int k = 0; k < ALU_NUM; k++)
            s2_fast_match[k] = fast_valid[k] && (fast_preg[k] == uop_q.src2_preg[INT_W-1:0]);
          for (int k = 0; k < 4; k++)
            s2_slow_exu_match[k] = slow_exu_valid[k] && (slow_exu_preg[k] == uop_q.src2_preg[INT_W-1:0]);
        end
        assign s2_fast = |s2_fast_match;
        ttg_onehot_mux #(.N(DW), .W(ALU_NUM)) u_eb2 (.sel(hit), .data(enq_byp2), .out(enq_byp2_sel));
        ttg_onehot_mux #(.N(DW), .W(2))       u_em2 (.sel(hit), .data(enq_mul2), .out(enq_mul2_sel));
        assign byp2_d = write ? enq_byp2_sel
                              : ((wait2_c && uop_q.src2_en && (uop_q.src2_preg != '0))
                                 ? (s2_slow_exu_match | s2_fast_match) : '0);
        assign mul_byp2_d = write ? enq_mul2_sel
                                  : ((wait2_c && uop_q.src2_en && (uop_q.src2_preg != '0))
                                     ? {s2_slow_exu_match[2], s2_slow_exu_match[0]} : 2'b00);
        always_ff @(posedge clk) begin
          if (!rst_n) begin
            byp2_q     <= '0;
            mul_byp2_q <= 2'b00;
          end else begin
            byp2_q     <= byp2_d;
            mul_byp2_q <= mul_byp2_d;
          end
        end
        assign fast_only_byp2 = byp2_q & ~{{(ALU_NUM-3){1'b0}}, mul_byp2_q[1], 1'b0, mul_byp2_q[0]};
        assign s2_fast_cancel = |(fast_only_byp2 & fast_cancel_raw);
        assign s2_cancel      = HAS_CANCEL ? (match_cancel(cancel_valid, cancel_preg, uop_q.src2_preg) || s2_fast_cancel) : 1'b0;
        assign slot_byp2[i]   = byp2_q;
      end
      assign wait2_c       = HAS_CANCEL ? (wait2_q || (uop_q.src2_en && s2_cancel)) : wait2_q;
      assign s2_after_slow = wait2_c & ~s2_slow;
      assign wait2_d       = write ? |(hit & enq_wait2) : (s2_after_slow & ~s2_fast);
      always_ff @(posedge clk) begin
        if (!rst_n) wait2_q <= 1'b0;
        else        wait2_q <= wait2_d;
      end
`ifndef SYNTHESIS
      logic s2_lsu_cn_chk, s2_fast_cam_chk;
      assign s2_lsu_cn_chk = HAS_CANCEL ? match_cancel(cancel_valid, cancel_preg, uop_q.src2_preg) : 1'b0;
      always_comb begin
        s2_fast_cam_chk = 1'b0;
        if (HAS_CANCEL && (SRC2_DOM != 1)) begin
          for (int a = 0; a < ALU_NUM; a++)
            s2_fast_cam_chk = s2_fast_cam_chk || (fast_cancel_valid_chk[a] && (fast_cancel_preg_chk[a] == uop_q.src2_preg));
        end
      end
      assert property (@(posedge clk) disable iff (!rst_n)
        (valid_q && !old_killed && !flush_all) |->
          (wait2_c == (wait2_q || (uop_q.src2_en && (s2_lsu_cn_chk || s2_fast_cam_chk)))));
`endif
    end else begin : g_no_s2
      assign wait2_c      = 1'b0;
      assign slot_byp2[i] = '0;
    end

    // ---- src3 wait & wake (FP queue only, FP domain only, no fast wake-up) ----
    if (HAS_SRC3) begin : g_s3
      logic wait3_q, wait3_d;
      logic s3_cancel, s3_slow;
      assign s3_cancel = HAS_CANCEL ? match_cancel(cancel_valid, cancel_preg, uop_q.src3_preg) : 1'b0;
      assign s3_slow   = lookup_fp_map(woken_slow_fp, uop_q.src3_preg);
      assign wait3_c   = HAS_CANCEL ? (wait3_q || (uop_q.src3_en && s3_cancel)) : wait3_q;
      assign wait3_d   = write ? |(hit & enq_wait3) : (wait3_c & ~s3_slow);
      always_ff @(posedge clk) begin
        if (!rst_n) wait3_q <= 1'b0;
        else        wait3_q <= wait3_d;
      end
    end else begin : g_no_s3
      assign wait3_c = 1'b0;
    end

    logic [LSU_LDU_COUNT-1:0] spec_t1_q, spec_t1_d, spec_rr_q, spec_rr_d;
    logic [LSU_LDU_COUNT-1:0] cn_port_mask, enq_spec_t1_sel, wake_spec_m;
    logic                     enq_killed_hit;
    logic                     rr_active, rr_cancelled, rr_retired, park_spec;

    assign cn_port_mask = cancel_valid[LSU_LDU_COUNT-1:0];
    ttg_onehot_mux #(.N(DW), .W(LSU_LDU_COUNT)) u_et1 (.sel(hit), .data(enq_spec_t1), .out(enq_spec_t1_sel));

    // RR-stage speculative state: registers and cancels only. Kept out of the always_comb below, which also reads
    // issue_clear (this cycle's grant): slot_ready (from rr_active) feeds the select that produces the grant.
    assign rr_active    = |spec_rr_q;
    assign rr_cancelled = |(spec_rr_q & cn_port_mask);
    assign rr_retired   = rr_active && !rr_cancelled;

    // Ref: IssueQueue::enqueue / comb_wakeup / commit_issue / flush_br / clear_br / flush_all
    // Evaluate branch kill in parallel with u_alloc / u_new (enq_killed per lane, old_killed from core_q)
    always_comb begin
      enq_killed_hit = |(hit & enq_killed);
      old_killed     = flush_br && isu_rob_younger(core_q.rob_idx, core_q.rob_flag, flush_rob_idx, flush_rob_flag);
      park_spec      = issue_clear[i] && (|spec_t1_q);
      valid_d        = ((|(hit & ~enq_killed)) ||
                        (valid_q && !old_killed && !(issue_clear[i] && !(|spec_t1_q)) && !rr_retired)) && !flush_all;
      spec_rr_d      = (flush_all || old_killed || write || rr_active) ? '0
                                                                        : (park_spec ? spec_t1_q : '0);
      for (int k = 0; k < LSU_LDU_COUNT; k++) begin
        logic m1, m2, m3;
        m1 = wait1_c && uop_q.src1_en && (uop_q.src1_preg == lsu_l1_wake_preg[k]);
        m2 = HAS_SRC2 && wait2_c && uop_q.src2_en && (uop_q.src2_preg == lsu_l1_wake_preg[k]);
        m3 = HAS_SRC3 && wait3_c && uop_q.src3_en && (uop_q.src3_preg == lsu_l1_wake_preg[k]);
        wake_spec_m[k] = lsu_l1_wake_valid[k] && (m1 || m2 || m3);
      end
      spec_t1_d = (!valid_d || park_spec) ? '0
                                            : (write ? (enq_killed_hit ? '0 : enq_spec_t1_sel) : wake_spec_m);
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        valid_q   <= 1'b0;
        core_q    <= '0;
        wait1_q   <= 1'b0;
        spec_t1_q <= '0;
        spec_rr_q <= '0;
      end else begin
        valid_q   <= valid_d;
        if (write) core_q <= iq_core_t'(new_core);
        wait1_q   <= wait1_d;
        spec_t1_q <= spec_t1_d;
        spec_rr_q <= spec_rr_d;
      end
    end

    assign slot_valid[i]   = valid_q;
    assign slot_rr_ret[i]  = valid_q && rr_retired;
    assign slot_surv_br[i] = valid_q && !old_killed && !rr_retired;
    assign slot_ready[i]   = valid_q && !rr_active && !wait1_c && !wait2_c && !wait3_c;
    assign slot_uop[i]     = uop_q;
    assign slot_spec_t1[i] = spec_t1_q;

`ifndef SYNTHESIS
    logic s1_lsu_cn_chk, s1_fast_cam_chk;
    assign s1_lsu_cn_chk = HAS_CANCEL ? match_cancel(cancel_valid, cancel_preg, uop_q.src1_preg) : 1'b0;
    always_comb begin
      s1_fast_cam_chk = 1'b0;
      if (HAS_CANCEL && (SRC1_DOM != 1)) begin
        for (int a = 0; a < ALU_NUM; a++)
          s1_fast_cam_chk = s1_fast_cam_chk || (fast_cancel_valid_chk[a] && (fast_cancel_preg_chk[a] == uop_q.src1_preg));
      end
    end
    assert property (@(posedge clk) disable iff (!rst_n)
      (valid_q && !old_killed && !flush_all) |->
        (wait1_c == (wait1_q || (uop_q.src1_en && (s1_lsu_cn_chk || s1_fast_cam_chk)))));
`endif
  end

endmodule

`default_nettype wire
