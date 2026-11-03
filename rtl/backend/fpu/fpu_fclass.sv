// Ref: back-end/Exu/include/FPU.h  FPUSoftfloat::f32_classify
`default_nettype none

// fclass.s: one-hot class mask in bits 0..9 (-inf, -norm, -sub, -0, +0, +sub, +norm, +inf, sNaN, qNaN).
module fpu_fclass (
  input  logic [31:0] a,
  output logic [31:0] class_mask
);

  logic        sign, is_zero, is_sub, is_norm, is_inf, is_nan, is_snan;
  logic [7:0]  exp_unused;
  logic [22:0] frac_unused;

  fpu_unpack u_a (.x(a), .sign(sign), .exp_field(exp_unused), .frac(frac_unused), .is_zero(is_zero), .is_sub(is_sub),
                  .is_norm(is_norm), .is_inf(is_inf), .is_nan(is_nan), .is_snan(is_snan));

  assign class_mask = {22'd0, is_nan & ~is_snan, is_snan,
                       is_inf & ~sign, is_norm & ~sign, is_sub & ~sign, is_zero & ~sign,
                       is_zero & sign, is_sub & sign, is_norm & sign, is_inf & sign};

  /* verilator lint_off UNUSEDSIGNAL */  // field outputs of the shared splitter are not needed for classification
  logic unused_fields;
  assign unused_fields = ^{exp_unused, frac_unused};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
