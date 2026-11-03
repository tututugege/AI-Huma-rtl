// Ref: back-end/Exu/include/FPU.h  FPUSoftfloat (cases FADD/FSUB: f32_add, b sign flipped for FSUB)
`default_nettype none

// binary32 add / subtract, bit-exact with softfloat for all rounding modes (result only, no flags).
// Far/near path in one datapath: order by magnitude, align the smaller operand (sticky jam), add or subtract,
// normalise by leading-zero count, round/pack in fpu_round_pack.
module fpu_addsub
  import fpu_pkg::*;
(
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        is_sub,
  input  fpu_rm_t     rm,
  output logic [31:0] result
);

  logic [31:0] b_eff;
  assign b_eff = {b[31] ^ is_sub, b[30:0]};

  logic       zero_a, zero_b, inf_a, inf_b, nan_a, nan_b;
  logic       sign_a, sign_b;
  logic [7:0] exp_a, exp_b;
  logic [22:0] frac_a, frac_b;
  logic       sub_a, norm_a, snan_a, sub_b, norm_b, snan_b;   // not needed here

  fpu_unpack u_a (.x(a), .sign(sign_a), .exp_field(exp_a), .frac(frac_a), .is_zero(zero_a), .is_sub(sub_a),
                  .is_norm(norm_a), .is_inf(inf_a), .is_nan(nan_a), .is_snan(snan_a));
  fpu_unpack u_b (.x(b_eff), .sign(sign_b), .exp_field(exp_b), .frac(frac_b), .is_zero(zero_b), .is_sub(sub_b),
                  .is_norm(norm_b), .is_inf(inf_b), .is_nan(nan_b), .is_snan(snan_b));

  // ---- order by magnitude: L = larger, S = smaller ----
  logic        a_larger;
  logic        sign_l, sign_s;
  logic [7:0]  exp_l, exp_s;       // effective exponent field (subnormals count as 1)
  logic [23:0] mant_l, mant_s;     // with hidden bit
  logic [7:0]  exp_diff;

  assign a_larger = (a[30:0] >= b_eff[30:0]);
  assign sign_l   = a_larger ? sign_a : sign_b;
  assign sign_s   = a_larger ? sign_b : sign_a;
  assign exp_l    = a_larger ? ((exp_a == 8'd0) ? 8'd1 : exp_a) : ((exp_b == 8'd0) ? 8'd1 : exp_b);
  assign exp_s    = a_larger ? ((exp_b == 8'd0) ? 8'd1 : exp_b) : ((exp_a == 8'd0) ? 8'd1 : exp_a);
  assign mant_l   = a_larger ? {(exp_a != 8'd0), frac_a} : {(exp_b != 8'd0), frac_b};
  assign mant_s   = a_larger ? {(exp_b != 8'd0), frac_b} : {(exp_a != 8'd0), frac_a};
  assign exp_diff = exp_l - exp_s;

  // ---- align the smaller operand: 3 extra low bits (guard, round, sticky), shifted-out bits jam into bit 0 ----
  logic [26:0] big27, small27, small_aligned, lost_mask;
  logic [4:0]  shift_clamped;
  logic        lost_nonzero;

  assign big27         = {mant_l, 3'b000};
  assign small27       = {mant_s, 3'b000};
  assign shift_clamped = (exp_diff > 8'd27) ? 5'd27 : exp_diff[4:0];
  assign lost_mask     = ~({27{1'b1}} << shift_clamped);
  assign lost_nonzero  = |(small27 & lost_mask);
  assign small_aligned = (small27 >> shift_clamped) | {26'd0, lost_nonzero};

  // ---- add / subtract ----
  logic        eff_sub;
  logic [27:0] sum;
  assign eff_sub = sign_l ^ sign_s;
  assign sum     = eff_sub ? ({1'b0, big27} - {1'b0, small_aligned}) : ({1'b0, big27} + {1'b0, small_aligned});

  // ---- normalise: leading one to bit 26 of sig27 ----
  logic [4:0]  lead_zeros;
  logic        sum_zero;
  logic [27:0] sum_left;
  logic [26:0] sig27;
  logic signed [11:0] exp_biased;

  fpu_clz #(.W(28)) u_clz (.x(sum), .count(lead_zeros), .all_zero(sum_zero));

  assign sum_left   = sum << lead_zeros;                       // leading one at bit 27 (when non-zero)
  assign sig27      = {sum_left[27:2], sum_left[1] | sum_left[0]};   // drop one position: bit 27 -> 26
  assign exp_biased = $signed({4'b0, exp_l}) + 12'sd1 - $signed({7'b0, lead_zeros});

  logic [31:0] numeric_result;
  fpu_round_pack u_pack (.sign(sign_l), .exp_biased(exp_biased), .sig27(sig27), .rm(rm), .result(numeric_result));

  // ---- special operands and exact cancellation ----
  always_comb begin
    result = numeric_result;
    if (sum_zero) result = {eff_sub ? rm.rdn : sign_l, 31'd0};   // x + (-x) = +0 (-0 when rounding down)
    if (inf_a || inf_b) result = inf_a ? {sign_a, 31'h7F800000} : {sign_b, 31'h7F800000};
    if (nan_a || nan_b || (inf_a && inf_b && (sign_a != sign_b))) result = F32_QNAN;
  end

  /* verilator lint_off UNUSEDSIGNAL */  // class flags this block does not need
  logic unused_flags;
  assign unused_flags = ^{zero_a, zero_b, sub_a, norm_a, snan_a, sub_b, norm_b, snan_b};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
