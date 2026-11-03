// Ref: back-end/include/IssueQueue.h  IssueQueue::enqueue  (also Isu::comb_calc_latency_next alloc_*_slot)
`default_nettype none

// In-order slot allocation: the k-th asserted request takes the k-th lowest free slot (an idle request takes nothing).
// More requests than free slots cannot happen (the producer is flow-controlled); excess requests get no slot.
module isu_alloc_chain #(
  parameter int NREQ  = 8,
  parameter int NSLOT = 64
) (
  input  logic             clk,           // only used by the overflow assertion
  input  logic [NREQ-1:0]  req,
  input  logic [NSLOT-1:0] free,
  output logic [NSLOT-1:0] slot_onehot [NREQ]   // slot taken by each request (all zero when it gets none)
);

  logic [NSLOT-1:0] avail [NREQ + 1];            // slots still free before request r
  assign avail[0] = free;

  for (genvar r = 0; r < NREQ; r++) begin : g_req
    logic [NSLOT-1:0] first_free;
    logic             has_free;
    ttg_first_set #(.N(NSLOT)) u_first (.req(avail[r]), .onehot(first_free), .any(has_free));
    assign slot_onehot[r] = first_free & {NSLOT{req[r]}};
    assign avail[r + 1]   = avail[r] & ~slot_onehot[r];
`ifndef SYNTHESIS
    // C++ asserts on queue overflow / delayed wake-up slot shortage: unreachable when the producer obeys the free count
    assert property (@(posedge clk) !req[r] || has_free);
`endif
  end

endmodule

`default_nettype wire
