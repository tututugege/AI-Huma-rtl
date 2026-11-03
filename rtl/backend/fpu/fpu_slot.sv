// Ref: back-end/Exu/include/AbstractFU.h  class IterativeFU (current_inst: the uop held while the FU is busy)
`default_nettype none

// Operand and routing registers of the uop in flight. Loaded on accept; the FU result is computed from them
// (fpu_compute) and only observed after the latency, so this is a multi-cycle path, not a pipeline.
module fpu_slot
  import ttg_cfg_pkg::*;
  import fpu_pkg::*;
(
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     accept,
  input  logic [NKIND-1:0]         kind_in,
  input  logic [2:0]               func3_in,
  input  logic [31:0]              src1_in,
  input  logic [31:0]              src2_in,
  input  logic [PRF_IDX_WIDTH-1:0] dest_preg_in,
  input  logic                     dest_en_in,
  input  logic [ROB_IDX_WIDTH-1:0] rob_idx_in,
  output logic [NKIND-1:0]         kind,
  output logic [2:0]               func3,
  output logic [31:0]              src1,
  output logic [31:0]              src2,
  output logic [PRF_IDX_WIDTH-1:0] dest_preg,
  output logic                     dest_en,
  output logic [ROB_IDX_WIDTH-1:0] rob_idx
);

  logic [NKIND-1:0]         kind_q, kind_d;
  logic [2:0]               func3_q, func3_d;
  logic [31:0]              src1_q, src1_d, src2_q, src2_d;
  logic [PRF_IDX_WIDTH-1:0] dest_preg_q, dest_preg_d;
  logic                     dest_en_q, dest_en_d;
  logic [ROB_IDX_WIDTH-1:0] rob_idx_q, rob_idx_d;

  always_comb begin
    kind_d      = accept ? kind_in : kind_q;
    func3_d     = accept ? func3_in : func3_q;
    src1_d      = accept ? src1_in : src1_q;
    src2_d      = accept ? src2_in : src2_q;
    dest_preg_d = accept ? dest_preg_in : dest_preg_q;
    dest_en_d   = accept ? dest_en_in : dest_en_q;
    rob_idx_d   = accept ? rob_idx_in : rob_idx_q;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      kind_q      <= '0;
      func3_q     <= '0;
      src1_q      <= '0;
      src2_q      <= '0;
      dest_preg_q <= '0;
      dest_en_q   <= 1'b0;
      rob_idx_q   <= '0;
    end else begin
      kind_q      <= kind_d;
      func3_q     <= func3_d;
      src1_q      <= src1_d;
      src2_q      <= src2_d;
      dest_preg_q <= dest_preg_d;
      dest_en_q   <= dest_en_d;
      rob_idx_q   <= rob_idx_d;
    end
  end

  assign kind      = kind_q;
  assign func3     = func3_q;
  assign src1      = src1_q;
  assign src2      = src2_q;
  assign dest_preg = dest_preg_q;
  assign dest_en   = dest_en_q;
  assign rob_idx   = rob_idx_q;

endmodule

`default_nettype wire
