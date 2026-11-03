// Ref: back-end/Exu/include/Fu.h  AluUnit
`default_nettype none

// Integer ALU: RV32I + Zba/Zbb/Zbs/Zbc subset.  Datapath = shared adder, comparators, bitwise unit, funnel shifter,
// carry-less multiplier and a Zbb unary unit; alu_decode picks which unit drives the result.
module alu
  import exu_fu_pkg::*;
(
  input  logic                en,
  input  logic                consume,
  input  logic [OP_W-1:0]     op,
  input  logic [2:0]          func3,
  input  logic [6:0]          func7,
  input  logic                src1_is_pc,
  input  logic                src2_is_imm,
  input  logic [31:0]         pc,
  input  logic [31:0]         imm,
  input  logic [31:0]         src1_rdata,
  input  logic [31:0]         src2_rdata,
  output logic                complete,
  output logic                ready,
  output logic [31:0]         result
);

  localparam int NSRC = 9;

  alu_ctl_t    ctl;
  logic [31:0] opa, opb;
  logic [4:0]  shamt;

  exu_fu_sc_ctl u_ctl (.en(en), .consume(consume), .complete(complete), .ready(ready));

  alu_decode u_dec (
    .op(op), .func3(func3), .func7(func7), .src2_is_imm(src2_is_imm), .imm_lo(imm[4:0]), .ctl(ctl)
  );

  // Ref: AluUnit::impl_compute operand selection
  always_comb begin
    opa   = src1_is_pc ? pc : src1_rdata;
    opb   = src2_is_imm ? imm : src2_rdata;
    shamt = opb[4:0];
  end

  // ---- adder / subtractor (add, sub, sh1add, sh2add, sh3add) ----
  logic [31:0] add_a, add_res;
  always_comb begin
    add_a   = opa << ctl.add_shamt;
    add_res = ctl.sub ? (add_a - opb) : (add_a + opb);
  end

  // ---- comparators (slt/sltu and min/max family share them) ----
  logic lt_s, lt_u, eq, gt_cmp, pick_a;
  always_comb begin
    lt_s   = $signed(opa) < $signed(opb);  // signed compare, explicit $signed
    lt_u   = opa < opb;
    eq     = (opa == opb);
    gt_cmp = ctl.mm_uns ? (!lt_u && !eq) : (!lt_s && !eq);
    pick_a = ctl.mm_max ? gt_cmp : (ctl.mm_uns ? lt_u : lt_s);  // keep operand1, else operand2
  end

  // ---- bitwise unit: and/or/xor of opa and B (B = opb, ~opb, or a one-hot bit mask) ----
  logic [31:0] lg_b_raw, lg_b, lg_res;
  always_comb begin
    lg_b_raw = ctl.lg_bit_b ? (32'd1 << shamt) : opb;
    lg_b     = ctl.lg_inv_b ? ~lg_b_raw : lg_b_raw;
    lg_res = (ctl.lg_and ? (opa & lg_b) : 32'd0) | (ctl.lg_or ? (opa | lg_b) : 32'd0)
           | (ctl.lg_xor ? (opa ^ lg_b) : 32'd0);
  end

  logic [31:0] shf_res, unary_res, mm_res, pack_res;
  logic [63:0] clmul_prod;
  logic [31:0] clmul_res;

  alu_shift u_shift (
    .x(opa), .shamt(shamt), .left(ctl.shf_left), .rot(ctl.shf_rot), .arith(ctl.shf_arith), .y(shf_res)
  );
  alu_clmul u_clmul (.a(opa), .b(opb), .prod(clmul_prod));
  alu_bitcnt u_unary (
    .x(opa), .sel_clz(ctl.clz), .sel_ctz(ctl.ctz), .sel_cpop(ctl.cpop), .sel_sext_b(ctl.sext_b),
    .sel_sext_h(ctl.sext_h), .sel_rev8(ctl.rev8), .sel_orcb(ctl.orcb), .y(unary_res)
  );

  always_comb begin
    mm_res    = pick_a ? opa : opb;
    pack_res  = ctl.packh ? {16'd0, opb[7:0], opa[7:0]} : {opb[15:0], opa[15:0]};
    clmul_res = ({32{ctl.clmul}} & clmul_prod[31:0]) | ({32{ctl.clmulr}} & clmul_prod[62:31])
              | ({32{ctl.clmulh}} & clmul_prod[63:32]);
  end

  logic [31:0] src [NSRC];
  always_comb begin
    src[0] = add_res;
    src[1] = {31'd0, ctl.slt ? lt_s : lt_u};
    src[2] = lg_res;
    src[3] = mm_res;
    src[4] = shf_res;
    src[5] = {31'd0, shf_res[0]};   // bext: (opa >> shamt) & 1, shifter run as a logical right shift
    src[6] = pack_res;
    src[7] = unary_res;
    src[8] = clmul_res;
  end

  // the logic-unit selects are one-hot among themselves, so OR-ing them as one source is exact
  ttg_onehot_mux #(.N(NSRC), .W(32)) u_res (
    .sel({ctl.clmul | ctl.clmulr | ctl.clmulh,
          ctl.clz | ctl.ctz | ctl.cpop | ctl.sext_b | ctl.sext_h | ctl.rev8 | ctl.orcb,
          ctl.pack | ctl.packh, ctl.bext, ctl.shf, ctl.mm,
          ctl.lg_and | ctl.lg_or | ctl.lg_xor, ctl.slt | ctl.sltu, ctl.add}),
    .data(src), .out(result)
  );

endmodule

`default_nettype wire
