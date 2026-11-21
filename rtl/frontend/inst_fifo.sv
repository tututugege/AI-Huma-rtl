// Ref: front-end/fifo/instruction_FIFO.cpp  instruction_FIFO_comb + model
`default_nettype none

// instruction_FIFO: queue of predecoded fetch groups (fused A+B + optional intact Block A fallback).
module inst_fifo import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             refetch,
  input  logic             rd_en,
  input  logic             wr_en,
  input  inst_fifo_entry_t wr_entry,
  output logic             rd_valid,
  output inst_fifo_entry_t rd_entry,
  output logic             full,
  output logic             empty
);

  /* verilator lint_off UNUSEDSIGNAL */
  logic [$clog2(INST_FIFO_DEPTH + 1)-1:0] size_unused;
  logic head_fresh_unused;
  /* verilator lint_on UNUSEDSIGNAL */

  front_fifo #(.DEPTH(INST_FIFO_DEPTH), .W($bits(inst_fifo_entry_t)), .FULL_AT(INST_FIFO_FULL_AT)) u_fifo (
    .clk, .rst_n,
    .clear   (refetch),
    .rd_en, .wr_en, .drop_tail(1'b0),
    .wdata   (wr_entry),
    .rd_valid,
    .rdata   (rd_entry),
    .full, .empty, .size(size_unused), .head_fresh(head_fresh_unused)
  );

endmodule

`default_nettype wire
