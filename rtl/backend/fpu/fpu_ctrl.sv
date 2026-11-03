// Ref: back-end/Exu/include/AbstractFU.h  class IterativeFU (comb_begin / comb_ctrl / comb_issue / comb_consume / seq)
`default_nettype none

// Handshake and timing of the single-entry iterative functional unit: one uop is held from accept until it is consumed.
//   comb_ctrl   : flush kills the held uop when flush_mask is all ones or overlaps its br_mask; clear_mask removes bits
//   comb_issue  : accept a new uop when en and the unit is free *after* the kill (the offered uop is stored as is)
//   complete    : the countdown reached 0 and the uop survived this cycle's flush
//   comb_consume: consume of a completed uop frees the unit; ready = unit free after consume
// The reference compares `done_cycle <= sim_time`; here a down counter loaded with latency-1 at accept does the same.
module fpu_ctrl
  import ttg_cfg_pkg::*;
  import fpu_pkg::*;
(
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     en,
  input  logic                     consume,
  input  logic                     flush,
  input  logic [BR_MASK_WIDTH-1:0] flush_mask,
  input  logic [BR_MASK_WIDTH-1:0] clear_mask,
  input  logic [BR_MASK_WIDTH-1:0] in_br_mask,
  input  logic [LAT_W-1:0]         latency_minus_1,
  output logic                     accept,
  output logic                     complete,
  output logic                     ready,
  output logic [BR_MASK_WIDTH-1:0] held_br_mask   // br_mask of the held uop after this cycle's clear_mask
);

  logic                     busy_q, busy_d;
  logic [LAT_W-1:0]         remaining_q, remaining_d;   // cycles still to wait; 0 = result available
  logic [BR_MASK_WIDTH-1:0] br_mask_q, br_mask_d;

  logic killed, alive;

  // Ref: IterativeFU::comb_ctrl
  assign killed = busy_q & flush & ((flush_mask == {BR_MASK_WIDTH{1'b1}}) | (|(br_mask_q & flush_mask)));
  assign alive  = busy_q & ~killed;

  // Ref: IterativeFU::comb_issue
  assign accept        = en & ~alive;
  assign complete      = alive & (remaining_q == '0);
  assign held_br_mask  = br_mask_q & ~clear_mask;

  // Ref: IterativeFU::comb_consume
  always_comb begin
    busy_d      = alive & ~(consume & complete);
    remaining_d = (remaining_q == '0) ? remaining_q : remaining_q - LAT_W'(1);
    br_mask_d   = held_br_mask;
    if (accept) begin
      busy_d      = 1'b1;
      remaining_d = latency_minus_1;
      br_mask_d   = in_br_mask;
    end
  end

  assign ready = ~busy_d;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      busy_q      <= 1'b0;
      remaining_q <= '0;
      br_mask_q   <= '0;
    end else begin
      busy_q      <= busy_d;
      remaining_q <= remaining_d;
      br_mask_q   <= br_mask_d;
    end
  end

endmodule

`default_nettype wire
