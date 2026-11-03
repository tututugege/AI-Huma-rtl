// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (prefix count: replaces the running counters of the C++ window scans)
`default_nettype none

// rank[i] = number of set bits strictly below i
module lsu_rank #(
  parameter int N  = 20,
  parameter int CW = $clog2(N + 1)
) (
  input  logic [N-1:0]  bits,
  output logic [CW-1:0] rank [N]
);

  always_comb begin
    rank[0] = '0;
    for (int i = 1; i < N; i++) rank[i] = rank[i-1] + CW'(bits[i-1]);
  end

endmodule

`default_nettype wire
