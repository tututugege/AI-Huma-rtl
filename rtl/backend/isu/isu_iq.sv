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
  parameter bit AGE_EN    = 1'b0    // the oldest-on-first-port select (isu_iq_select)
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [DW-1:0]            enq_valid,
  input  isu_enq_t                 enq [DW],
  input  logic [TAG_NUM-1:0]       woken,
  input  logic [TAG_NUM-1:0]       cancel_v,        // wake-up of the previous cycle was wrong: waiting again (LP_L2)
  input  op_set_t                  fu_ready [NP],   // per port: op classes the functional unit accepts now
  input  logic [NP-1:0]            gate_ok,         // FP write-port gate (isu_fp_gate); 1 for ports without one
  input  logic                     issue_block,     // rob flush or misprediction this cycle
  input  logic                     flush_all,
  input  logic                     flush_br,
  input  logic [BR_MASK_WIDTH-1:0] flush_br_mask,
  input  logic [BR_MASK_WIDTH-1:0] clear_mask,
  output logic [READY_NUM_W-1:0]   free_slots,      // registered occupancy, as seen by dispatch
  output logic [NP-1:0]            cand_valid,      // port's pick passes FU readiness and issue block (before the gate)
  output logic [NP-1:0]            grant_valid,
  output isu_uop_t                 grant_uop [NP]
);

  localparam int UW = $bits(isu_uop_t);
  localparam int CW = $clog2(SIZE + 1);

  logic [SIZE-1:0] slot_valid, slot_ready;
  isu_uop_t        slot_uop [SIZE];
  op_set_t         slot_op  [SIZE];
  logic [SIZE-1:0] sel_onehot [NP];
  logic [NP-1:0]   sel_valid;
  logic [SIZE-1:0] granted_slot;
  logic [SIZE-1:0] enq_slot [DW];
  logic [SIZE-1:0] write_slot;           // slots written by an enqueue this cycle
  isu_uop_t        enq_uop  [DW];
  logic [DW-1:0]   enq_wait1, enq_wait2, enq_wait3;

  // ---- select and grant (reads registered state only) ----
  logic [SIZE-1:0] older [SIZE];
  if (AGE_EN) begin : g_age
    isu_age_matrix #(.SIZE(SIZE)) u_age (.clk(clk), .write(write_slot), .slot_valid(slot_valid), .older(older));
  end else begin : g_noage
    for (genvar i = 0; i < SIZE; i++) begin : g_z
      assign older[i] = '0;
    end
  end
  isu_iq_select #(.SIZE(SIZE), .NP(NP), .QID(QID), .AGE_EN(AGE_EN)) u_select (
    .ready(slot_ready), .entry_op(slot_op), .older(older), .sel_onehot(sel_onehot), .sel_valid(sel_valid));

  logic [UW-1:0] slot_bits [SIZE];
  for (genvar i = 0; i < SIZE; i++) begin : g_bits
    assign slot_bits[i] = slot_uop[i];
  end

  logic [SIZE-1:0] granted_by_port [NP];
  for (genvar p = 0; p < NP; p++) begin : g_port
    logic [UW-1:0] sel_bits;
    isu_uop_t      sel_uop;
    ttg_onehot_mux #(.N(SIZE), .W(UW)) u_read (.sel(sel_onehot[p]), .data(slot_bits), .out(sel_bits));
    assign sel_uop        = isu_uop_t'(sel_bits);
    assign grant_uop[p]   = sel_uop;
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
  for (genvar w = 0; w < DW; w++) begin : g_enq
    assign enq_uop[w]   = enq[w].uop;
    assign enq_wait1[w] = enq[w].uop.src1_en && enq[w].src1_busy && !woken[enq[w].uop.src1_preg];
    assign enq_wait2[w] = enq[w].uop.src2_en && enq[w].src2_busy && !woken[enq[w].uop.src2_preg];
    assign enq_wait3[w] = enq[w].uop.src3_en && enq[w].src3_busy && !woken[enq[w].uop.src3_preg];
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

  isu_iq_store #(.SIZE(SIZE), .DW(DW)) u_store (
    .clk(clk), .rst_n(rst_n),
    .enq_slot(enq_slot), .enq_uop(enq_uop), .enq_wait1(enq_wait1), .enq_wait2(enq_wait2), .enq_wait3(enq_wait3),
    .woken(woken),
    .cancel_v(cancel_v),
    .issue_clear(granted_slot), .flush_all(flush_all), .flush_br(flush_br), .flush_br_mask(flush_br_mask),
    .clear_mask(clear_mask),
    .slot_valid(slot_valid), .slot_ready(slot_ready), .slot_uop(slot_uop), .slot_op(slot_op));

  // ---- occupancy reported to dispatch (Isu::comb_ready) ----
  logic [CW-1:0] used_count;
  ttg_popcount #(.N(SIZE), .CW(CW)) u_count (.bits(slot_valid), .count(used_count));
  assign free_slots = READY_NUM_W'(SIZE) - READY_NUM_W'(used_count);

endmodule

`default_nettype wire
