// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_flush: LDQ-index queues after a rob flush / branch mispredict)
`default_nettype none

// Last operation of an LDQ-index queue in a cycle: a rob flush empties it (head stays, count = 0); a mispredict
// invalidates the entries whose LDQ entry is now Empty.
module lsu_flush_ring_ld
  import lsu_pkg::*;
(
  input  logic             flush,
  input  logic             mispred,
  input  logic [RN-1:0][RIW-1:0] ring_idx,       // slot indices before this operation
  input  logic [LQ-1:0]    ld_empty,              // LDQ entry Empty after the flush / mispredict step
  output lsu_rop_t         op
);
  logic [RN-1:0] dead;
  for (genvar s = 0; s < RN; s++) begin : g_slot
    assign dead[s] = ld_empty[ring_idx[s]];
  end
  always_comb begin
    op           = ROP_NOP;
    op.flush     = flush;
    op.kill_slot = mispred ? dead : '0;
  end
endmodule

`default_nettype wire
