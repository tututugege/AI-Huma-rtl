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

  localparam int SW     = $clog2(NREQ + 1);              // free-slot counts saturate at NREQ (no request has that rank)
  localparam int STAGES = (NSLOT > 1) ? $clog2(NSLOT) : 1;

  function automatic logic [SW-1:0] sat_add(input logic [SW-1:0] a, input logic [SW-1:0] b);
    logic [SW:0] s;
    s = {1'b0, a} + {1'b0, b};
    return (s > (SW+1)'(NREQ)) ? SW'(NREQ) : s[SW-1:0];
  endfunction

  // pre[s][i]: free slots in i .. i-2^s+1 (saturated); pre[STAGES][i] = free slots in 0 .. i
  logic [SW-1:0] pre [STAGES+1][NSLOT];
  logic [SW-1:0] rank_free [NSLOT];     // free slots below slot i
  logic [SW-1:0] rank_req  [NREQ];      // asserted requests below request r

  always_comb begin
    for (int i = 0; i < NSLOT; i++) pre[0][i] = SW'(free[i]);
    for (int s = 0; s < STAGES; s++)
      for (int i = 0; i < NSLOT; i++)
        pre[s+1][i] = (i >= (1 << s)) ? sat_add(pre[s][i], pre[s][i - (1 << s)]) : pre[s][i];
    for (int i = 0; i < NSLOT; i++) rank_free[i] = (i == 0) ? '0 : pre[STAGES][i-1];
    for (int r = 0; r < NREQ; r++) begin
      rank_req[r] = '0;
      for (int q = 0; q < r; q++) rank_req[r] = rank_req[r] + SW'(req[q]);
    end
  end

  for (genvar r = 0; r < NREQ; r++) begin : g_req
    for (genvar i = 0; i < NSLOT; i++) begin : g_slot
      assign slot_onehot[r][i] = req[r] && free[i] && (rank_free[i] == rank_req[r]);
    end
`ifndef SYNTHESIS
    // C++ asserts on queue overflow / delayed wake-up slot shortage: unreachable when the producer obeys the free count
    assert property (@(posedge clk) !req[r] || (|slot_onehot[r]));
`endif
  end

endmodule

`default_nettype wire
