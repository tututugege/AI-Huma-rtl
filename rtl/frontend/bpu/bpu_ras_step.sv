// Ref: front-end/BPU/BPU.h  BPU_TOP::ras_push / ras_pop
`default_nettype none

// One RAS operation on (base, count) of a circular stack.  C++ keeps stack[0..count-1] in a shifting array:
// push with room writes stack[count++]; push on a full stack drops the oldest (everything shifts down) and writes the
// top; pop only decrements count.  Only [0,count) is ever read, so a circular buffer (base pointer) is equivalent:
// element j lives in slot (base + j) mod 32; a push on a full stack overwrites the oldest slot and advances the base.
module bpu_ras_step import bpu_pkg::*; (
  input  logic [RAS_PTR_W-1:0] base,
  input  logic [RAS_CNT_W-1:0] count,
  input  logic                 push,
  input  logic                 pop,
  output logic [RAS_PTR_W-1:0] base_next,
  output logic [RAS_CNT_W-1:0] count_next,
  output logic                 wr_en,
  output logic [RAS_PTR_W-1:0] wr_slot
);

  logic full;

  always_comb begin
    full       = (count == RAS_CNT_W'(RAS_DEPTH));
    wr_en      = push;
    wr_slot    = full ? base : base + count[RAS_PTR_W-1:0];
    base_next  = (push && full) ? base + RAS_PTR_W'(1) : base;
    count_next = count;
    if (push && !full) count_next = count + RAS_CNT_W'(1);
    else if (pop && count != '0) count_next = count - RAS_CNT_W'(1);
  end

endmodule

`default_nettype wire
