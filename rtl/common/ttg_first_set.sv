// Ref: (new common primitive) find-first-set, lowest index has priority
`default_nettype none

module ttg_first_set #(
  parameter int N = 8
) (
  input  logic [N-1:0] req,
  output logic [N-1:0] onehot,
  output logic         any
);

  // isolate the lowest set bit with a log-depth prefix OR (Kogge-Stone): below[i] = |req[i-1:0].
  // (req & -req would be the same function, but a plain carry chain is N gate levels deep)
  localparam int STAGES = (N > 1) ? $clog2(N) : 1;

  logic [N-1:0] pre [STAGES+1];   // pre[s][i] = |req[i : max(0, i - 2^s + 1)]

  always_comb begin
    pre[0] = req;
    for (int s = 0; s < STAGES; s++) pre[s+1] = pre[s] | (pre[s] << (1 << s));
    onehot = req & ~(pre[STAGES] << 1);
    any    = |req;
  end

endmodule

`default_nettype wire
