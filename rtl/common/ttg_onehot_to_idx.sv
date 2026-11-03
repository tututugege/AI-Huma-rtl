// Ref: (new common primitive) one-hot vector to binary index (all-zero input gives index 0)
`default_nettype none

module ttg_onehot_to_idx #(
  parameter int N    = 8,
  parameter int IDXW = (N > 1) ? $clog2(N) : 1
) (
  input  logic [N-1:0]    onehot,
  output logic [IDXW-1:0] idx
);

  // OR-reduce the indices of the set bits: bit b of idx is set if any set position has bit b set
  always_comb begin
    idx = '0;
    for (int i = 0; i < N; i++) idx = idx | (IDXW'(i) & {IDXW{onehot[i]}});
  end

endmodule

`default_nettype wire
