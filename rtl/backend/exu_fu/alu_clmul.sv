// Ref: back-end/Exu/include/Fu.h  AluUnit::impl_compute (Zbc clmul / clmulr / clmulh)
`default_nettype none

// 32x32 carry-less multiply: prod[k] = XOR over i of (b[i] & a[k-i]).  clmul = prod[31:0], clmulr = prod[62:31],
// clmulh = prod[63:32] (prod[63] is always 0).  The C++ per-bit XOR loops are these three slices.
module alu_clmul (
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [63:0] prod
);

  always_comb begin
    prod = '0;
    for (int i = 0; i < 32; i++) prod = prod ^ (({32'd0, a} << i) & {64{b[i]}});
  end

endmodule

`default_nettype wire
