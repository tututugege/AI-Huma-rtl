// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (entry.valid = false for processed entries; dequeue_*(): pop leading invalid)
`default_nettype none

// keep_w[p] = 0 invalidates the entry at window position p (positions outside min(count, WIN) are never touched);
// afterwards leading invalid entries of the window are popped (head moves, count drops).
module lsu_ring_kill_pop
  import lsu_pkg::*;
(
  input  lsu_ring_t      ring_i,
  input  logic [WIN-1:0] keep_w,
  output lsu_ring_t      ring_o
);

  logic [WIN-1:0]  in_win, valid_after;
  logic [RN-1:0]   kill_pos, kill_slot;
  logic [WIN-1:0]  first_live;
  /* verilator lint_off UNUSEDSIGNAL */  // first_set "any" not needed: n_pop defaults to the window size
  logic            any_live;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [RCW-1:0]  n_pop, win_count;

  for (genvar p = 0; p < WIN; p++) begin : g_pos
    assign in_win[p]      = ring_i.count > RCW'(p);
    assign valid_after[p] = in_win[p] && ring_i.valid[ring_i.head + RIW'(p)] && keep_w[p];
    assign kill_pos[p]    = in_win[p] && !keep_w[p];
  end
  if (RN > WIN) begin : g_pad
    assign kill_pos[RN-1:WIN] = '0;
  end
  assign kill_slot = rotl_rn(kill_pos, ring_i.head);

  ttg_first_set #(.N(WIN)) u_first (.req(valid_after), .onehot(first_live), .any(any_live));

  always_comb begin
    win_count = ring_i.count > RCW'(WIN) ? RCW'(WIN) : ring_i.count;
    n_pop     = win_count;                       // no live entry in the window: everything in the window leaves
    for (int p = 0; p < WIN; p++) if (first_live[p]) n_pop = RCW'(p);
  end

  always_comb begin
    ring_o       = ring_i;
    ring_o.valid = ring_i.valid & ~kill_slot;
    ring_o.head  = ring_i.head + RIW'(n_pop);
    ring_o.count = ring_i.count - n_pop;
  end

endmodule

`default_nettype wire
