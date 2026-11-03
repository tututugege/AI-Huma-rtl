// Ref: back-end/Exu/include/FPU.h  FPUSoftfloat (case FMUL: f32_mul)
`default_nettype none

// binary32 multiply, bit-exact with softfloat for all rounding modes (result only, no flags).
module fpu_mul
  import fpu_pkg::*;
(
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  fpu_rm_t     rm,
  output logic [31:0] result
);

  logic        sign_a, sign_b, zero_a, zero_b, inf_a, inf_b, nan_a, nan_b;
  logic [7:0]  exp_a, exp_b;
  logic [22:0] frac_a, frac_b;
  logic        sub_a, norm_a, snan_a, sub_b, norm_b, snan_b;   // not needed here

  fpu_unpack u_a (.x(a), .sign(sign_a), .exp_field(exp_a), .frac(frac_a), .is_zero(zero_a), .is_sub(sub_a),
                  .is_norm(norm_a), .is_inf(inf_a), .is_nan(nan_a), .is_snan(snan_a));
  fpu_unpack u_b (.x(b), .sign(sign_b), .exp_field(exp_b), .frac(frac_b), .is_zero(zero_b), .is_sub(sub_b),
                  .is_norm(norm_b), .is_inf(inf_b), .is_nan(nan_b), .is_snan(snan_b));

  logic [23:0]        sig_a, sig_b;
  logic signed [11:0] e_a, e_b;
  logic [47:0]        product;      // in [2^46, 2^48)
  logic               top;          // product >= 2: result significand needs the carry position
  logic [26:0]        sig27;
  logic signed [11:0] exp_biased;
  logic               sign_res;
  logic [31:0]        numeric_result;

  fpu_norm u_norm_a (.exp_field(exp_a), .frac(frac_a), .sig24(sig_a), .exp_unbiased(e_a));
  fpu_norm u_norm_b (.exp_field(exp_b), .frac(frac_b), .sig24(sig_b), .exp_unbiased(e_b));

  assign product    = sig_a * sig_b;
  assign top        = product[47];
  assign sig27      = top ? {product[47:22], |product[21:0]} : {product[46:21], |product[20:0]};
  assign exp_biased = e_a + e_b + (top ? 12'sd128 : 12'sd127);
  assign sign_res   = sign_a ^ sign_b;

  fpu_round_pack u_pack (.sign(sign_res), .exp_biased(exp_biased), .sig27(sig27), .rm(rm), .result(numeric_result));

  always_comb begin
    result = numeric_result;
    if (zero_a || zero_b) result = {sign_res, 31'd0};
    if (inf_a || inf_b)   result = {sign_res, 31'h7F800000};
    if (nan_a || nan_b || (inf_a && zero_b) || (zero_a && inf_b)) result = F32_QNAN;
  end

  /* verilator lint_off UNUSEDSIGNAL */  // class flags this block does not need
  logic unused_flags;
  assign unused_flags = ^{sub_a, norm_a, snan_a, sub_b, norm_b, snan_b};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
