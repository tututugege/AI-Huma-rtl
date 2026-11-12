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
  input  logic                     clk,            // only used by the overflow assertion
  input  logic [N-1:0]             in_valid,
  input  logic [PRF_IDX_WIDTH-1:0] in_preg [N],
  output logic [M-1:0]             out_valid,
  output logic [PRF_IDX_WIDTH-1:0] out_preg [M]
);

  localparam int RW = $clog2(N + 1);

  logic [RW-1:0] rank [N];                       // number of asserted slots before slot i
  for (genvar i = 0; i < N; i++) begin : g_rank
    logic [N-1:0] before_mask;
    assign before_mask = in_valid & ~({N{1'b1}} << i);
    ttg_popcount #(.N(N)) u_rank (.bits(before_mask), .count(rank[i]));
  end

  for (genvar c = 0; c < M; c++) begin : g_chan
    logic [N-1:0] pick;                          // the slot that lands on channel c (one-hot or none)
    for (genvar i = 0; i < N; i++) begin : g_pick
      assign pick[i] = in_valid[i] & (rank[i] == RW'(c));
    end
    assign out_valid[c] = |pick;
    ttg_onehot_mux #(.N(N), .W(PRF_IDX_WIDTH)) u_mux (.sel(pick), .data(in_preg), .out(out_preg[c]));
  end

`ifndef SYNTHESIS
  logic [RW-1:0] total;
  ttg_popcount #(.N(N)) u_total (.bits(in_valid), .count(total));
  assert property (@(posedge clk) total <= RW'(M));
`endif

endmodule

`default_nettype wire
