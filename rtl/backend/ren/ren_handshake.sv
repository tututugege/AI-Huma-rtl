// Ref: back-end/Ren.cpp  class Ren  Ren::comb_alloc (stall chain) and Ren::comb_fire (fire, ren2dec.ready)
`default_nettype none

// In-order stall: once a slot that needs a preg fails to get one, it and every younger slot are blocked.
module ren_handshake
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N = DECODE_WIDTH
) (
  input  logic [N-1:0] inst_valid,
  input  logic [N-1:0] alloc_req,     // inst_valid & dest_en
  input  logic [N-1:0] alloc_valid,
  input  logic         dis_ready,
  input  logic         flush,
  input  logic         mispred,
  output logic [N-1:0] out_valid,     // ren2dis.valid
  output logic [N-1:0] fire,
  output logic         ren2dec_ready
);

  logic [N-1:0] alloc_fail;           // requested but not served
  logic [N-1:0] first_fail;           // oldest failing slot (one-hot)
  logic         fail_any;
  logic [N-1:0] blocked;              // slot is at or after the oldest failing slot

  assign alloc_fail = alloc_req & ~alloc_valid;
  ttg_first_set #(.N(N)) u_first_fail (.req(alloc_fail), .onehot(first_fail), .any(fail_any));

  // all slots from the oldest failing one upward: ~(first_fail - 1) (two's complement), empty if nothing fails
  assign blocked = fail_any ? ~(first_fail - N'(1)) : '0;

  for (genvar i = 0; i < N; i++) begin : g_slot
    assign out_valid[i] = inst_valid[i] & ~blocked[i];
    assign fire[i]      = out_valid[i] & dis_ready;
  end

  assign ren2dec_ready = (&(fire | ~inst_valid)) & ~flush & ~mispred;

endmodule

`default_nettype wire
