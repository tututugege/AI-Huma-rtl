// Ref: back-end/Isu.cpp  Isu::comb_awake (unified broadcast), include/IssueQueue.h  IssueQueue::comb_wakeup
`default_nettype none

// Wake-up channels folded into one bit per physical register in [BASE, BASE + TAGS).
// Used for the registered slow wake-up sources, split by register domain (Int: 0..PRF_NUM-1, FP: FP_TAG_BASE..).
module isu_wake_bus
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
#(
  parameter int N    = WAKE_NUM,
  parameter int BASE = 0,
  parameter int TAGS = TAG_NUM
) (
  input  logic [N-1:0]             wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0] wake_preg [N],
  output logic [TAGS-1:0]          woken
);

  // Ref: IssueQueue::comb_wakeup
  always_comb begin
    for (int r = 0; r < TAGS; r++) begin
      woken[r] = 1'b0;
      for (int k = 0; k < N; k++)
        woken[r] = woken[r] | (wake_valid[k] & (wake_preg[k] == PRF_IDX_WIDTH'(BASE + r)));
    end
  end

endmodule

`default_nettype wire
