// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (queue window: for (i < min(count, WINDOW)) { slot = (head + i) % N })
`default_nettype none

module lsu_ring_win
  import lsu_pkg::*;
(
  input  lsu_ring_t        ring,
  output logic [WIN-1:0]   valid_w,           // position p is inside min(count, WIN) and the slot is valid
  output logic [RIW-1:0]   idx_w  [WIN]       // LDQ/STQ index stored at position p
);

  for (genvar p = 0; p < WIN; p++) begin : g_pos
    assign valid_w[p] = ring.count > RCW'(p) && ring.valid[ring.head + RIW'(p)];
    assign idx_w[p]   = ring.idx[ring.head + RIW'(p)];
  end

endmodule

`default_nettype wire
