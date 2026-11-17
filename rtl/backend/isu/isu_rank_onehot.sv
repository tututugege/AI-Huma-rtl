// Ref: (new common primitive) the k-th lowest set bit, for k = 0 .. K-1, in parallel
`default_nettype none

// onehot[k] marks the set bit of `set` that has exactly k set bits below it (the k-th lowest), all zero when there are fewer. A
// log-depth saturating prefix count gives every bit the number of set bits below it (saturated at K, which no output matches).
module isu_rank_onehot #(
  parameter int N = 64,
  parameter int K = 2
) (
  input  logic [N-1:0] set,
  output logic [N-1:0] onehot [K]
);

  localparam int SW     = $clog2(K + 1);
  localparam int STAGES = (N > 1) ? $clog2(N) : 1;

  function automatic logic [SW-1:0] sat_add(input logic [SW-1:0] a, input logic [SW-1:0] b);
    logic [SW:0] s;
    s = {1'b0, a} + {1'b0, b};
    return (s > (SW+1)'(K)) ? SW'(K) : s[SW-1:0];
  endfunction

  logic [SW-1:0] pre [STAGES+1][N];   // pre[STAGES][i]: set bits in 0 .. i
  logic [SW-1:0] rank [N];            // set bits below bit i

  always_comb begin
    for (int i = 0; i < N; i++) pre[0][i] = SW'(set[i]);
    for (int s = 0; s < STAGES; s++)
      for (int i = 0; i < N; i++)
        pre[s+1][i] = (i >= (1 << s)) ? sat_add(pre[s][i], pre[s][i - (1 << s)]) : pre[s][i];
    for (int i = 0; i < N; i++) rank[i] = (i == 0) ? '0 : pre[STAGES][i-1];
    for (int k = 0; k < K; k++)
      for (int i = 0; i < N; i++) onehot[k][i] = set[i] && (rank[i] == SW'(k));
  end

endmodule

`default_nettype wire
