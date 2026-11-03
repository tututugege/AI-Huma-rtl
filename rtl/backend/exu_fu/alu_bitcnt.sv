// Ref: back-end/Exu/include/Fu.h  AluUnit::impl_compute (Zbb clz/ctz/cpop/sext.b/sext.h/rev8/orc.b)
`default_nettype none

// Zbb unary operations on operand1.  Exactly one select may be set; none set gives 0.
module alu_bitcnt (
  input  logic [31:0] x,
  input  logic        sel_clz,
  input  logic        sel_ctz,
  input  logic        sel_cpop,
  input  logic        sel_sext_b,
  input  logic        sel_sext_h,
  input  logic        sel_rev8,
  input  logic        sel_orcb,
  output logic [31:0] y
);

  localparam int NSRC = 7;

  logic [31:0] x_rev;
  logic [31:0] lo_first, hi_first;   // lowest set bit of x / of rev(x) = highest set bit of x
  logic        lo_any, hi_any;
  logic [4:0]  lo_idx, hi_idx;
  logic [5:0]  pop;
  logic [31:0] src [NSRC];
  logic [31:0] clz_val, ctz_val, orcb_val;

  always_comb for (int i = 0; i < 32; i++) x_rev[i] = x[31 - i];

  ttg_first_set #(.N(32)) u_lo (.req(x), .onehot(lo_first), .any(lo_any));
  ttg_first_set #(.N(32)) u_hi (.req(x_rev), .onehot(hi_first), .any(hi_any));
  ttg_onehot_to_idx #(.N(32)) u_lo_idx (.onehot(lo_first), .idx(lo_idx));
  ttg_onehot_to_idx #(.N(32)) u_hi_idx (.onehot(hi_first), .idx(hi_idx));
  ttg_popcount #(.N(32)) u_pop (.bits(x), .count(pop));

  always_comb begin
    ctz_val = lo_any ? {27'd0, lo_idx} : 32'd32;            // ctz(0) = 32
    clz_val = hi_any ? {27'd0, hi_idx} : 32'd32;            // lowest set bit of rev(x) sits at position clz(x)
    for (int b = 0; b < 4; b++) orcb_val[8*b +: 8] = {8{|x[8*b +: 8]}};
    src[0] = clz_val;
    src[1] = ctz_val;
    src[2] = {26'd0, pop};
    src[3] = {{24{x[7]}}, x[7:0]};
    src[4] = {{16{x[15]}}, x[15:0]};
    src[5] = {x[7:0], x[15:8], x[23:16], x[31:24]};
    src[6] = orcb_val;
  end

  ttg_onehot_mux #(.N(NSRC), .W(32)) u_mux (
    .sel({sel_orcb, sel_rev8, sel_sext_h, sel_sext_b, sel_cpop, sel_ctz, sel_clz}), .data(src), .out(y)
  );

endmodule

`default_nettype wire
