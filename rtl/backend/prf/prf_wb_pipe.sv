// Ref: back-end/Prf.cpp  class Prf  inst_r[] / comb_pipeline / seq
`default_nettype none

// Write-back stage registers (one per issue lane): results arriving from the execution units are held for one cycle,
// then written into the register file and forwarded to the operand read ports.
module prf_wb_pipe import ttg_cfg_pkg::*; #(
  // UopType encoding width = ceil(log2(MAX_UOP_TYPE=18)) (base_types.h); not exported by ttg_cfg_pkg
  parameter int UOP_TYPE_WIDTH = 5,
  parameter int LANES = ISSUE_WIDTH
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     flush,
  input  logic                     bcast_mispred,
  input  logic [BR_MASK_WIDTH-1:0] bcast_br_mask,
  input  logic [BR_MASK_WIDTH-1:0] bcast_clear_mask,
  input  logic                     exe_valid    [LANES],
  input  logic [PRF_IDX_WIDTH-1:0] exe_dest_preg [LANES],
  input  logic [31:0]              exe_result   [LANES],
  input  logic [BR_MASK_WIDTH-1:0] exe_br_mask  [LANES],
  input  logic                     exe_dest_en  [LANES],
  input  logic [UOP_TYPE_WIDTH-1:0] exe_op      [LANES],
  output logic [LANES-1:0]         wb_valid_q,
  output logic [PRF_IDX_WIDTH-1:0] wb_dest_preg_q [LANES],
  output logic [31:0]              wb_result_q  [LANES],
  output logic [BR_MASK_WIDTH-1:0] wb_br_mask_q [LANES],
  output logic [LANES-1:0]         wb_dest_en_q,
  output logic [UOP_TYPE_WIDTH-1:0] wb_op_q     [LANES]
);

  logic [LANES-1:0]         wb_valid_d;
  logic [PRF_IDX_WIDTH-1:0] wb_dest_preg_d [LANES];
  logic [31:0]              wb_result_d    [LANES];
  logic [BR_MASK_WIDTH-1:0] wb_br_mask_d   [LANES];
  logic [LANES-1:0]         wb_dest_en_d;
  logic [UOP_TYPE_WIDTH-1:0] wb_op_d       [LANES];

  logic [LANES-1:0]         exe_killed;
  logic [LANES-1:0]         exe_valid_vec;

  prf_kill #(.LANES(LANES)) u_kill_incoming (
    .lane_br_mask  (exe_br_mask),
    .bcast_mispred (bcast_mispred),
    .bcast_br_mask (bcast_br_mask),
    .lane_killed   (exe_killed)
  );

  // Ref: Prf::comb_pipeline -- payload loads whenever the execution unit presents a valid result
  always_comb begin
    for (int i = 0; i < LANES; i++) begin
      exe_valid_vec[i] = exe_valid[i];
      wb_dest_preg_d[i] = exe_valid[i] ? exe_dest_preg[i] : wb_dest_preg_q[i];
      wb_result_d[i]    = exe_valid[i] ? exe_result[i]    : wb_result_q[i];
      wb_dest_en_d[i]   = exe_valid[i] ? exe_dest_en[i]   : wb_dest_en_q[i];
      wb_op_d[i]        = exe_valid[i] ? exe_op[i]        : wb_op_q[i];
      // surviving uops drop the resolved-branch bits (clear_mask); killed uops are invalidated anyway
      wb_br_mask_d[i]   = exe_valid[i] ? (exe_br_mask[i] & ~bcast_clear_mask) : wb_br_mask_q[i];
    end
  end

  // Ref: Prf::comb_pipeline -- flush has priority, then squash by mispredicted branch
  always_comb begin
    wb_valid_d = exe_valid_vec & ~exe_killed & {LANES{~flush}};
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wb_valid_q <= '0;
      for (int i = 0; i < LANES; i++) begin
        wb_dest_preg_q[i] <= '0;
        wb_result_q[i]    <= '0;
        wb_br_mask_q[i]   <= '0;
        wb_op_q[i]        <= '0;
      end
      wb_dest_en_q <= '0;
    end else begin
      wb_valid_q <= wb_valid_d;
      for (int i = 0; i < LANES; i++) begin
        wb_dest_preg_q[i] <= wb_dest_preg_d[i];
        wb_result_q[i]    <= wb_result_d[i];
        wb_br_mask_q[i]   <= wb_br_mask_d[i];
        wb_op_q[i]        <= wb_op_d[i];
      end
      wb_dest_en_q <= wb_dest_en_d;
    end
  end

endmodule

`default_nettype wire
