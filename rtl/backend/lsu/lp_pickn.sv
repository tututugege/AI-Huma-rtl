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

  ttg_pick_k #(.N(N), .K(K)) u_pk (.req(vec), .pick_oh(onehot), .valid(v));
  for (genvar m = 0; m < K; m++) begin : g_m
    ttg_onehot_to_idx #(.N(N), .IDXW(IW)) u_ix (.onehot(onehot[m]), .idx(idx[m]));
  end

endmodule

`default_nettype wire
