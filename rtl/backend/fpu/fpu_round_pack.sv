// Ref: back-end/Exu/include/FPU.h  (softfloat softfloat_roundPackToF32, used by f32_div / f32_sqrt / i32_to_f32)
`default_nettype none

// Round and pack a finite non-zero result into binary32.
//   value = (-1)^sign * sig27 * 2^(exp_biased - 127 - 26); sig27[26] is the leading one,
//   sig27[2:0] = guard/round/sticky.
// exp_biased <= 0 produces a subnormal (the significand is shifted right with sticky); exp_biased >= 255 or a rounding
// carry into the exponent field overflows to infinity or the largest finite value depending on mode and sign.
module fpu_round_pack
  import fpu_pkg::*;
(
  input  logic                sign,
  input  logic signed [11:0]  exp_biased,
  input  logic [26:0]         sig27,
  input  fpu_rm_t             rm,
  output logic [31:0]         result
);

  logic        is_subnormal_range;   // exp_biased <= 0
  logic        exp_overflow;         // exp_biased >= 255 before rounding
  logic [11:0] shift_amount;         // 1 - exp_biased, only meaningful for subnormal results
  logic [4:0]  shift_clamped;        // >= 27 shifts everything out: 27 and above behave the same
  logic [26:0] lost_mask;
  logic [26:0] sig_shifted;
  logic        lost_nonzero;
  logic [26:0] sig_final;
  logic [23:0] sig24;
  logic        inc;
  logic [24:0] sig24_rounded;
  logic [7:0]  exp_field_base;
  logic [31:0] magnitude;
  logic        magnitude_overflow;
  logic        overflow_to_inf;
  logic        any_overflow;

  assign is_subnormal_range = (exp_biased <= 12'sd0);
  assign exp_overflow       = (exp_biased >= 12'sd255);
  assign shift_amount       = 12'sd1 - exp_biased;
  assign shift_clamped      = (shift_amount > 12'd27) ? 5'd27 : shift_amount[4:0];

  // right shift with sticky ("jam"): bits shifted out are OR-ed into bit 0
  assign lost_mask    = ~({27{1'b1}} << shift_clamped);
  assign lost_nonzero = |(sig27 & lost_mask);
  assign sig_shifted  = (sig27 >> shift_clamped) | {26'd0, lost_nonzero};
  assign sig_final    = is_subnormal_range ? sig_shifted : sig27;

  assign sig24 = sig_final[26:3];
  assign inc   = fpu_round_inc(rm, sig_final[2], sig_final[1] | sig_final[0], sig_final[3], sign);
  assign sig24_rounded = {1'b0, sig24} + {24'd0, inc};

  // Normal: field = exp_biased-1 and the leading one of sig24 adds the missing 1; subnormal: field 0, no leading one,
  // and a rounding carry into bit 23 naturally becomes the smallest normal number.
  assign exp_field_base = is_subnormal_range ? 8'd0 : 8'(exp_biased - 12'sd1);
  assign magnitude      = {exp_field_base, 23'd0} + {7'd0, sig24_rounded};
  assign magnitude_overflow = exp_overflow | (magnitude[30:23] == 8'hFF);

  assign overflow_to_inf = rm.rne | rm.rmm | (rm.rdn & sign) | (rm.rup & ~sign);
  assign any_overflow    = magnitude_overflow;

  always_comb begin
    result = {sign, magnitude[30:0]};
    if (any_overflow) result = {sign, overflow_to_inf ? 31'h7F800000 : 31'h7F7FFFFF};
  end

  /* verilator lint_off UNUSEDSIGNAL */  // magnitude[31] is always 0: the sum stays below 2^31
  logic unused_msb;
  assign unused_msb = magnitude[31];
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
