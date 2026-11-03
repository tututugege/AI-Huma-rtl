// Ref: back-end/Exu/include/FPU.h  FPUSoftfloat (case FCVT_S_W: i32_to_f32 / ui32_to_f32)
`default_nettype none

// int32 / uint32 -> binary32, rounded with the given mode (zero converts to +0 in every mode).
module fpu_cvt_i2f
  import fpu_pkg::*;
(
  input  logic [31:0] a,
  input  fpu_rm_t     rm,
  input  logic        is_unsigned,
  output logic [31:0] result
);

  logic        sign;
  logic [31:0] magnitude;
  logic [4:0]  lead_zeros;
  logic        is_zero;
  logic [31:0] normalised;           // magnitude shifted so that the leading one sits at bit 31
  logic [26:0] sig27;
  logic signed [11:0] exp_biased;
  logic [31:0] packed_result;

  assign sign      = ~is_unsigned & a[31];
  assign magnitude = sign ? (32'd0 - a) : a;

  fpu_clz #(.W(32)) u_clz (.x(magnitude), .count(lead_zeros), .all_zero(is_zero));

  assign normalised = magnitude << lead_zeros;
  assign sig27      = {normalised[31:6], |normalised[5:0]};
  assign exp_biased = 12'sd158 - $signed({7'b0, lead_zeros});   // 127 + 31 - lead_zeros

  fpu_round_pack u_pack (.sign(sign), .exp_biased(exp_biased), .sig27(sig27), .rm(rm), .result(packed_result));

  assign result = is_zero ? 32'd0 : packed_result;

endmodule

`default_nettype wire
