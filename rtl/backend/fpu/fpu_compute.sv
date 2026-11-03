// Ref: back-end/Exu/include/FPU.h  FPUSoftfloat::impl_compute (result selection)
`default_nettype none

// All FP operations side by side, one result per kind, selected by the one-hot kind. Purely combinational: the FU
// registers its operands at accept and reads this result when the latency has elapsed (a multi-cycle path).
module fpu_compute
  import fpu_pkg::*;
(
  input  logic [NKIND-1:0] kind,
  input  logic [2:0]       func3,       // rounding mode for the arithmetic/conversion kinds
  input  logic [31:0]      a,
  input  logic [31:0]      b,
  output logic [31:0]      result
);

  fpu_rm_t rm;
  assign rm = fpu_rm_decode(func3);

  logic [31:0] res_addsub, res_mul, res_div, res_sqrt, res_f2i, res_i2f;
  logic [31:0] res_sgnj, res_sgnjn, res_sgnjx, res_min, res_max, res_class;
  logic        cmp_nan, cmp_eq, cmp_lt, cmp_le, a_lt_b, b_lt_a;

  fpu_addsub u_addsub (.a(a), .b(b), .is_sub(kind[K_SUB]), .rm(rm), .result(res_addsub));
  fpu_mul    u_mul    (.a(a), .b(b), .rm(rm), .result(res_mul));
  fpu_div    u_div    (.a(a), .b(b), .rm(rm), .result(res_div));
  fpu_sqrt   u_sqrt   (.a(a), .rm(rm), .result(res_sqrt));
  fpu_cvt_f2i u_f2i   (.a(a), .rm(rm), .is_unsigned(kind[K_CVT_WU]), .result(res_f2i));
  fpu_cvt_i2f u_i2f   (.a(a), .rm(rm), .is_unsigned(kind[K_CVT_SWU]), .result(res_i2f));
  fpu_sgnj   u_sgnj   (.a(a), .b_sign(b[31]), .sgnj(res_sgnj), .sgnjn(res_sgnjn), .sgnjx(res_sgnjx));
  fpu_cmp    u_cmp    (.a(a), .b(b), .nan_either(cmp_nan), .eq(cmp_eq), .lt(cmp_lt), .le(cmp_le));
  fpu_fclass u_class  (.a(a), .class_mask(res_class));

  assign a_lt_b = cmp_lt;
  assign b_lt_a = ~cmp_nan & ~cmp_le;   // both ordered: b < a  <=>  not (a <= b)

  fpu_minmax u_minmax (.a(a), .b(b), .nan_a(fpu_is_nan(a[30:0])), .nan_b(fpu_is_nan(b[30:0])),
                       .a_lt_b(a_lt_b), .b_lt_a(b_lt_a), .min_result(res_min), .max_result(res_max));

  logic [31:0] result_by_kind [NKIND];

  always_comb begin
    result_by_kind[K_ADD]     = res_addsub;
    result_by_kind[K_SUB]     = res_addsub;
    result_by_kind[K_MUL]     = res_mul;
    result_by_kind[K_DIV]     = res_div;
    result_by_kind[K_SQRT]    = res_sqrt;
    result_by_kind[K_CVT_W]   = res_f2i;
    result_by_kind[K_CVT_WU]  = res_f2i;
    result_by_kind[K_CVT_SW]  = res_i2f;
    result_by_kind[K_CVT_SWU] = res_i2f;
    result_by_kind[K_SGNJ]    = res_sgnj;
    result_by_kind[K_SGNJN]   = res_sgnjn;
    result_by_kind[K_SGNJX]   = res_sgnjx;
    result_by_kind[K_MIN]     = res_min;
    result_by_kind[K_MAX]     = res_max;
    result_by_kind[K_EQ]      = {31'd0, cmp_eq};
    result_by_kind[K_LT]      = {31'd0, cmp_lt};
    result_by_kind[K_LE]      = {31'd0, cmp_le};
    result_by_kind[K_CLASS]   = res_class;
  end

  ttg_onehot_mux #(.N(NKIND), .W(32)) u_select (.sel(kind), .data(result_by_kind), .out(result));

endmodule

`default_nettype wire
