// Ref: (new common primitive) parallel K-way lowest-set-bit picker (thermometer Kogge-Stone prefix sum)
`default_nettype none

// Given an N-bit vector `req`, picks the 1st, 2nd, ..., K-th lowest set bits in parallel:
//   pick_oh[k][i] = 1 iff bit i is the (k+1)-th lowest set bit of req (one-hot per k, or 0 if < k+1 bits set)
//   valid[k]      = 1 iff req has at least (k+1) set bits
// Uses thermometer-coded saturating Kogge-Stone prefix sum (t[m] == 1 iff count >= m + 1) with balanced |terms
// reduction (~3 gate levels per stage, O(log N) depth, zero carry chains).
module ttg_pick_k #(
  parameter int N = 8,
  parameter int K = 4
) (
  input  logic [N-1:0] req,
  output logic [N-1:0] pick_oh [K],
  output logic [K-1:0] valid
);

`ifdef SYNTHESIS
  localparam int STAGES = (N > 1) ? $clog2(N) : 1;

  function automatic logic [K-1:0] therm_add(input logic [K-1:0] a, input logic [K-1:0] b);
    logic [K-1:0] c;
    for (int m = 0; m < K; m++) begin
      logic [K:0] terms;
      terms    = '0;
      terms[0] = a[m];
      terms[1] = b[m];
      for (int p = 1; p <= m; p++) terms[p + 1] = a[p - 1] & b[m - p];
      c[m] = |terms;
    end
    return c;
  endfunction

  logic [K-1:0] pre [STAGES+1][N];
  logic [K-1:0] rank_oh [N];   // rank_oh[i][k] == 1 iff exactly k bits below i are set

  always_comb begin
    for (int i = 0; i < N; i++) begin
      pre[0][i]    = '0;
      pre[0][i][0] = req[i];
    end
    for (int s = 0; s < STAGES; s++)
      for (int i = 0; i < N; i++)
        pre[s+1][i] = (i >= (1 << s)) ? therm_add(pre[s][i], pre[s][i - (1 << s)]) : pre[s][i];
    for (int i = 0; i < N; i++) begin
      logic [K-1:0] tf;
      tf = (i == 0) ? '0 : pre[STAGES][i-1];
      rank_oh[i][0] = ~tf[0];
      for (int m = 1; m < K; m++) rank_oh[i][m] = tf[m-1] & ~tf[m];
    end
  end

  for (genvar k = 0; k < K; k++) begin : g_k
    for (genvar i = 0; i < N; i++) begin : g_i
      assign pick_oh[k][i] = req[i] & rank_oh[i][k];
    end
    assign valid[k] = pre[STAGES][N-1][k];
  end
`else
  // Fast simulation path (bit-identical to thermometer Kogge-Stone above, verified by tests/common_prims)
  always_comb begin
    int cnt;
    cnt   = 0;
    valid = '0;
    for (int k = 0; k < K; k++) pick_oh[k] = '0;
    for (int i = 0; i < N; i++) begin
      if (req[i] && cnt < K) begin
        pick_oh[cnt][i] = 1'b1;
        valid[cnt]      = 1'b1;
        cnt             = cnt + 1;
      end
    end
  end
`endif

endmodule

`default_nettype wire
