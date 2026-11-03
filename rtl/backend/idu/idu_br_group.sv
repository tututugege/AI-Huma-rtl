// Ref: back-end/Idu.cpp  class Idu::comb_decode (br_num / running_mask / stall loop)
`default_nettype none

// Per-group branch tagging. Lane i's k-th branch (k = number of older branches in the group) takes allocation
// slot k; a branch with no free slot "stalls": it and every younger lane are dropped from the group.
// br_mask of a lane = base mask | tags of all older branches in the group (prefix OR).
module idu_br_group #(
  parameter int DW     = 8,
  parameter int NTAG   = 64,
  parameter int NALLOC = 8,
  parameter int TAGW   = $clog2(NTAG)
) (
  input  logic [DW-1:0]    entry_valid,
  input  logic [DW-1:0]    is_branch,                 // valid BR/JALR per lane
  input  logic [NTAG-1:0]  alloc_oh [NALLOC],         // free-tag slots from idu_br_alloc
  input  logic [NTAG-1:0]  base_mask,                 // now_br_mask & ~clear_mask
  output logic [DW-1:0]    lane_valid,                // entry valid and not dropped by a tag stall
  output logic [TAGW-1:0]  lane_br_id [DW],
  output logic [NTAG-1:0]  lane_br_mask [DW],
  output logic [NTAG-1:0]  lane_tag_oh [DW],          // granted tag (one-hot), zero if not a granted branch
  output logic [NTAG-1:0]  lane_cp_mask [DW]          // br_mask checkpoint for the lane's own tag
);

  localparam int RANKW = $clog2(DW + 1);

  logic [DW-1:0]   stall;
  logic [DW:0]     dropped;                           // dropped[i+1]: a stall occurred in lanes 0..i
  logic [NTAG-1:0] mask_before [DW+1];                // mask_before[i]: base | tags granted to lanes < i

  assign dropped[0]     = 1'b0;
  assign mask_before[0] = base_mask;

  for (genvar i = 0; i < DW; i++) begin : g_lane
    logic [DW-1:0]    older_branches;
    logic [RANKW-1:0] rank;
    logic [NALLOC-1:0] rank_oh;

    // older branches in the group (lanes < i)
    assign older_branches = is_branch & DW'((1 << i) - 1);
    ttg_popcount #(.N(DW), .CW(RANKW)) u_rank (.bits(older_branches), .count(rank));

    for (genvar k = 0; k < NALLOC; k++) begin : g_rank_oh
      assign rank_oh[k] = is_branch[i] & (rank == RANKW'(k));
    end

    ttg_onehot_mux #(.N(NALLOC), .W(NTAG)) u_tag (.sel(rank_oh), .data(alloc_oh), .out(lane_tag_oh[i]));
    ttg_onehot_to_idx #(.N(NTAG)) u_id (.onehot(lane_tag_oh[i]), .idx(lane_br_id[i]));

    assign stall[i]          = is_branch[i] & ~(|lane_tag_oh[i]);
    assign dropped[i+1]      = dropped[i] | stall[i];
    assign lane_valid[i]     = entry_valid[i] & ~dropped[i+1];
    assign mask_before[i+1]  = mask_before[i] | lane_tag_oh[i];
    assign lane_br_mask[i]   = dropped[i+1] ? '0 : mask_before[i];
    assign lane_cp_mask[i]   = mask_before[i+1];
  end

endmodule

`default_nettype wire
