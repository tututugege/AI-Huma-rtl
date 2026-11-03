// Ref: back-end/Exu/include/FPU.h  FPUSoftfloat (case FSQRT: f32_sqrt, RISC-V NaN/inf/zero rules)
`default_nettype none

// binary32 square root, bit-exact with softfloat for all rounding modes (result only, no flags).
module fpu_sqrt
  import fpu_pkg::*;
(
  input  logic [31:0] a,
  input  fpu_rm_t     rm,
  output logic [31:0] result
);

  logic        sign_a, zero_a, inf_a, nan_a;
  logic [7:0]  exp_a;
  logic [22:0] frac_a;
  logic        sub_a, norm_a, snan_a;   // not needed here

  fpu_unpack u_a (.x(a), .sign(sign_a), .exp_field(exp_a), .frac(frac_a), .is_zero(zero_a), .is_sub(sub_a),
                  .is_norm(norm_a), .is_inf(inf_a), .is_nan(nan_a), .is_snan(snan_a));

  // ---- finite positive non-zero path: sqrt(2^e * m) with e made even ----
  logic [23:0]        sig_a;
  logic signed [11:0] e_a;
  logic               e_odd;
  logic signed [11:0] e_even;           // e rounded down to an even number
  logic [24:0]        sig_adj;          // m (or 2m when e is odd) as a 25-bit integer scaled by 2^23
  logic [53:0]        radicand;
  logic [26:0]        root;
  logic               rem_nonzero;
  logic [26:0]        sig27;
  logic signed [11:0] exp_biased;
  logic [31:0]        numeric_result;

  fpu_norm u_norm (.exp_field(exp_a), .frac(frac_a), .sig24(sig_a), .exp_unbiased(e_a));

  assign e_odd      = e_a[0];
  assign e_even     = e_a & ~12'sd1;
  assign sig_adj    = e_odd ? {sig_a, 1'b0} : {1'b0, sig_a};
  assign radicand   = {sig_adj, 29'd0};
  assign exp_biased = (e_even >>> 1) + 12'sd127;

  fpu_sqrt_array u_array (.radicand(radicand), .root(root), .remainder_nonzero(rem_nonzero));

  assign sig27 = {root[26:1], root[0] | rem_nonzero};

  fpu_round_pack u_pack (.sign(1'b0), .exp_biased(exp_biased), .sig27(sig27), .rm(rm), .result(numeric_result));

  always_comb begin
    result = numeric_result;
    if (nan_a || (sign_a && !zero_a)) result = F32_QNAN;   // NaN, or negative non-zero (incl. -inf): invalid
    else if (zero_a || inf_a)         result = a;           // +-0 -> +-0, +inf -> +inf
  end

  /* verilator lint_off UNUSEDSIGNAL */  // class flags this block does not need
  logic unused_flags;
  assign unused_flags = ^{sub_a, norm_a, snan_a};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
