// Ref: back-end/Exu/include/FPU.h  FPUSoftfloat (case FCMP: f32_eq / f32_lt / f32_le; also used by f32_min/max_riscv)
`default_nettype none

// binary32 comparisons. Any NaN operand makes eq/lt/le false (flags are not modelled).
module fpu_cmp
  import fpu_pkg::*;
(
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        nan_either,
  output logic        eq,
  output logic        lt,
  output logic        le
);

  logic sign_a, sign_b;
  logic both_zero;           // magnitudes of a and b are both zero (+0 == -0)
  logic bits_equal;
  logic mag_less;            // |a| < |b| as unsigned bit patterns
  logic signs_differ;
  logic lt_raw, le_raw;

  assign sign_a = a[31];
  assign sign_b = b[31];
  assign nan_either   = fpu_is_nan(a[30:0]) | fpu_is_nan(b[30:0]);
  assign both_zero    = ~|((a | b) & 32'h7FFFFFFF);
  assign bits_equal   = (a == b);
  assign signs_differ = sign_a ^ sign_b;
  assign mag_less     = (a[30:0] < b[30:0]);

  always_comb begin
    // same sign: ordering of the bit patterns, reversed for negative numbers
    lt_raw = signs_differ ? (sign_a & ~both_zero) : (~bits_equal & (sign_a ^ mag_less));
    le_raw = signs_differ ? (sign_a | both_zero)  : (bits_equal | (sign_a ^ mag_less));
  end

  assign eq = ~nan_either & (bits_equal | both_zero);
  assign lt = ~nan_either & lt_raw;
  assign le = ~nan_either & le_raw;

endmodule

`default_nettype wire
