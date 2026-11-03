// Ref: back-end/Prf.cpp  Prf::comb_awake
`default_nettype none

// Load wake-up broadcast: every surviving load in the write-back stage that has a destination announces its
// physical register. The announcements are packed in lane order into the first WAKE_NUM slots; extra loads are dropped.
module prf_awake import ttg_cfg_pkg::*; #(
  // UopType encoding width = ceil(log2(MAX_UOP_TYPE=18)) (base_types.h); not exported by ttg_cfg_pkg
  parameter int UOP_TYPE_WIDTH = 5,
  parameter int LANES    = ISSUE_WIDTH,
  parameter int WAKE_NUM = LSU_LOAD_WB_WIDTH
) (
  input  logic [LANES-1:0]          wb_valid,
  input  logic [LANES-1:0]          wb_dest_en,
  input  logic [UOP_TYPE_WIDTH-1:0] wb_op        [LANES],
  input  logic [PRF_IDX_WIDTH-1:0]  wb_dest_preg [LANES],
  input  logic [BR_MASK_WIDTH-1:0]  wb_br_mask   [LANES],
  input  logic                      bcast_mispred,
  input  logic [BR_MASK_WIDTH-1:0]  bcast_br_mask,
  output logic [WAKE_NUM-1:0]       wake_valid,
  output logic [PRF_IDX_WIDTH-1:0]  wake_preg    [WAKE_NUM]
);

  localparam int RANKW = $clog2(LANES + 1);
  localparam logic [UOP_TYPE_WIDTH-1:0] UOP_LOAD_CODE = UOP_TYPE_WIDTH'(3);  // enum UopType: UOP_LOAD

  logic [LANES-1:0] lane_killed;
  logic [LANES-1:0] lane_wakes;      // load result visible and not squashed

  prf_kill #(.LANES(LANES)) u_kill_wb (
    .lane_br_mask  (wb_br_mask),
    .bcast_mispred (bcast_mispred),
    .bcast_br_mask (bcast_br_mask),
    .lane_killed   (lane_killed)
  );

  always_comb begin
    for (int i = 0; i < LANES; i++) begin
      lane_wakes[i] = wb_valid[i] && wb_dest_en[i] && (wb_op[i] == UOP_LOAD_CODE) && !lane_killed[i];
    end
  end

  // rank of each waking lane = number of waking lanes before it (prefix popcount)
  logic [RANKW-1:0] lane_rank [LANES];
  for (genvar i = 0; i < LANES; i++) begin : g_rank
    logic [LANES-1:0] earlier;
    always_comb begin
      for (int j = 0; j < LANES; j++) earlier[j] = lane_wakes[j] && (j < i);
    end
    ttg_popcount #(.N(LANES)) u_rank (.bits(earlier), .count(lane_rank[i]));
  end

  // each wake slot takes the lane whose rank equals the slot number
  for (genvar k = 0; k < WAKE_NUM; k++) begin : g_slot
    logic [LANES-1:0] slot_sel;
    always_comb begin
      for (int i = 0; i < LANES; i++) slot_sel[i] = lane_wakes[i] && (lane_rank[i] == RANKW'(k));
    end
    assign wake_valid[k] = |slot_sel;
    ttg_onehot_mux #(.N(LANES), .W(PRF_IDX_WIDTH)) u_preg (.sel(slot_sel), .data(wb_dest_preg), .out(wake_preg[k]));
  end

endmodule

`default_nettype wire
