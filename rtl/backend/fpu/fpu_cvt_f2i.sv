// Ref: back-end/Exu/include/FPU.h  FPUSoftfloat (case FCVT_W_S: f32_to_i32 / f32_to_ui32, exact=true)
`default_nettype none

// float -> int32 / uint32 with the given rounding mode. Saturation follows softfloat's RISC-V specialisation:
//   signed:   NaN, +overflow -> 0x7FFFFFFF, -overflow -> 0x80000000
//   unsigned: NaN, +overflow -> 0xFFFFFFFF, negative (non-zero after rounding) -> 0
module fpu_cvt_f2i
  import fpu_pkg::*;
(
  input  logic [31:0] a,
  input  fpu_rm_t     rm,
  input  logic        is_unsigned,
  output logic [31:0] result
);

  logic        sign_a, zero_a, inf_a, nan_a;
  logic [7:0]  exp_a;
  logic [22:0] frac_a;
  logic        sub_a, norm_a, snan_a;   // not needed here

  fpu_unpack u_a (.x(a), .sign(sign_a), .exp_field(exp_a), .frac(frac_a), .is_zero(zero_a), .is_sub(sub_a),
                  .is_norm(norm_a), .is_inf(inf_a), .is_nan(nan_a), .is_snan(snan_a));

  // Fixed point image of |a|: P = m * 2^(sh + 2), m = {hidden, frac}, sh = unbiased exponent (valid for sh+2 >= 0).
  // P[56:25] is the integer part, P[24] the round bit, P[23:0] (plus bits shifted out) the sticky bits.
  logic [23:0]        mant;
  logic signed [11:0] sh;               // unbiased exponent (subnormals use -126)
  logic signed [11:0] shift_left;       // sh + 2
  logic [56:0]        left_value;
  logic [56:0]        fixed_point;
  logic               sticky_shifted;
  logic               too_big;          // |a| >= 2^32: overflows both formats whatever the rounding

  assign mant       = {~zero_a & ~sub_a, frac_a};
  assign sh         = sub_a ? -12'sd126 : ($signed({4'b0, exp_a}) - 12'sd127);
  assign shift_left = sh + 12'sd2;
  assign too_big    = (sh >= 12'sd32);

  // |a| < 2^-2 (shift_left < 0): integer part and round bit are 0 and every mantissa bit is sticky
  assign left_value     = {33'd0, mant} << shift_left[5:0];
  assign fixed_point    = (shift_left >= 12'sd0) ? left_value : 57'd0;
  assign sticky_shifted = (shift_left < 12'sd0) & (|mant);

  logic [31:0] int_part;
  logic        round_bit, sticky, inc;
  logic [32:0] int_rounded;

  assign int_part    = fixed_point[56:25];
  assign round_bit   = fixed_point[24];
  assign sticky      = (|fixed_point[23:0]) | sticky_shifted;
  assign inc         = fpu_round_inc(rm, round_bit, sticky, int_part[0], sign_a);
  assign int_rounded = {1'b0, int_part} + {32'd0, inc};

  // saturation and sign application
  logic [31:0] signed_result, unsigned_result;
  logic        signed_overflow, unsigned_overflow;

  assign signed_overflow   = too_big | (sign_a ? (int_rounded > 33'h80000000) : (int_rounded >= 33'h80000000));
  assign unsigned_overflow = too_big | int_rounded[32];

  always_comb begin
    signed_result = sign_a ? (32'd0 - int_rounded[31:0]) : int_rounded[31:0];
    if (signed_overflow) signed_result = sign_a ? 32'h80000000 : 32'h7FFFFFFF;
    unsigned_result = sign_a ? 32'd0 : int_rounded[31:0];
    if (!sign_a && unsigned_overflow) unsigned_result = 32'hFFFFFFFF;
    result = is_unsigned ? unsigned_result : signed_result;
    if (nan_a)      result = is_unsigned ? 32'hFFFFFFFF : 32'h7FFFFFFF;
  end

  /* verilator lint_off UNUSEDSIGNAL */  // class flags this block does not need (infinity is covered by too_big)
  logic unused_flags;
  assign unused_flags = ^{inf_a, snan_a, norm_a};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
