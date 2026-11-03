// Ref: back-end/Idu.cpp  class Idu::comb_fire (fire[] and the per-slot tag commit)
`default_nettype none

// Handshake with rename: a lane fires when rename is ready, unless the group is cancelled by a ROB flush or by the
// latched branch misprediction (flush / mispred paths of comb_fire return before any fire). Granted branch tags are
// committed (allocated) only for firing lanes.
module idu_fire_ctl #(
  parameter int DW   = 8,
  parameter int NTAG = 64
) (
  input  logic [DW-1:0]   lane_valid,
  input  logic            ren_ready,
  input  logic            rob_flush,
  input  logic            latch_mispred,
  input  logic [NTAG-1:0] lane_tag_oh [DW],
  output logic [DW-1:0]   consume_fire,
  output logic [NTAG-1:0] lane_commit_oh [DW],      // granted tag of a firing lane, else zero
  output logic [NTAG-1:0] commit_all_oh             // union of the committed tags
);

  logic group_go;
  logic [NTAG-1:0] commit_acc [DW+1];

  assign group_go      = ren_ready & ~rob_flush & ~latch_mispred;
  assign consume_fire  = lane_valid & {DW{group_go}};
  assign commit_acc[0] = '0;

  for (genvar i = 0; i < DW; i++) begin : g_lane
    assign lane_commit_oh[i] = lane_tag_oh[i] & {NTAG{consume_fire[i]}};
    assign commit_acc[i+1]   = commit_acc[i] | lane_commit_oh[i];
  end

  assign commit_all_oh = commit_acc[DW];

endmodule

`default_nettype wire
