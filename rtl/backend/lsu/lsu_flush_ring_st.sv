// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_flush: STQ-index queues after a rob flush / branch mispredict)
`default_nettype none

// A rob flush empties the queue; a mispredict invalidates entries outside the truncated STQ window [head, head+count).
module lsu_flush_ring_st
  import lsu_pkg::*;
(
  input  logic             flush,
  input  logic             mispred,
  input  lsu_ring_t        ring_i,
  input  logic [RIW-1:0]   stq_head,
  input  logic [RCW-1:0]   stq_count,
  output lsu_ring_t        ring_o
);

  logic [RN-1:0] dead;
  for (genvar s = 0; s < RN; s++) begin : g_slot
    assign dead[s] = !stq_alive(ring_i.idx[s], stq_head, stq_count);
  end

  always_comb begin
    ring_o       = ring_i;
    ring_o.valid = flush ? '0 : (mispred ? ring_i.valid & ~dead : ring_i.valid);
    ring_o.count = flush ? '0 : ring_i.count;
  end

endmodule

`default_nettype wire
