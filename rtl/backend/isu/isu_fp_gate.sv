// Ref: back-end/include/FpStats.h  FpStats::try_reserve; back-end/Isu.cpp  comb_issue (grant_gate)  (EXP-032)
`default_nettype none

// FP register-file write-port limit. The cycle in which an FP unit writes the FP register file is known at issue (issue
// cycle + latency), so a grant reserves one of P write ports in that future cycle (a ring of busy counters indexed by
// the cycle number, like XiangShan's WbFuBusyTable); a grant that finds the cycle full is refused and the uop stays in
// its queue. The candidates are the FP-writing grants in the reference's evaluation order (the INT queue's I2F ports,
// then the FP queue's ports); a refused candidate takes no reservation, so later candidates see only the granted
// earlier ones.
module isu_fp_gate
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
#(
  parameter int NC = 5,                 // candidates: grant ports that can write the FP file (multi-cycle latency)
  parameter int P  = FP_WB_PORTS        // write ports per cycle (0: no limit)
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          flush_all,      // the reference clears every reservation on a global flush
  input  logic [NC-1:0] cand_valid,     // candidate is granted by its queue (before this gate)
  input  logic [NC-1:0] cand_fpw,       // ... and writes the FP register file (dest_en & dest_fp & an FP-unit op)
  input  logic [FP_COUNT_W:0] cand_lat [NC],   // model latency in cycles (>= 2)
  output logic [NC-1:0] gate_ok         // candidate may issue (not an FP write, or a port is free in its cycle)
);

  localparam int RING = 64;
  localparam int RB = $clog2(RING);
  localparam int CNT_W = $clog2(P + 2);

  logic [RB-1:0] now_q;
  logic [CNT_W-1:0] busy_q [RING];

  logic [RB-1:0] slot [NC];
  logic [NC-1:0] granted;               // candidate holds a reservation
  logic [CNT_W-1:0] occ [NC];           // reservations in the candidate's cycle before it

  for (genvar k = 0; k < NC; k++) begin : g_cand
    logic [NC-1:0] same;                // earlier granted candidates that reserve the same cycle
    logic [CNT_W-1:0] n_same;
    for (genvar j = 0; j < NC; j++) begin : g_same
      if (j < k) begin : g_older
        assign same[j] = granted[j] & (slot[j] == slot[k]);
      end else begin : g_none
        assign same[j] = 1'b0;
      end
    end
    ttg_popcount #(.N(NC), .CW(CNT_W)) u_same (.bits(same), .count(n_same));
    assign slot[k]    = now_q + RB'(cand_lat[k]);
    assign occ[k]     = busy_q[slot[k]] + n_same;
    assign gate_ok[k] = !(cand_valid[k] && cand_fpw[k]) || (P == 0) || (occ[k] < CNT_W'(P));
    assign granted[k] = cand_valid[k] && cand_fpw[k] && gate_ok[k];
  end

  // per slot: reservations added this cycle; the slot of the current cycle is consumed at its end
  for (genvar s = 0; s < RING; s++) begin : g_slot
    logic [NC-1:0] hit;
    logic [CNT_W-1:0] n_hit;
    for (genvar k = 0; k < NC; k++) begin : g_hit
      assign hit[k] = granted[k] & (slot[k] == RB'(s));
    end
    ttg_popcount #(.N(NC), .CW(CNT_W)) u_hit (.bits(hit), .count(n_hit));
    always_ff @(posedge clk) begin
      if (!rst_n || flush_all)     busy_q[s] <= '0;
      else if (now_q == RB'(s))    busy_q[s] <= '0;
      else                         busy_q[s] <= busy_q[s] + n_hit;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) now_q <= '0;
    else        now_q <= now_q + RB'(1);
  end

endmodule

`default_nettype wire
