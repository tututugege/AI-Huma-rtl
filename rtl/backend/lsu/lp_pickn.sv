// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (find-first picks over a 64-bit vector: write-back, drain, replay regis
`default_nettype none

// The K lowest set bits of a vector: onehot[m] / idx[m] / v[m] = the m-th lowest set bit (m = 0 is the lowest).
module lp_pickn #(
  parameter int N = 64,
  parameter int K = 4,
  parameter int IW = (N > 1) ? $clog2(N) : 1
) (
  input  logic [N-1:0]  vec,
  output logic [N-1:0]  onehot [K],
  output logic [IW-1:0] idx [K],
  output logic [K-1:0]  v
);

  logic [N-1:0] rem [K+1];
  logic [K-1:0] any_k;
  assign rem[0] = vec;
  for (genvar m = 0; m < K; m++) begin : g_m
    lp_ffs #(.N(N)) u_fs (.req(rem[m]), .onehot(onehot[m]), .any(any_k[m]));
    ttg_onehot_to_idx #(.N(N), .IDXW(IW)) u_ix (.onehot(onehot[m]), .idx(idx[m]));
    assign rem[m+1] = rem[m] & ~onehot[m];
  end
  assign v = any_k;

endmodule

`default_nettype wire
