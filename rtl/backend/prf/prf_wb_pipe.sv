// Ref: back-end/Prf.cpp  class Prf  inst_r[] / comb_pipeline / seq
`default_nettype none

// Write-back stage registers, one per issue lane. A result arriving from an execution unit is held for one cycle
// (then written into the register file and forwarded to the operand read ports), unless a flush or a misprediction
// of a branch it depends on kills it. Only results that actually write a register are kept (wen).
module prf_wb_pipe import ttg_cfg_pkg::*; #(
  parameter int LANES = ISSUE_WIDTH
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     flush,
  input  logic                     bcast_mispred,
  input  logic [BR_MASK_WIDTH-1:0] bcast_br_mask,
  input  logic [BR_MASK_WIDTH-1:0] bcast_clear_mask,
  input  logic [LANES-1:0]         exe_valid,
  input  logic [LANES-1:0]         exe_dest_en,
  input  logic [LANES-1:0]         exe_is_load,
  input  logic [PRF_IDX_WIDTH-1:0] exe_dest_preg [LANES],
  input  logic [31:0]              exe_result    [LANES],
  input  logic [BR_MASK_WIDTH-1:0] exe_br_mask   [LANES],
  output logic [LANES-1:0]         wb_wen_q,        // result of this lane writes a register this cycle
  output logic [LANES-1:0]         wb_is_load_q,
  output logic [PRF_IDX_WIDTH-1:0] wb_dest_preg_q [LANES],
  output logic [31:0]              wb_result_q    [LANES],
  output logic [BR_MASK_WIDTH-1:0] wb_br_mask_q   [LANES]
);

  logic [LANES-1:0]         wb_wen_d;
  logic [BR_MASK_WIDTH-1:0] wb_br_mask_d [LANES];

  // Ref: Prf::comb_pipeline -- flush kills everything; a mispredicted branch kills its dependants;
  // survivors drop the bits of branches that resolved this cycle. The payload is just the execution unit's output.
  always_comb begin
    for (int i = 0; i < LANES; i++) begin
      wb_wen_d[i] = !flush && exe_valid[i] && exe_dest_en[i] &&
                    !(bcast_mispred && ((exe_br_mask[i] & bcast_br_mask) != '0));
      wb_br_mask_d[i] = exe_br_mask[i] & ~bcast_clear_mask;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wb_wen_q     <= '0;
      wb_is_load_q <= '0;
      for (int i = 0; i < LANES; i++) begin
        wb_dest_preg_q[i] <= '0;
        wb_result_q[i]    <= '0;
        wb_br_mask_q[i]   <= '0;
      end
    end else begin
      wb_wen_q     <= wb_wen_d;
      wb_is_load_q <= exe_is_load;
      for (int i = 0; i < LANES; i++) begin
        wb_dest_preg_q[i] <= exe_dest_preg[i];
        wb_result_q[i]    <= exe_result[i];
        wb_br_mask_q[i]   <= wb_br_mask_d[i];
      end
    end
  end

endmodule

`default_nettype wire
