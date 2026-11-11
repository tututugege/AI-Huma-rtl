// Ref: back-end/Exu/include/Fu.h  AluUnit::impl_compute (Zbc clmul / clmulr / clmulh)
`default_nettype none

// XLENxXLEN carry-less multiply: prod[k] = XOR over i of (b[i] & a[k-i]).  clmul = prod[XLEN-1:0],
// clmulr = prod[2*XLEN-2:XLEN-1], clmulh = prod[2*XLEN-1:XLEN] (the top bit of prod is always 0).
module alu_clmul import ttg_cfg_pkg::*; (
  input  logic [XLEN_BITS-1:0] a,
  input  logic [XLEN_BITS-1:0] b,
  output logic [2*XLEN_BITS-1:0] prod
);

  always_comb begin
    prod = '0;
    for (int i = 0; i < XLEN_BITS; i++) prod = prod ^ (((2*XLEN_BITS)'(a) << i) & {(2*XLEN_BITS){b[i]}});
  end

endmodule

`default_nettype wire
