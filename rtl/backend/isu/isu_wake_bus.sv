// Ref: back-end/Isu.cpp  Isu::comb_awake (unified broadcast), include/IssueQueue.h  IssueQueue::comb_wakeup
`default_nettype none

// All wake-up channels folded into one bit per physical register. An issue-queue slot is woken by looking up its
// source preg in this map (equivalent to the reference model's preg -> slot-bitmap matrix).
module isu_wake_bus
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
(
  input  logic [WAKE_NUM-1:0]      wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0] wake_preg [WAKE_NUM],
  output logic [PRF_NUM-1:0]       woken
);

  // Ref: IssueQueue::comb_wakeup
  always_comb begin
    for (int r = 0; r < PRF_NUM; r++) begin
      woken[r] = 1'b0;
      for (int k = 0; k < WAKE_NUM; k++) woken[r] = woken[r] | (wake_valid[k] & (wake_preg[k] == PRF_IDX_WIDTH'(r)));
    end
  end

endmodule

`default_nettype wire
