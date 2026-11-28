// Ref: back-end/Prf.cpp  Prf::comb_awake
`default_nettype none

module prf_awake import ttg_cfg_pkg::*; import ttg_util_pkg::ttg_rob_younger; #(
  parameter int LANES = WB_LANES,
  parameter int WAKE_NUM = LSU_LOAD_WB_WIDTH
) (
  input  logic [LANES-1:0]         wb_wen,
  input  logic [LANES-1:0]         wb_is_load,
  input  logic [PRF_IDX_WIDTH-1:0] wb_dest_preg [LANES],
  input  logic [ROB_IDX_WIDTH-1:0] wb_rob_idx   [LANES],
  input  logic [LANES-1:0]         wb_rob_flag,
  input  logic                     bcast_mispred,
  input  logic [ROB_IDX_WIDTH-1:0] bcast_rob_idx,
  input  logic                     bcast_rob_flag,
  output logic [WAKE_NUM-1:0]      wake_valid,
  output logic [PRF_IDX_WIDTH-1:0] wake_preg    [WAKE_NUM]
);

  localparam int RANKW = $clog2(LANES + 1);

  logic [LANES-1:0] lane_wakes;

  always_comb begin
    for (int i = 0; i < LANES; i++) begin
      lane_wakes[i] = wb_wen[i] && wb_is_load[i] &&
                      !(bcast_mispred && ttg_rob_younger(wb_rob_idx[i], wb_rob_flag[i], bcast_rob_idx, bcast_rob_flag));
    end
  end

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
