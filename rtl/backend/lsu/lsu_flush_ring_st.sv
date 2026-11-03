// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_flush: STQ-index queues after a rob flush / branch mispredict)
`default_nettype none

// Last operation of an STQ-index queue in a cycle: a rob flush empties it; a mispredict invalidates the entries
// outside the truncated STQ window [head, head + count).
module lsu_flush_ring_st
  import lsu_pkg::*;
(
  input  logic             flush,
  input  logic             mispred,
  input  logic [RN-1:0][RIW-1:0] ring_idx,       // slot indices of the queue before this operation
  input  logic [RIW-1:0]   stq_head,
  input  logic [RCW-1:0]   stq_count,
  output lsu_rop_t         op
);
  logic [RN-1:0] dead;
  for (genvar s = 0; s < RN; s++) begin : g_slot
    assign dead[s] = !stq_alive(ring_idx[s], stq_head, stq_count);
  end
  always_comb begin
    op           = ROP_NOP;
    op.flush     = flush;
    op.kill_slot = mispred ? dead : '0;
  end
endmodule

`default_nettype wire
