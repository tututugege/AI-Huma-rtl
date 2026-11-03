// Ref: back-end/Prf.cpp  Prf::comb_read (operand part)
`default_nettype none

// Two operand read ports per issue lane, each with its own bypass network.
module prf_read_ports import ttg_cfg_pkg::*; #(
  parameter int LANES  = ISSUE_WIDTH,
  parameter int FU_NUM = TOTAL_FU_COUNT
) (
  input  logic                     src_en    [2][LANES],
  input  logic [PRF_IDX_WIDTH-1:0] src_preg  [2][LANES],
  input  logic [31:0]              rf_data   [2][LANES],
  input  logic [LANES-1:0]         wb_valid,
  input  logic [LANES-1:0]         wb_dest_en,
  input  logic [PRF_IDX_WIDTH-1:0] wb_dest_preg [LANES],
  input  logic [31:0]              wb_result    [LANES],
  input  logic [FU_NUM-1:0]        fu_valid,
  input  logic [FU_NUM-1:0]        fu_dest_en,
  input  logic [PRF_IDX_WIDTH-1:0] fu_dest_preg [FU_NUM],
  input  logic [31:0]              fu_result    [FU_NUM],
  output logic [31:0]              rdata     [2][LANES]
);

  for (genvar s = 0; s < 2; s++) begin : g_src
    for (genvar i = 0; i < LANES; i++) begin : g_lane
      prf_bypass #(.WB_LANES(LANES), .FU_NUM(FU_NUM)) u_bypass (
        .src_en       (src_en[s][i]),
        .src_preg     (src_preg[s][i]),
        .rf_data      (rf_data[s][i]),
        .wb_valid     (wb_valid),
        .wb_dest_en   (wb_dest_en),
        .wb_dest_preg (wb_dest_preg),
        .wb_result    (wb_result),
        .fu_valid     (fu_valid),
        .fu_dest_en   (fu_dest_en),
        .fu_dest_preg (fu_dest_preg),
        .fu_result    (fu_result),
        .rdata        (rdata[s][i])
      );
    end
  end

endmodule

`default_nettype wire
