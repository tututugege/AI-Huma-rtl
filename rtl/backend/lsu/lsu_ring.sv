// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (enqueue_*/dequeue_* of the six index queues + their per-cycle valid kills)
`default_nettype none

// One index queue (wait_mmu_ldq, wait_mmu_stq, mmu_done_stq, finish, stlf_queue, wait_dcache_ldq).
// A cycle applies up to six operations in stage order (ring_apply in lsu_pkg: kill_slot, window kill + pop, append,
// flush); view[k] is the queue after the first k operations (view[0] = registers), the stage logic reads the view that
// matches its position in the cycle.  The registers keep the slot index only where an append wrote it
// (the stored index of an invalid slot is never used: every reader masks with valid).
module lsu_ring
  import lsu_pkg::*;
(
  input  logic      clk,
  input  logic      rst_n,
  input  lsu_rop_t  op0, op1, op2, op3, op4, op5,       // operations of the cycle in stage order
  output lsu_ring_t view0, view1, view2, view3, view4, view5, view6
);

  logic [RN-1:0]            valid_q;
  logic [RN-1:0][RIW-1:0]   idx_q;
  logic [RIW-1:0]           head_q;
  logic [RCW-1:0]           count_q;

  assign view0 = '{valid: valid_q, idx: idx_q, head: head_q, count: count_q};

  lsu_rres_t r1, r2, r3, r4, r5, r6;
  assign r1    = ring_apply(view0, op0);
  assign r2    = ring_apply(r1.r, op1);
  assign r3    = ring_apply(r2.r, op2);
  assign r4    = ring_apply(r3.r, op3);
  assign r5    = ring_apply(r4.r, op4);
  assign r6    = ring_apply(r5.r, op5);
  assign view1 = r1.r;
  assign view2 = r2.r;
  assign view3 = r3.r;
  assign view4 = r4.r;
  assign view5 = r5.r;
  assign view6 = r6.r;

  lsu_ring_t      last_r;
  logic [RN-1:0]  last_set;
  assign last_r   = r6.r;
  assign last_set = r1.set | r2.set | r3.set | r4.set | r5.set | r6.set;

  // ---- registers: flags / pointers every cycle, slot index only when appended ----
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_q <= '0;
      head_q  <= '0;
      count_q <= '0;
    end else begin
      valid_q <= last_r.valid;
      head_q  <= last_r.head;
      count_q <= last_r.count;
    end
  end
  for (genvar s = 0; s < RN; s++) begin : g_slot
    always_ff @(posedge clk) begin
      if (last_set[s]) idx_q[s] <= last_r.idx[s];
    end
  end

endmodule

`default_nettype wire
