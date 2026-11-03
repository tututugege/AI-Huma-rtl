// Ref: back-end/Exu/include/FPU.h  FPUSoftfloat::impl_compute (dispatch), FPUSoftfloat::calculate_latency
`default_nettype none

// uop fields -> instruction kind (one-hot) and latency. Encodings softfloat's impl_compute asserts on (reserved
// func7/func3/rs2 values) are unreachable from a decoded RISC-V F instruction: they select no kind and result in 0.
module fpu_decode
  import fpu_pkg::*;
(
  input  logic [6:0]            func7,
  input  logic [2:0]            func3,
  input  logic                  rs2_bit0,       // imm[0]: 0 = signed, 1 = unsigned variant of fcvt
  output logic [NKIND-1:0]      kind,
  output logic [LAT_W-1:0]      latency_minus_1
);

  logic arith_group;     // func7>>2 in 0..3: fadd/fsub/fmul/fdiv (func7[1:0] is the format, ignored like the reference)
  logic is_cvt_w, is_cvt_s, is_sqrt, is_sgnj, is_minmax, is_cmp, is_class;
  logic is_mul, is_div;

  assign arith_group = (func7[6:4] == 3'd0);
  assign is_cvt_w    = (func7 == 7'h60);
  assign is_cvt_s    = (func7 == 7'h68);
  assign is_sqrt     = (func7 == 7'h2C);
  assign is_sgnj     = (func7 == 7'h10);
  assign is_minmax   = (func7 == 7'h14);
  assign is_cmp      = (func7 == 7'h50);
  assign is_class    = (func7 == 7'h70);
  assign is_mul      = arith_group & (func7[3:2] == 2'd2);
  assign is_div      = arith_group & (func7[3:2] == 2'd3);

  always_comb begin
    kind            = '0;
    kind[K_ADD]     = arith_group & (func7[3:2] == 2'd0);
    kind[K_SUB]     = arith_group & (func7[3:2] == 2'd1);
    kind[K_MUL]     = is_mul;
    kind[K_DIV]     = is_div;
    kind[K_SQRT]    = is_sqrt;
    kind[K_CVT_W]   = is_cvt_w & ~rs2_bit0;
    kind[K_CVT_WU]  = is_cvt_w & rs2_bit0;
    kind[K_CVT_SW]  = is_cvt_s & ~rs2_bit0;
    kind[K_CVT_SWU] = is_cvt_s & rs2_bit0;
    kind[K_SGNJ]    = is_sgnj & (func3 == 3'd0);
    kind[K_SGNJN]   = is_sgnj & (func3 == 3'd1);
    kind[K_SGNJX]   = is_sgnj & (func3 == 3'd2);
    kind[K_MIN]     = is_minmax & (func3 == 3'd0);
    kind[K_MAX]     = is_minmax & (func3 == 3'd1);
    kind[K_EQ]      = is_cmp & (func3 == 3'd2);
    kind[K_LT]      = is_cmp & (func3 == 3'd1);
    kind[K_LE]      = is_cmp & (func3 == 3'd0);
    kind[K_CLASS]   = is_class;
  end

  // mul and the conversions: 3 cycles, div and sqrt: 10, everything else (including unknown encodings): 5
  always_comb begin
    latency_minus_1 = LAT_W'(LAT_FADD - 1);
    if (is_mul | is_cvt_w | is_cvt_s) latency_minus_1 = LAT_W'(LAT_FMUL - 1);
    if (is_div | is_sqrt)             latency_minus_1 = LAT_W'(LAT_FDIV - 1);
  end

endmodule

`default_nettype wire
