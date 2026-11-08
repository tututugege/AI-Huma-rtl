// Ref: lp_ffs (same function) + its prefix-OR
`default_nettype none

// Find-first-set with the prefix-OR exported: pre[i] = |req[i:0] (Kogge-Stone), onehot = req & ~(pre << 1).
module lp_ffs_p #(
  parameter int N = 8
) (
  input  logic [N-1:0] req,
  output logic [N-1:0] onehot,
  output logic         any,
  output logic [N-1:0] pre
);

  always_comb begin
    pre = req;
    for (int s = 1; s < N; s = s * 2) pre = pre | (pre << s);
    onehot = req & ~(pre << 1);
    any = pre[N-1];
  end

endmodule

`default_nettype wire
