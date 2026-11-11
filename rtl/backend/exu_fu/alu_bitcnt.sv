// Ref: back-end/Exu/include/Fu.h  AluUnit::impl_compute (Zbb clz/ctz/cpop/sext.b/sext.h/rev8/orc.b)
`default_nettype none

// Zbb unary operations on operand1 (XLEN_BITS wide).  Exactly one select may be set; none set gives 0.  The rv64 word
// forms (clzw/ctzw/cpopw) are run by the caller on a preconditioned operand: {a, 32'hFFFFFFFF} / {32'h1, a} / zext(a).
module alu_bitcnt import ttg_cfg_pkg::*; (
  input  logic [XLEN_BITS-1:0] x,
  input  logic        sel_clz,
  input  logic        sel_ctz,
  input  logic        sel_cpop,
  input  logic        sel_sext_b,
  input  logic        sel_sext_h,
  input  logic        sel_rev8,
  input  logic        sel_orcb,
  output logic [XLEN_BITS-1:0] y
);

  localparam int NSRC = 7;
  localparam int W = XLEN_BITS;
  localparam int IW = $clog2(W);

  logic [W-1:0] x_rev;
  logic [W-1:0] lo_first, hi_first;   // lowest set bit of x / of rev(x) = highest set bit of x
  logic         lo_any, hi_any;
  logic [IW-1:0] lo_idx, hi_idx;
  logic [IW:0]  pop;
  logic [W-1:0] src [NSRC];
  logic [W-1:0] clz_val, ctz_val, orcb_val, rev8_val;

  always_comb for (int i = 0; i < W; i++) x_rev[i] = x[W - 1 - i];

  ttg_first_set #(.N(W)) u_lo (.req(x), .onehot(lo_first), .any(lo_any));
  ttg_first_set #(.N(W)) u_hi (.req(x_rev), .onehot(hi_first), .any(hi_any));
  ttg_onehot_to_idx #(.N(W)) u_lo_idx (.onehot(lo_first), .idx(lo_idx));
  ttg_onehot_to_idx #(.N(W)) u_hi_idx (.onehot(hi_first), .idx(hi_idx));
  ttg_popcount #(.N(W)) u_pop (.bits(x), .count(pop));

  always_comb begin
    ctz_val = lo_any ? W'(lo_idx) : W'(W);            // ctz(0) = XLEN
    clz_val = hi_any ? W'(hi_idx) : W'(W);            // lowest set bit of rev(x) sits at position clz(x)
    for (int b = 0; b < W / 8; b++) orcb_val[8*b +: 8] = {8{|x[8*b +: 8]}};
    for (int b = 0; b < W / 8; b++) rev8_val[8*b +: 8] = x[8*(W/8 - 1 - b) +: 8];
    src[0] = clz_val;
    src[1] = ctz_val;
    src[2] = W'(pop);
    src[3] = {{(W - 8){x[7]}}, x[7:0]};
    src[4] = {{(W - 16){x[15]}}, x[15:0]};
    src[5] = rev8_val;
    src[6] = orcb_val;
  end

  ttg_onehot_mux #(.N(NSRC), .W(W)) u_mux (
    .sel({sel_orcb, sel_rev8, sel_sext_h, sel_sext_b, sel_cpop, sel_ctz, sel_clz}), .data(src), .out(y)
  );

endmodule

`default_nettype wire
