// Ref: back-end/Exu/include/FPU.h  (softfloat normSubnormalF32Sig, used by f32_div / f32_sqrt)
`default_nettype none

// Operand normalisation: 24-bit significand with the leading one at bit 23 and the unbiased exponent
// (value = sig24 * 2^(exp - 23)). Valid for finite non-zero operands; subnormals are shifted up.
module fpu_norm (
  input  logic [7:0]  exp_field,
  input  logic [22:0] frac,
  output logic [23:0] sig24,
  output logic signed [11:0] exp_unbiased
);

  logic [4:0] lz;
  logic       lz_all_zero;
  logic       is_sub;

  assign is_sub = (exp_field == 8'h00);

  // leading zeros of {0, frac}: >= 1 for every subnormal
  fpu_clz #(.W(24)) u_clz (.x({1'b0, frac}), .count(lz), .all_zero(lz_all_zero));

  always_comb begin
    sig24        = {1'b1, frac};
    exp_unbiased = 12'sd0 + $signed({4'b0, exp_field}) - 12'sd127;
    if (is_sub) begin
      sig24        = {1'b0, frac} << lz;
      exp_unbiased = -12'sd126 - $signed({7'b0, lz});
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */  // an all-zero fraction (+-0) is screened out by the callers
  logic unused_lz_all_zero;
  assign unused_lz_all_zero = lz_all_zero;
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
