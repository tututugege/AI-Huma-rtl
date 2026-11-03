// Ref: back-end/Exu/include/FPU.h  FPUSoftfloat::f32_classify / is_nan_u32 (field split and value classes)
`default_nettype none

// Binary32 field split and value class flags (exactly one of zero/sub/norm/inf/nan holds).
module fpu_unpack (
  input  logic [31:0] x,
  output logic        sign,
  output logic [7:0]  exp_field,
  output logic [22:0] frac,
  output logic        is_zero,
  output logic        is_sub,
  output logic        is_norm,
  output logic        is_inf,
  output logic        is_nan,
  output logic        is_snan
);

  logic exp_zero, exp_ones, frac_zero;

  assign sign      = x[31];
  assign exp_field = x[30:23];
  assign frac      = x[22:0];
  assign exp_zero  = (exp_field == 8'h00);
  assign exp_ones  = (exp_field == 8'hFF);
  assign frac_zero = (frac == 23'd0);
  assign is_zero   = exp_zero & frac_zero;
  assign is_sub    = exp_zero & ~frac_zero;
  assign is_norm   = ~exp_zero & ~exp_ones;
  assign is_inf    = exp_ones & frac_zero;
  assign is_nan    = exp_ones & ~frac_zero;
  assign is_snan   = is_nan & ~frac[22];

endmodule

`default_nettype wire
