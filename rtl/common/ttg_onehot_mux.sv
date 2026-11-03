// Ref: (new common primitive) AND-OR multiplexer selected by a one-hot vector (no select gives 0)
`default_nettype none

module ttg_onehot_mux #(
  parameter int N = 4,
  parameter int W = 8
) (
  input  logic [N-1:0] sel,
  input  logic [W-1:0] data [N],
  output logic [W-1:0] out
);

  always_comb begin
    out = '0;
    for (int i = 0; i < N; i++) out = out | (data[i] & {W{sel[i]}});
  end

endmodule

`default_nettype wire
