// Ref: back-end/include/IssueQueue.h  class IssueQueue  (enqueue, wake-up, schedule, issue commit, flush)
`default_nettype none

// One issue queue: parameterised by depth, enqueue lanes and its physical issue ports.
module isu_iq
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
#(
  parameter int SIZE      = 64,
  parameter int DW        = IQ_DISPATCH_WIDTH,
  parameter int NP        = 4,
  parameter int QID       = 0,   // issue queue number (its ports: isu_pkg iq_port)
  // memory queue with shared AGUs: the SH_N ports from SH_STA_LO (store addresses) share an AGU with the SH_N ports from SH_LO_LD
  // (loads): a load that is granted keeps it, the store-address port is not granted then (its pick stays taken)
  parameter int SH_N      = 0,
  parameter int SH_LD_LO  = 0,
  parameter int SH_STA_LO = 0,
  parameter bit AGE_EN    = 1'b0,   // the oldest-on-first-port select (isu_iq_select)
  parameter bit HAS_SRC2  = 1'b1,
  parameter bit HAS_SRC3  = 1'b0,
  parameter int SRC1_DOM  = 0,      // 0 = INT, 1 = FP
  parameter int SRC2_DOM  = 0,      // 0 = INT, 1 = FP, 2 = BOTH
  parameter int FP_TAGS   = FP_EN ? FPRF_NUM : 1,
  parameter int INT_W     = $clog2(PRF_NUM)
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [DW-1:0]            enq_valid,
  input  isu_enq_t                 enq [DW],
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: queues use only their domain's slow bitmap / fast wake-ups
  input  logic [PRF_NUM-1:0]       woken_slow_int,
  input  logic [FP_TAGS-1:0]       woken_slow_fp,
  input  logic [3:0]               slow_exu_valid,
  input  logic [INT_W-1:0]         slow_exu_preg [4],
  input  logic [FAST_UNITS-1:0]    fast_valid,
  input  logic [INT_W-1:0]         fast_preg [FAST_UNITS],
  input  logic [PRF_NUM-1:0]       cancel_int,      // wake-up of the previous cycle was wrong: waiting again (LP_L2)
  input  logic [FP_TAGS-1:0]       cancel_fp,
  /* verilator lint_on UNUSEDSIGNAL */
  input  op_set_t                  fu_ready [NP],   // per port: op classes the functional unit accepts now
  input  logic [NP-1:0]            gate_ok,         // FP write-port gate (isu_fp_gate); 1 for ports without one
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: a queue whose ports have no blockable class (memory, STD, BR) does not read it
  input  logic [WB_NCLS-1:0]       cls_free [NP],   // per port and completion class: the completion cycle is free (EXP-046)
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic                     issue_block,     // rob flush or misprediction this cycle
  input  logic                     flush_all,
  input  logic                     flush_br,
  input  logic [BR_MASK_WIDTH-1:0] flush_br_mask,
  input  logic [BR_MASK_WIDTH-1:0] clear_mask,
  output logic [READY_NUM_W-1:0]   free_slots,      // registered occupancy, as seen by dispatch
  output logic [NP-1:0]            cand_valid,      // port's pick passes FU readiness and issue block (before the gate)
  output logic [NP-1:0]            grant_valid,
  output isu_uop_t                 grant_uop [NP],
  output logic [ALU_NUM-1:0]       grant_src1_byp [NP],
  output logic [ALU_NUM-1:0]       grant_src2_byp [NP]
);

  localparam int UW = $bits(isu_uop_t);
  localparam int CW = $clog2(SIZE + 1);

  logic [SIZE-1:0] slot_valid, slot_ready;
  isu_uop_t        slot_uop  [SIZE];
  op_set_t         slot_op   [SIZE];
  logic [ALU_NUM-1:0] slot_byp1 [SIZE];
  logic [ALU_NUM-1:0] slot_byp2 [SIZE];
  logic [SIZE-1:0] sel_onehot [NP];
  logic [NP-1:0]   sel_valid;
  logic [SIZE-1:0] granted_slot;
  logic [SIZE-1:0] enq_slot [DW];
  logic [SIZE-1:0] write_slot;           // slots written by an enqueue this cycle
  isu_uop_t        enq_uop  [DW];
  logic [DW-1:0]   enq_wait1, enq_wait2, enq_wait3;
  logic [ALU_NUM-1:0] enq_byp1 [DW];
  logic [ALU_NUM-1:0] enq_byp2 [DW];

  // ---- select and grant (reads registered state only) ----
  logic [SIZE-1:0] older [SIZE];
  if (AGE_EN) begin : g_age
    isu_age_matrix #(.SIZE(SIZE)) u_age (.clk(clk), .write(write_slot), .slot_valid(slot_valid), .older(older));
  end else begin : g_noage
    for (genvar i = 0; i < SIZE; i++) begin : g_z
      assign older[i] = '0;
    end
  end
  // EXP-046: the slots each port may take this cycle: the slot's completion cycle on the port is free. Only the classes that
  // can be blocked on the port (isu_pkg cls_blockable) are looked at; the class of a slot comes from its one-hot op (plus is_word / func7
  // for the divides). Both inputs are registered (the stored uop, the reservation table).
  // the classes that can be blocked on some port of this queue; each slot keeps those class bits in a register written at enqueue,
  // so the select reads a flop instead of decoding the stored op (cls_hit) every cycle
  function automatic logic [WB_NCLS-1:0] q_blockable();
    logic [WB_NCLS-1:0] m = '0;
    for (int p = 0; p < NP; p++) for (int c = 0; c < WB_NCLS; c++) if (cls_blockable(iq_port(QID, p), c)) m[c] = 1'b1;
    return m;
  endfunction
  localparam logic [WB_NCLS-1:0] QBLK = q_blockable();
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: all zero (not read) in a queue without blockable classes (memory, STD, BR)
  logic [WB_NCLS-1:0] slot_cls_q [SIZE];       // slot's completion class, one-hot, only the QBLK bits (read only while the slot is valid)
  /* verilator lint_on UNUSEDSIGNAL */
  for (genvar i = 0; i < SIZE; i++) begin : g_cls
    for (genvar c = 0; c < WB_NCLS; c++) begin : g_c
      if (QBLK[c]) begin : g_k
        logic nxt;
        always_comb begin
          nxt = slot_cls_q[i][c];
          for (int w = 0; w < DW; w++)
            if (enq_slot[w][i]) nxt = cls_hit(op_onehot(enq_uop[w].op), enq_uop[w].is_word, enq_uop[w].func7, c);
        end
        always_ff @(posedge clk) slot_cls_q[i][c] <= nxt;
      end else begin : g_z
        assign slot_cls_q[i][c] = 1'b0;
      end
    end
  end
  logic [SIZE-1:0] port_ok [NP];
  for (genvar p = 0; p < NP; p++) begin : g_pok
    localparam int PP = iq_port(QID, p);
    logic [SIZE-1:0] blocked [WB_NCLS];       // per class: slots of that class whose completion cycle on the port is taken
    for (genvar c = 0; c < WB_NCLS; c++) begin : g_c
      if (cls_blockable(PP, c)) begin : g_b
        for (genvar i = 0; i < SIZE; i++) begin : g_s
          assign blocked[c][i] = !cls_free[p][c] && slot_cls_q[i][c];
        end
      end else begin : g_n
        assign blocked[c] = '0;
      end
    end
    always_comb begin
      port_ok[p] = '1;
      for (int c = 0; c < WB_NCLS; c++) port_ok[p] = port_ok[p] & ~blocked[c];
    end
  end
  isu_iq_select #(.SIZE(SIZE), .NP(NP), .QID(QID), .AGE_EN(AGE_EN)) u_select (
    .ready(slot_ready), .entry_op(slot_op), .older(older), .port_ok(port_ok), .sel_onehot(sel_onehot), .sel_valid(sel_valid));

  localparam int BYPW = 2 * ALU_NUM;
  logic [UW-1:0]   slot_bits [SIZE];
  logic [BYPW-1:0] slot_byp_bits [SIZE];
  for (genvar i = 0; i < SIZE; i++) begin : g_bits
    assign slot_bits[i]     = slot_uop[i];
    assign slot_byp_bits[i] = {slot_byp2[i], slot_byp1[i]};
  end

  logic [SIZE-1:0] granted_by_port [NP];
  for (genvar p = 0; p < NP; p++) begin : g_port
    logic [UW-1:0]   sel_bits;
    logic [BYPW-1:0] sel_byp;
    isu_uop_t        sel_uop;
    ttg_onehot_mux #(.N(SIZE), .W(UW))   u_read     (.sel(sel_onehot[p]), .data(slot_bits),     .out(sel_bits));
    ttg_onehot_mux #(.N(SIZE), .W(BYPW)) u_read_byp (.sel(sel_onehot[p]), .data(slot_byp_bits), .out(sel_byp));
    assign sel_uop           = isu_uop_t'(sel_bits);
    assign grant_uop[p]      = sel_uop;
    assign grant_src1_byp[p] = sel_byp[ALU_NUM-1:0];
    assign grant_src2_byp[p] = sel_byp[BYPW-1:ALU_NUM];
    assign cand_valid[p]  = sel_valid[p] && !issue_block && ((fu_ready[p] & op_onehot(sel_uop.op)) != '0);
    if (SH_N > 0 && p >= SH_STA_LO && p < SH_STA_LO + SH_N) begin : g_shared
      assign grant_valid[p] = cand_valid[p] && gate_ok[p] && !grant_valid[SH_LD_LO + (p - SH_STA_LO)];
    end else begin : g_own
      assign grant_valid[p] = cand_valid[p] && gate_ok[p];
    end
    assign granted_by_port[p] = sel_onehot[p] & {SIZE{grant_valid[p]}};
  end

  // Ref: IssueQueue::commit_issue
  always_comb begin
    granted_slot = '0;
    for (int p = 0; p < NP; p++) granted_slot = granted_slot | granted_by_port[p];
  end

  // ---- enqueue: dispatch uop, wake-up of this cycle folded in, slot allocation ----
  localparam int FP_W = (FP_TAGS > 1) ? $clog2(FP_TAGS) : 1;
  function automatic logic enq_int_slow(input logic [PRF_IDX_WIDTH-1:0] preg);
    return (preg < PRF_IDX_WIDTH'(PRF_NUM)) ? woken_slow_int[preg[INT_W-1:0]] : 1'b0;
  endfunction
  function automatic logic enq_fp_slow(input logic [PRF_IDX_WIDTH-1:0] preg);
    logic [PRF_IDX_WIDTH-1:0] idx;
    idx = preg - PRF_IDX_WIDTH'(FP_TAG_BASE);
    if (!FP_EN) return 1'b0;
    return (preg >= PRF_IDX_WIDTH'(FP_TAG_BASE)) && (idx < PRF_IDX_WIDTH'(FP_TAGS)) ? woken_slow_fp[idx[FP_W-1:0]] : 1'b0;
  endfunction

  for (genvar w = 0; w < DW; w++) begin : g_enq
    logic e1_woken;
    assign enq_uop[w] = enq[w].uop;
    if (SRC1_DOM == 1) begin : g_e1_fp
      assign e1_woken    = enq_fp_slow(enq[w].uop.src1_preg);
      assign enq_byp1[w] = '0;
    end else begin : g_e1_int
      logic [ALU_NUM-1:0] e1_fast_m, e1_slow_m;
      always_comb begin
        e1_slow_m = '0;
        for (int k = 0; k < ALU_NUM; k++)
          e1_fast_m[k] = fast_valid[k] && (fast_preg[k] == enq[w].uop.src1_preg[INT_W-1:0]);
        for (int k = 0; k < 4; k++)
          e1_slow_m[k] = slow_exu_valid[k] && (slow_exu_preg[k] == enq[w].uop.src1_preg[INT_W-1:0]);
      end
      assign e1_woken    = enq_int_slow(enq[w].uop.src1_preg) || (|e1_fast_m);
      assign enq_byp1[w] = (enq[w].uop.src1_en && (enq[w].uop.src1_preg != '0))
                           ? (e1_slow_m | e1_fast_m) : '0;
    end
    assign enq_wait1[w] = enq[w].uop.src1_en && enq[w].src1_busy && !e1_woken;

    if (HAS_SRC2) begin : g_e2
      logic e2_woken;
      if (SRC2_DOM == 1) begin : g_e2_fp
        assign e2_woken    = enq_fp_slow(enq[w].uop.src2_preg);
        assign enq_byp2[w] = '0;
      end else if (SRC2_DOM == 2) begin : g_e2_both
        logic e2_is_int;
        logic [ALU_NUM-1:0] e2_fast_m, e2_slow_m;
        assign e2_is_int = enq[w].uop.src2_preg < PRF_IDX_WIDTH'(PRF_NUM);
        always_comb begin
          e2_slow_m = '0;
          for (int k = 0; k < ALU_NUM; k++)
            e2_fast_m[k] = e2_is_int && fast_valid[k] && (fast_preg[k] == enq[w].uop.src2_preg[INT_W-1:0]);
          for (int k = 0; k < 4; k++)
            e2_slow_m[k] = e2_is_int && slow_exu_valid[k] && (slow_exu_preg[k] == enq[w].uop.src2_preg[INT_W-1:0]);
        end
        assign e2_woken    = e2_is_int ? (enq_int_slow(enq[w].uop.src2_preg) || (|e2_fast_m))
                                       : enq_fp_slow(enq[w].uop.src2_preg);
        assign enq_byp2[w] = (enq[w].uop.src2_en && (enq[w].uop.src2_preg != '0))
                             ? (e2_slow_m | e2_fast_m) : '0;
      end else begin : g_e2_int
        logic [ALU_NUM-1:0] e2_fast_m, e2_slow_m;
        always_comb begin
          e2_slow_m = '0;
          for (int k = 0; k < ALU_NUM; k++)
            e2_fast_m[k] = fast_valid[k] && (fast_preg[k] == enq[w].uop.src2_preg[INT_W-1:0]);
          for (int k = 0; k < 4; k++)
            e2_slow_m[k] = slow_exu_valid[k] && (slow_exu_preg[k] == enq[w].uop.src2_preg[INT_W-1:0]);
        end
        assign e2_woken    = enq_int_slow(enq[w].uop.src2_preg) || (|e2_fast_m);
        assign enq_byp2[w] = (enq[w].uop.src2_en && (enq[w].uop.src2_preg != '0))
                             ? (e2_slow_m | e2_fast_m) : '0;
      end
      assign enq_wait2[w] = enq[w].uop.src2_en && enq[w].src2_busy && !e2_woken;
    end else begin : g_no_e2
      assign enq_wait2[w] = 1'b0;
      assign enq_byp2[w]  = '0;
    end

    if (HAS_SRC3) begin : g_e3
      logic e3_woken;
      assign e3_woken     = enq_fp_slow(enq[w].uop.src3_preg);
      assign enq_wait3[w] = enq[w].uop.src3_en && enq[w].src3_busy && !e3_woken;
    end else begin : g_no_e3
      assign enq_wait3[w] = 1'b0;
    end
  end

  // a slot freed by an issue this cycle can be reused by an enqueue in the same cycle
  isu_alloc_chain #(.NREQ(DW), .NSLOT(SIZE)) u_alloc (
    .clk(clk), .req(enq_valid),
    .free(~slot_valid),   // the allocation starts from the registered valid bits: it does not wait for this cycle's issue
    .slot_onehot(enq_slot));

  always_comb begin
    write_slot = '0;
    for (int w = 0; w < DW; w++) write_slot = write_slot | enq_slot[w];
  end

  isu_iq_store #(.SIZE(SIZE), .DW(DW), .HAS_SRC2(HAS_SRC2), .HAS_SRC3(HAS_SRC3),
                 .SRC1_DOM(SRC1_DOM), .SRC2_DOM(SRC2_DOM), .FP_TAGS(FP_TAGS), .INT_W(INT_W)) u_store (
    .clk(clk), .rst_n(rst_n),
    .enq_slot(enq_slot), .enq_uop(enq_uop), .enq_wait1(enq_wait1), .enq_wait2(enq_wait2), .enq_wait3(enq_wait3),
    .enq_byp1(enq_byp1), .enq_byp2(enq_byp2),
    .woken_slow_int(woken_slow_int), .woken_slow_fp(woken_slow_fp),
    .slow_exu_valid(slow_exu_valid), .slow_exu_preg(slow_exu_preg),
    .fast_valid(fast_valid), .fast_preg(fast_preg),
    .cancel_int(cancel_int), .cancel_fp(cancel_fp),
    .issue_clear(granted_slot), .flush_all(flush_all), .flush_br(flush_br), .flush_br_mask(flush_br_mask),
    .clear_mask(clear_mask),
    .slot_valid(slot_valid), .slot_ready(slot_ready), .slot_uop(slot_uop), .slot_op(slot_op),
    .slot_byp1(slot_byp1), .slot_byp2(slot_byp2));

  // ---- occupancy reported to dispatch (Isu::comb_ready) ----
  logic [CW-1:0] used_count;
  ttg_popcount #(.N(SIZE), .CW(CW)) u_count (.bits(slot_valid), .count(used_count));
  assign free_slots = READY_NUM_W'(SIZE) - READY_NUM_W'(used_count);

endmodule

`default_nettype wire
