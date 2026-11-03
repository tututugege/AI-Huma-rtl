// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (WaitDcacheLDQEntry: req_gen, replay_wait_cycles; nxt.req_gen)
`default_nettype none

// Per-slot state of the wait_dcache queue (not per LDQ entry: it stays with the slot when the slot is reused) and the
// request generation counter.
//   wait : D response sets (4 / 0) -> D wake-up clears -> M counts down;     gen : M writes the request generation
module lsu_wd_slot
  import lsu_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,
  input  logic [RN-1:0]     set,
  input  logic [RWW-1:0]    set_val   [RN],
  input  logic [RN-1:0]     clr,
  input  logic [RN-1:0]     dec,
  input  logic [RN-1:0]     gen_we,
  input  logic [GENW-1:0]   gen_wd    [RN],
  input  logic [RCW-1:0]    n_iss,                // DCache load requests issued this cycle
  output logic [RWW-1:0]    wait_q    [RN],
  output logic [RWW-1:0]    wait_wk   [RN],       // wait after response and wake-up (what M sees)
  output logic [GENW-1:0]   gen_q     [RN],
  output logic [GENW-1:0]   req_gen_q
);

  for (genvar s = 0; s < RN; s++) begin : g_slot
    logic [RWW-1:0] w_set;
    assign w_set      = set[s] ? set_val[s] : wait_q[s];
    assign wait_wk[s] = clr[s] ? '0 : w_set;
    always_ff @(posedge clk) begin
      if (!rst_n)                      wait_q[s] <= '0;
      else if (set[s] || clr[s] || dec[s]) wait_q[s] <= dec[s] ? wait_wk[s] - RWW'(1) : wait_wk[s];
      if (gen_we[s]) gen_q[s] <= gen_wd[s];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) req_gen_q <= '0;
    else        req_gen_q <= req_gen_q + GENW'(n_iss);
  end

endmodule

`default_nettype wire
