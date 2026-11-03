// Ref: (new common primitive) number of set bits
`default_nettype none

module ttg_popcount #(
  parameter int N  = 8,
  parameter int CW = $clog2(N + 1)
) (
  input  logic [N-1:0]  bits,
  output logic [CW-1:0] count
);

  always_comb begin
    count = '0;
    for (int i = 0; i < N; i++) count = count + CW'(bits[i]);
  end

endmodule

`default_nettype wire
