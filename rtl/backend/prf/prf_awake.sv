// Ref: back-end/Prf.cpp  Prf::comb_awake
`default_nettype none

// Load wake-up broadcast: every surviving load in the write-back stage announces its destination register.
// The announcements are packed in lane order into WAKE_NUM slots (the issue queues index them by slot).
// More than WAKE_NUM loads in one cycle cannot happen (one load per LSU write-back port), so nothing is dropped.
module prf_awake import ttg_cfg_pkg::*; #(
  parameter int LANES    = ISSUE_WIDTH,
  parameter int WAKE_NUM = LSU_LOAD_WB_WIDTH
) (
  input  logic [LANES-1:0]         wb_wen,
  input  logic [LANES-1:0]         wb_is_load,
  input  logic [PRF_IDX_WIDTH-1:0] wb_dest_preg [LANES],
  input  logic [BR_MASK_WIDTH-1:0] wb_br_mask   [LANES],
  input  logic                     bcast_mispred,
  input  logic [BR_MASK_WIDTH-1:0] bcast_br_mask,
  output logic [WAKE_NUM-1:0]      wake_valid,
  output logic [PRF_IDX_WIDTH-1:0] wake_preg    [WAKE_NUM]
);

  localparam int RANKW = $clog2(LANES + 1);

  logic [LANES-1:0] lane_wakes;   // load result visible and not squashed by this cycle's misprediction

  always_comb begin
    for (int i = 0; i < LANES; i++) begin
      lane_wakes[i] = wb_wen[i] && wb_is_load[i] &&
                      !(bcast_mispred && ((wb_br_mask[i] & bcast_br_mask) != '0));
    end
  end

  // lane i goes to slot (number of waking lanes before it)
  for (genvar k = 0; k < WAKE_NUM; k++) begin : g_slot
    logic [LANES-1:0] slot_sel;
    for (genvar i = 0; i < LANES; i++) begin : g_lane
      logic [RANKW-1:0] rank;
      ttg_popcount #(.N(LANES)) u_rank (.bits(lane_wakes & LANES'((1 << i) - 1)), .count(rank));
      assign slot_sel[i] = lane_wakes[i] && (rank == RANKW'(k));
    end
    assign wake_valid[k] = |slot_sel;
    ttg_onehot_mux #(.N(LANES), .W(PRF_IDX_WIDTH)) u_preg (.sel(slot_sel), .data(wb_dest_preg), .out(wake_preg[k]));
  end

endmodule

`default_nettype wire
