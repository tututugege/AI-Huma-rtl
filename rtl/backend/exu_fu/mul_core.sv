// Ref: back-end/Exu/include/Fu.h  MulUnit::impl_compute (mul / mulh / mulhsu / mulhu, and rv64 mulw)
`default_nettype none

// XLENxXLEN multiplier, the four M-extension variants selected by func3[1:0]:
//   0 mul (low half) 1 mulh (signed x signed) 2 mulhsu (signed x unsigned) 3 mulhu (unsigned x unsigned).
// rv64 mulw (is_word, func3 = 0): the low word of the product, sign-extended.
module mul_core import ttg_cfg_pkg::*; (
  input  logic [1:0]  func3,
  input  logic        is_word,
  input  logic [XLEN_BITS-1:0] src1_rdata,
  input  logic [XLEN_BITS-1:0] src2_rdata,
  output logic [XLEN_BITS-1:0] result
);

  localparam int W = XLEN_BITS;
  localparam int HW = XLEN_BITS / 2;

  logic               a_signed, b_signed;
  logic signed [W:0]  a_ext, b_ext;
  logic signed [2*W-1:0] prod;   // the low 2*XLEN bits of the (2*XLEN+2)-bit product are all that is used

  always_comb begin
    a_signed = (func3 == 2'd1) || (func3 == 2'd2);   // mulh, mulhsu: signed rs1 (mul: low half is sign agnostic)
    b_signed = (func3 == 2'd1);                      // mulh: signed rs2
    a_ext    = $signed({a_signed && src1_rdata[W-1], src1_rdata});
    b_ext    = $signed({b_signed && src2_rdata[W-1], src2_rdata});
    prod     = a_ext * b_ext;                        // signed x signed, extended to 2*XLEN bits by context
    if (is_word)              result = {{(W - HW){prod[HW-1]}}, prod[HW-1:0]};
    else if (func3 == 2'd0)   result = prod[W-1:0];
    else                      result = prod[2*W-1:W];
  end

endmodule

`default_nettype wire
