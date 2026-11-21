// Ref: back-end/include/IssueQueue.h  IssueQueue::enqueue  (also Isu::comb_calc_latency_next alloc_*_slot)
`default_nettype none

// In-order slot allocation: the k-th asserted request takes the k-th lowest free slot (an idle request takes nothing).
// More requests than free slots cannot happen (the producer is flow-controlled); excess requests get no slot.
// Parallel form: every slot computes its rank among the free slots (a log-depth saturating prefix count) and every request
// its rank among the asserted requests; slot s goes to the request whose rank equals the slot's. (The former chain took the
// lowest remaining free slot request by request: NREQ find-firsts one after the other.)
module isu_alloc_chain #(
  parameter int NREQ  = 8,
  parameter int NSLOT = 64
) (
  input  logic             clk,           // only used by the overflow assertion
  input  logic [NREQ-1:0]  req,
  input  logic [NSLOT-1:0] free,
  output logic [NSLOT-1:0] slot_onehot [NREQ]   // slot taken by each request (all zero when it gets none)
);

  // Match the m-th asserted request to the m-th lowest free slot via two parallel ttg_pick_k trees.
  logic [NSLOT-1:0] free_oh [NREQ];
  logic [NREQ-1:0]  req_oh  [NREQ];
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: total free/req counts are checked by the producer and assertion below
  logic [NREQ-1:0]  free_valid, req_valid;
  /* verilator lint_on UNUSEDSIGNAL */

  ttg_pick_k #(.N(NSLOT), .K(NREQ)) u_free (.req(free), .pick_oh(free_oh), .valid(free_valid));
  ttg_pick_k #(.N(NREQ),  .K(NREQ)) u_req  (.req(req),  .pick_oh(req_oh),  .valid(req_valid));

  for (genvar r = 0; r < NREQ; r++) begin : g_req
    for (genvar i = 0; i < NSLOT; i++) begin : g_slot
      logic [NREQ-1:0] match_m;
      for (genvar m = 0; m < NREQ; m++) begin : g_m
        assign match_m[m] = req_oh[m][r] & free_oh[m][i];
      end
      assign slot_onehot[r][i] = |match_m;
    end
`ifndef SYNTHESIS
    // C++ asserts on queue overflow / delayed wake-up slot shortage: unreachable when the producer obeys the free count
    assert property (@(posedge clk) !req[r] || (|slot_onehot[r]));
`endif
  end

endmodule

`default_nettype wire
