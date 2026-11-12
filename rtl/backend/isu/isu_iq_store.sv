// Ref: back-end/include/IssueQueue.h  IssueQueue (entry, enqueue, comb_wakeup, flush_br, clear_br, commit_issue)
`default_nettype none

// Issue-queue storage: per slot a valid bit, the uop and two "still waiting for source" bits.
// Next-state priority per slot: enqueue writes the slot; wake-up clears wait bits of old entries; issue frees the slot;
// then flush kills (global, or by branch mask on the slot's mask before the clear); finally resolved-branch bits clear.
module isu_iq_store
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
#(
  parameter int SIZE = 64,
  parameter int DW   = IQ_DISPATCH_WIDTH
) (
  input  logic                     clk,
  input  logic                     rst_n,
  // enqueue: slot_onehot[w] is the slot written by lane w (zero when lane w is idle)
  input  logic [SIZE-1:0]          enq_slot [DW],
  input  isu_uop_t                 enq_uop  [DW],
  input  logic [DW-1:0]            enq_wait1,
  input  logic [DW-1:0]            enq_wait2,
  input  logic [TAG_NUM-1:0]       woken,
  input  logic [TAG_NUM-1:0]       cancel_v,       // the wake-up of the previous cycle was wrong: entries wait again
  input  logic [SIZE-1:0]          issue_clear,    // slots granted this cycle
  input  logic                     flush_all,
  input  logic                     flush_br,       // misprediction without a global flush
  input  logic [BR_MASK_WIDTH-1:0] flush_br_mask,
  input  logic [BR_MASK_WIDTH-1:0] clear_mask,
  // registered view (what select and the PRF read this cycle)
  output logic [SIZE-1:0]          slot_valid,
  output logic [SIZE-1:0]          slot_ready,
  output isu_uop_t                 slot_uop [SIZE],
  output op_set_t                  slot_op  [SIZE]
);

  localparam int UW = $bits(isu_uop_t);

  logic [UW-1:0] enq_bits [DW];
  for (genvar w = 0; w < DW; w++) begin : g_pack
    assign enq_bits[w] = enq_uop[w];
  end

  for (genvar i = 0; i < SIZE; i++) begin : g_slot
    logic [DW-1:0] hit;                  // enqueue lane that writes this slot
    logic          write;
    logic [UW-1:0] new_bits;
    logic          valid_q, valid_d;
    isu_uop_t      uop_q, uop_d;
    logic          wait1_q, wait1_d, wait2_q, wait2_d;
    logic          wait1_c, wait2_c;     // wait bits with this cycle's cancel (applied before the select)
    logic          killed_by_branch;

    for (genvar w = 0; w < DW; w++) begin : g_hit
      assign hit[w] = enq_slot[w][i];
    end
    assign write = |hit;
    ttg_onehot_mux #(.N(DW), .W(UW)) u_new (.sel(hit), .data(enq_bits), .out(new_bits));

    assign wait1_c = wait1_q || (uop_q.src1_en && cancel_v[uop_q.src1_preg]);
    assign wait2_c = wait2_q || (uop_q.src2_en && cancel_v[uop_q.src2_preg]);

    // Ref: IssueQueue::enqueue / comb_wakeup / commit_issue / flush_br / clear_br / flush_all
    always_comb begin
      uop_d   = write ? isu_uop_t'(new_bits) : uop_q;
      wait1_d = write ? |(hit & enq_wait1) : (wait1_c & ~woken[uop_q.src1_preg]);
      wait2_d = write ? |(hit & enq_wait2) : (wait2_c & ~woken[uop_q.src2_preg]);
      killed_by_branch = flush_br && ((uop_d.br_mask & flush_br_mask) != '0);   // mask before the clear below
      valid_d = ((valid_q && !issue_clear[i]) || write) && !flush_all && !killed_by_branch;
      uop_d.br_mask = uop_d.br_mask & ~clear_mask;
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        valid_q <= 1'b0;
        uop_q   <= '0;
        wait1_q <= 1'b0;
        wait2_q <= 1'b0;
      end else begin
        valid_q <= valid_d;
        uop_q   <= uop_d;
        wait1_q <= wait1_d;
        wait2_q <= wait2_d;
      end
    end

    assign slot_valid[i] = valid_q;
    assign slot_ready[i] = valid_q && !wait1_c && !wait2_c;
    assign slot_uop[i]   = uop_q;
    assign slot_op[i]    = op_onehot(uop_q.op);
  end

endmodule

`default_nettype wire
