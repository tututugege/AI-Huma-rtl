// Ref: back-end/Exu/include/FPU.h  (softfloat f32_div significand division)
`default_nettype none

// Restoring divider array: q = floor(sa * 2^27 / sb) for normalised 24-bit significands (2^23 <= sa, sb < 2^24),
// 28 quotient bits (q < 2^28, q >= 2^26), one subtract-and-select stage per bit. It is a multi-cycle path in the FU:
// the operands are registered at accept and the quotient is only consumed LAT_FDIV cycles later.
module fpu_div_array (
  input  logic [23:0] sa,
  input  logic [23:0] sb,
  output logic [27:0] quotient,
  output logic        remainder_nonzero
);

  logic [23:0] remainder [28];   // partial remainder after stage i, always < sb

  for (genvar i = 0; i < 28; i++) begin : g_stage
    logic [24:0] dividend_i;     // previous remainder shifted left (stage 0: the dividend itself)
    logic [23:0] diff;       // exact when fits: the true difference is below sb < 2^24
    logic        fits;
    if (i == 0) begin : g_first
      assign dividend_i = {1'b0, sa};
    end else begin : g_next
      assign dividend_i = {remainder[i-1], 1'b0};
    end
    assign diff  = dividend_i[23:0] - sb;
    assign fits  = (dividend_i >= {1'b0, sb});
    assign remainder[i]   = fits ? diff : dividend_i[23:0];
    assign quotient[27-i] = fits;
  end

  assign remainder_nonzero = |remainder[27];

endmodule

`default_nettype wire
