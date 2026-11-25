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
  parameter int SIZE     = 64,
  parameter int DW       = IQ_DISPATCH_WIDTH,
  parameter bit HAS_SRC2 = 1'b1,
  parameter bit HAS_SRC3 = 1'b0,
  parameter bit HAS_CANCEL = 1'b0,
  // 0 = integer domain only, 1 = FP domain only, 2 = both domains (STD src2)
  parameter int SRC1_DOM = 0,
  parameter int SRC2_DOM = 0,
  parameter int FP_TAGS  = FP_EN ? FPRF_NUM : 1,
  parameter int INT_W    = $clog2(PRF_NUM)
) (
  input  logic                     clk,
  input  logic                     rst_n,
  // enqueue: slot_onehot[w] is the slot written by lane w (zero when lane w is idle)
  input  logic [SIZE-1:0]          enq_slot [DW],
  input  isu_uop_t                 enq_uop  [DW],
  input  logic [DW-1:0]            enq_wait1,
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: unused when HAS_SRC2/3 == 0 or domain does not read the other bitmap
  input  logic [DW-1:0]            enq_wait2,
  input  logic [DW-1:0]            enq_wait3,
  input  logic [ALU_NUM-1:0]       enq_byp1 [DW],
  input  logic [ALU_NUM-1:0]       enq_byp2 [DW],
  input  logic [PRF_NUM-1:0]       woken_slow_int,
  input  logic [FP_TAGS-1:0]       woken_slow_fp,
  input  logic [3:0]               slow_exu_valid,
  input  logic [INT_W-1:0]         slow_exu_preg [4],
  input  logic [FAST_UNITS-1:0]    fast_valid,
  input  logic [INT_W-1:0]         fast_preg [FAST_UNITS],
  input  logic [LSU_LDU_COUNT-1:0] cancel_valid,   // wrong speculative load wake-up (LP_L2[3]): 4-way direct compare
  input  logic [PRF_IDX_WIDTH-1:0] cancel_preg [LSU_LDU_COUNT],
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [SIZE-1:0]          issue_clear,    // slots granted this cycle
  input  logic                     flush_all,
  input  logic                     flush_br,       // misprediction without a global flush
  input  logic [ROB_IDX_WIDTH-1:0] flush_rob_idx,
  input  logic                     flush_rob_flag,
  // registered view (what select and the PRF read this cycle)
  output logic [SIZE-1:0]          slot_valid,
  output logic [SIZE-1:0]          slot_ready,
  output isu_uop_t                 slot_uop  [SIZE],
  output logic [ALU_NUM-1:0]       slot_byp1 [SIZE],
  output logic [ALU_NUM-1:0]       slot_byp2 [SIZE]
);

  localparam int UW   = $bits(isu_uop_t);
  localparam int FP_W = (FP_TAGS > 1) ? $clog2(FP_TAGS) : 1;

  function automatic logic match_cancel(
    input logic [LSU_LDU_COUNT-1:0] cn_v,
    input logic [PRF_IDX_WIDTH-1:0] cn_p [LSU_LDU_COUNT],
    input logic [PRF_IDX_WIDTH-1:0] preg
  );
    logic m;
    m = 1'b0;
    for (int k = 0; k < LSU_LDU_COUNT; k++)
      m = m || (cn_v[k] && (cn_p[k] == preg));
    return m;
  endfunction

  function automatic logic lookup_int_map(input logic [PRF_NUM-1:0] m, input logic [PRF_IDX_WIDTH-1:0] preg);
    return (preg < PRF_IDX_WIDTH'(PRF_NUM)) ? m[preg[INT_W-1:0]] : 1'b0;
  endfunction

  function automatic logic lookup_fp_map(input logic [FP_TAGS-1:0] m, input logic [PRF_IDX_WIDTH-1:0] preg);
    logic [PRF_IDX_WIDTH-1:0] idx;
    idx = preg - PRF_IDX_WIDTH'(FP_TAG_BASE);
    if (!FP_EN) return 1'b0;
    return (preg >= PRF_IDX_WIDTH'(FP_TAG_BASE)) && (idx < PRF_IDX_WIDTH'(FP_TAGS)) ? m[idx[FP_W-1:0]] : 1'b0;
  endfunction

  logic [UW-1:0] enq_bits [DW];
  logic [DW-1:0] enq_killed;
  for (genvar w = 0; w < DW; w++) begin : g_pack
    assign enq_bits[w]   = enq_uop[w];
    assign enq_killed[w] = flush_br && isu_rob_younger(enq_uop[w].rob_idx, enq_uop[w].rob_flag, flush_rob_idx, flush_rob_flag);
  end

  for (genvar i = 0; i < SIZE; i++) begin : g_slot
    logic [DW-1:0] hit;                  // enqueue lane that writes this slot
    logic          write;
    logic [UW-1:0] new_bits;
    logic          valid_q, valid_d;
    isu_uop_t      uop_q, uop_d;
    logic          wait1_q, wait1_d, wait1_c;
    logic          wait2_c, wait3_c;
    logic          old_killed;

    for (genvar w = 0; w < DW; w++) begin : g_hit
      assign hit[w] = enq_slot[w][i];
    end
    assign write = |hit;
    ttg_onehot_mux #(.N(DW), .W(UW)) u_new (.sel(hit), .data(enq_bits), .out(new_bits));

    // ---- src1 wait, wake, and EXU bypass mask ----
    logic s1_cancel, s1_slow, s1_fast, s1_after_slow;
    if (SRC1_DOM == 1) begin : g_s1_fp
      assign s1_cancel    = HAS_CANCEL ? match_cancel(cancel_valid, cancel_preg, uop_q.src1_preg) : 1'b0;
      assign s1_slow      = lookup_fp_map(woken_slow_fp, uop_q.src1_preg);
      assign s1_fast      = 1'b0;
      assign slot_byp1[i] = '0;
    end else begin : g_s1_int
      logic [ALU_NUM-1:0] s1_fast_match, s1_slow_exu_match, enq_byp1_sel, byp1_q, byp1_d;
      assign s1_cancel = HAS_CANCEL ? match_cancel(cancel_valid, cancel_preg, uop_q.src1_preg) : 1'b0;
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
      assign byp1_d = write ? enq_byp1_sel
                            : ((wait1_c && uop_q.src1_en && (uop_q.src1_preg != '0))
                               ? (s1_slow_exu_match | s1_fast_match) : '0);
      always_ff @(posedge clk) begin
        if (!rst_n) byp1_q <= '0;
        else        byp1_q <= byp1_d;
      end
      assign slot_byp1[i] = byp1_q;
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
        logic s2_is_int;
        logic [ALU_NUM-1:0] s2_fast_match, s2_slow_exu_match, enq_byp2_sel, byp2_q, byp2_d;
        assign s2_is_int = uop_q.src2_preg < PRF_IDX_WIDTH'(PRF_NUM);
        assign s2_cancel = HAS_CANCEL ? match_cancel(cancel_valid, cancel_preg, uop_q.src2_preg) : 1'b0;
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
        assign byp2_d = write ? enq_byp2_sel
                              : ((wait2_c && uop_q.src2_en && (uop_q.src2_preg != '0))
                                 ? (s2_slow_exu_match | s2_fast_match) : '0);
        always_ff @(posedge clk) begin
          if (!rst_n) byp2_q <= '0;
          else        byp2_q <= byp2_d;
        end
        assign slot_byp2[i] = byp2_q;
      end else begin : g_s2_int
        logic [ALU_NUM-1:0] s2_fast_match, s2_slow_exu_match, enq_byp2_sel, byp2_q, byp2_d;
        assign s2_cancel = HAS_CANCEL ? match_cancel(cancel_valid, cancel_preg, uop_q.src2_preg) : 1'b0;
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
        assign byp2_d = write ? enq_byp2_sel
                              : ((wait2_c && uop_q.src2_en && (uop_q.src2_preg != '0))
                                 ? (s2_slow_exu_match | s2_fast_match) : '0);
        always_ff @(posedge clk) begin
          if (!rst_n) byp2_q <= '0;
          else        byp2_q <= byp2_d;
        end
        assign slot_byp2[i] = byp2_q;
      end
      assign wait2_c       = HAS_CANCEL ? (wait2_q || (uop_q.src2_en && s2_cancel)) : wait2_q;
      assign s2_after_slow = wait2_c & ~s2_slow;
      assign wait2_d       = write ? |(hit & enq_wait2) : (s2_after_slow & ~s2_fast);
      always_ff @(posedge clk) begin
        if (!rst_n) wait2_q <= 1'b0;
        else        wait2_q <= wait2_d;
      end
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

    // Ref: IssueQueue::enqueue / comb_wakeup / commit_issue / flush_br / clear_br / flush_all
    // Evaluate branch kill in parallel with u_alloc / u_new (enq_killed per lane, old_killed from uop_q)
    always_comb begin
      old_killed = flush_br && isu_rob_younger(uop_q.rob_idx, uop_q.rob_flag, flush_rob_idx, flush_rob_flag);
      uop_d      = write ? isu_uop_t'(new_bits) : uop_q;
      valid_d    = ((|(hit & ~enq_killed)) || (valid_q && !issue_clear[i] && !old_killed)) && !flush_all;
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        valid_q <= 1'b0;
        uop_q   <= '0;
        wait1_q <= 1'b0;
      end else begin
        valid_q <= valid_d;
        uop_q   <= uop_d;
        wait1_q <= wait1_d;
      end
    end

    assign slot_valid[i] = valid_q;
    assign slot_ready[i] = valid_q && !wait1_c && !wait2_c && !wait3_c;
    assign slot_uop[i]   = uop_q;
  end

endmodule

`default_nettype wire
