// Ref: back-end/Isu.cpp  comb_issue (grant_gate) and WbBusy (EXP-035)
`default_nettype none

// Completion-cycle reservation of the issue ports. A port completes one uop per cycle (one ROB / write-back
// entry), and the cycle in which a granted uop completes is known at issue (issue cycle + offset), so a grant
// reserves (port, cycle) in a ring of busy bits indexed by the cycle number (like XiangShan's WbFuBusyTable).
// A pick that finds its cycle taken is refused and stays in its queue. A port grants at most one uop per cycle,
// so the picks of different ports never share a reservation and each port's check depends on the table only.
module isu_wb_gate
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  flush_all,        // every reservation is cleared on a global flush
  input  logic [WB_OFF_W-1:0]   off [ISSUE_WIDTH],  // completion offset of the port's pick (cycles, >= 1)
  input  logic [ISSUE_WIDTH-1:0] reserve,         // the port's pick is granted (after every gate)
  output logic [ISSUE_WIDTH-1:0] port_ok          // the pick's completion cycle is free
);

  localparam int RB = WB_OFF_W;
  localparam int RING = 1 << RB;

  logic [RB-1:0] now_q;
  logic [RING-1:0] busy_q [ISSUE_WIDTH];

  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_port
    logic [RB-1:0] slot;
    assign slot = now_q + off[p];
    assign port_ok[p] = !busy_q[p][slot];
    for (genvar s = 0; s < RING; s++) begin : g_slot
      always_ff @(posedge clk) begin
        if (!rst_n || flush_all)  busy_q[p][s] <= 1'b0;
        else if (now_q == RB'(s)) busy_q[p][s] <= 1'b0;   // the slot of the current cycle is consumed at its end
        else if (reserve[p] && slot == RB'(s)) busy_q[p][s] <= 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) now_q <= '0;
    else        now_q <= now_q + RB'(1);
  end

endmodule

`default_nettype wire
