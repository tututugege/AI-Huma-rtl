// Ref: back-end/Exu/include/Fu.h  MulUnit::impl_compute
`default_nettype none

// 32x32 multiplier for mul / mulh / mulhsu / mulhu (func3 = 0..3): one 33x33 signed multiplier whose operands are
// sign-extended (signed operand) or zero-extended (unsigned operand).
module mul_core (
  input  logic [1:0]  func3,
  input  logic [31:0] src1_rdata,
  input  logic [31:0] src2_rdata,
  output logic [31:0] result
);

  logic               a_signed, b_signed;
  logic signed [32:0] a_ext, b_ext;
  logic signed [63:0] prod;   // the low 64 bits of the 66-bit product are all that is used

  always_comb begin
    a_signed = (func3 == 2'd1) || (func3 == 2'd2);   // mulh, mulhsu: signed rs1 (mul: low half is sign agnostic)
    b_signed = (func3 == 2'd1);                      // mulh: signed rs2
    a_ext    = $signed({a_signed && src1_rdata[31], src1_rdata});
    b_ext    = $signed({b_signed && src2_rdata[31], src2_rdata});
    prod     = a_ext * b_ext;                        // signed x signed, extended to 64 bits by context
    result   = (func3 == 2'd0) ? prod[31:0] : prod[63:32];
  end

endmodule

`default_nettype wire
