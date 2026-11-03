// Ref: back-end/Exu/include/FPU.h  FPUSoftfloat (case FDIV: f32_div, RISC-V NaN/inf/zero rules)
`default_nettype none

// binary32 division, bit-exact with softfloat for all five rounding modes (result only, no flags).
module fpu_div
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

  // ---- finite non-zero path ----
  logic [23:0]        sig_a, sig_b;
  logic signed [11:0] e_a, e_b;
  logic [27:0]        quotient;
  logic               rem_nonzero;
  logic               sign_res;
  logic               q_top;              // sa >= sb: quotient in [1,2), otherwise [0.5,1)
  logic [26:0]        sig27;
  logic signed [11:0] exp_biased;
  logic [31:0]        numeric_result;

  fpu_norm u_norm_a (.exp_field(exp_a), .frac(frac_a), .sig24(sig_a), .exp_unbiased(e_a));
  fpu_norm u_norm_b (.exp_field(exp_b), .frac(frac_b), .sig24(sig_b), .exp_unbiased(e_b));
  fpu_div_array u_array (.sa(sig_a), .sb(sig_b), .quotient(quotient), .remainder_nonzero(rem_nonzero));

  assign sign_res = sign_a ^ sign_b;
  assign q_top    = quotient[27];
  // keep 24 significand bits + guard + round + sticky; everything below is folded into the sticky bit
  assign sig27      = q_top ? {quotient[27:2], quotient[1] | quotient[0] | rem_nonzero}
                            : {quotient[26:1], quotient[0] | rem_nonzero};
  assign exp_biased = e_a - e_b + (q_top ? 12'sd127 : 12'sd126);

  fpu_round_pack u_pack (.sign(sign_res), .exp_biased(exp_biased), .sig27(sig27), .rm(rm), .result(numeric_result));

  // ---- special operands (softfloat RISC-V specialisation: any NaN result is the canonical quiet NaN) ----
  always_comb begin
    result = numeric_result;
    if (nan_a || nan_b || (inf_a && inf_b) || (zero_a && zero_b)) result = F32_QNAN;
    else if (inf_a || zero_b)                                      result = {sign_res, 31'h7F800000};
    else if (inf_b || zero_a)                                      result = {sign_res, 31'd0};
  end

  /* verilator lint_off UNUSEDSIGNAL */  // class flags this block does not need
  logic unused_flags;
  assign unused_flags = ^{sub_a, norm_a, snan_a, sub_b, norm_b, snan_b};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
