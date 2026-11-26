// Ref: rtl/common/ttg_first_set.sv (same function, log-depth form when LP_L2[9])
`default_nettype none

// Find-first-set, lowest index has priority: Kogge-Stone prefix-OR (log2 N levels).
module lp_ffs #(
  parameter int N = 8
) (
  input  logic [N-1:0] req,
  output logic [N-1:0] onehot,
  output logic         any
);

  logic [N-1:0] pre;
  always_comb begin
    pre = req;
    for (int s = 1; s < N; s = s * 2) pre = pre | (pre << s);   // pre[i] = |req[i:0]
    onehot = req & ~(pre << 1);
    any = pre[N-1];
  end

endmodule

`default_nettype wire
