// Ref: back-end/Isu.cpp  Isu::comb_awake  (FP slots fire on the FPW_CH channels "in slot order")
`default_nettype none

// Packs the asserted slots of a wide wake-up vector onto M channels, in slot order: channel c carries the c-th asserted
// slot. More than M asserted slots cannot happen (the reference asserts it); the excess is dropped.
module isu_wake_compact
  import ttg_cfg_pkg::*;
#(
  parameter int N = 24,
  parameter int M = 8
) (
  /* verilator lint_off UNUSEDSIGNAL */  // waiver: clk only clocks the overflow assertion (unread under -DSYNTHESIS)
  input  logic                     clk,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [N-1:0]             in_valid,
  input  logic [PRF_IDX_WIDTH-1:0] in_preg [N],
  output logic [M-1:0]             out_valid,
  output logic [PRF_IDX_WIDTH-1:0] out_preg [M]
);

  logic [N-1:0] pick [M];                        // pick[c]: one-hot slot that lands on channel c

  ttg_pick_k #(.N(N), .K(M)) u_pick (.req(in_valid), .pick_oh(pick), .valid(out_valid));

  for (genvar c = 0; c < M; c++) begin : g_chan
    ttg_onehot_mux #(.N(N), .W(PRF_IDX_WIDTH)) u_mux (.sel(pick[c]), .data(in_preg), .out(out_preg[c]));
  end

`ifndef SYNTHESIS
  localparam int RW = $clog2(N + 1);
  logic [RW-1:0] total;
  ttg_popcount #(.N(N)) u_total (.bits(in_valid), .count(total));
  assert property (@(posedge clk) total <= RW'(M));
`endif

endmodule

`default_nettype wire
