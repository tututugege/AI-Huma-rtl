// Ref: back-end/Exu/include/FPU.h  FPUSoftfloat::f32_min_riscv / f32_max_riscv
`default_nettype none

// fmin / fmax with the RISC-V rules: one NaN -> the other operand, two NaNs -> canonical NaN, -0 < +0.
module fpu_minmax
  import fpu_pkg::*;
(
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        nan_a,
  input  logic        nan_b,
  input  logic        a_lt_b,      // numeric a < b (false when either is NaN)
  input  logic        b_lt_a,      // numeric b < a
  output logic [31:0] min_result,
  output logic [31:0] max_result
);

  logic [31:0] min_ordered, max_ordered;

  always_comb begin
    // neither is NaN: strictly ordered -> the smaller/larger; equal (including -0 vs +0) -> OR / AND of the patterns
    min_ordered = a_lt_b ? a : (b_lt_a ? b : (a | b));
    max_ordered = a_lt_b ? b : (b_lt_a ? a : (a & b));
    min_result  = min_ordered;
    max_result  = max_ordered;
    if (nan_a && nan_b) begin
      min_result = F32_QNAN;
      max_result = F32_QNAN;
    end else if (nan_a) begin
      min_result = b;
      max_result = b;
    end else if (nan_b) begin
      min_result = a;
      max_result = a;
    end
  end

endmodule

`default_nettype wire
