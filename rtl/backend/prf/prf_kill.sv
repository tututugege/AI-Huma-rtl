// Ref: back-end/Prf.cpp  is_killed()  (reference model commit 2f31e8d)
`default_nettype none

// Per-lane squash test: a uop dies when a misprediction is broadcast and the uop depends on the mispredicted branch.
module prf_kill import ttg_cfg_pkg::*; #(
  parameter int LANES = ISSUE_WIDTH
) (
  input  logic [BR_MASK_WIDTH-1:0] lane_br_mask [LANES],
  input  logic                     bcast_mispred,
  input  logic [BR_MASK_WIDTH-1:0] bcast_br_mask,
  output logic [LANES-1:0]         lane_killed
);

  // Ref: is_killed
  always_comb begin
    for (int i = 0; i < LANES; i++) begin
      lane_killed[i] = bcast_mispred && ((lane_br_mask[i] & bcast_br_mask) != '0);
    end
  end

endmodule

`default_nettype wire
