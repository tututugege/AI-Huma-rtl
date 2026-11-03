// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_flush: LDQ-index queues after a rob flush / branch mispredict)
`default_nettype none

// A rob flush empties the queue (head stays, count = 0); a mispredict invalidates entries whose LDQ entry is now Empty.
module lsu_flush_ring_ld
  import lsu_pkg::*;
(
  input  logic             flush,
  input  logic             mispred,
  input  lsu_ring_t        ring_i,
  input  logic [LQ-1:0]    ld_empty,
  output lsu_ring_t        ring_o
);

  logic [RN-1:0] dead;
  for (genvar s = 0; s < RN; s++) begin : g_slot
    assign dead[s] = ld_empty[ring_i.idx[s]];
  end

  always_comb begin
    ring_o       = ring_i;
    ring_o.valid = flush ? '0 : (mispred ? ring_i.valid & ~dead : ring_i.valid);
    ring_o.count = flush ? '0 : ring_i.count;
  end

endmodule

`default_nettype wire
