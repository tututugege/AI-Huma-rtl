// Ref: back-end/Exu/include/Fu.h  AluUnit
`default_nettype none

// Integer ALU: RV32I / RV64I (+ *W forms) + Zba/Zbb/Zbs/Zbc subset.  Datapath = shared adder, comparators,
// bitwise unit, funnel shifter, carry-less multiplier and a Zbb unary unit; alu_decode picks the unit.
module alu
  import exu_fu_pkg::*;
  import ttg_cfg_pkg::*;
(
  input  logic                en,
  input  logic                consume,
  input  logic [OP_W-1:0]     op,
  input  logic [2:0]          func3,
  input  logic [6:0]          func7,
  input  logic                src1_is_pc,
  input  logic                src2_is_imm,
  input  logic                is_word,
  input  logic [XLEN_BITS-1:0]         pc,
  input  logic [31:0]         imm,
  input  logic [XLEN_BITS-1:0]         src1_rdata,
  input  logic [XLEN_BITS-1:0]         src2_rdata,
  output logic                complete,
  output logic                ready,
  output logic [XLEN_BITS-1:0]         result
);

  localparam int NSRC = 9;
  localparam int HW = XLEN_BITS / 2;           // the *W word width (rv64: 32)
  localparam int SHW = $clog2(XLEN_BITS);

  alu_ctl_t    ctl;
  logic [XLEN_BITS-1:0] opa, opb;
  logic [SHW-1:0] shamt;
  logic [XLEN_BITS-1:0] imm_x;

  exu_fu_sc_ctl u_ctl (.en(en), .consume(consume), .complete(complete), .ready(ready));

  alu_decode u_dec (
    .op(op), .func3(func3), .func7_in(func7), .src2_is_imm(src2_is_imm), .is_word(is_word), .imm_lo(imm[4:0]),
    .ctl(ctl)
  );

  // Ref: AluUnit::impl_compute operand selection
  always_comb begin
    imm_x = XLEN_BITS'($signed(imm));
    opa   = src1_is_pc ? pc : src1_rdata;
    opb   = src2_is_imm ? imm_x : src2_rdata;
    shamt = ctl.w_shamt5 ? SHW'(opb[$clog2(HW)-1:0]) : opb[SHW-1:0];
  end

  // rv64 word-op operand1 preconditioning: zero-extended (add.uw, shNadd.uw, slli.uw, srlw), sign-extended (sraw)
  logic [XLEN_BITS-1:0] opa_w;
  always_comb begin
    opa_w = opa;
    if (ctl.w_zext_a)      opa_w = {{(XLEN_BITS - HW){1'b0}}, opa[HW-1:0]};
    else if (ctl.w_sext_a) opa_w = {{(XLEN_BITS - HW){opa[HW-1]}}, opa[HW-1:0]};
  end

  // ---- adder / subtractor (add, sub, sh1add, sh2add, sh3add) ----
  logic [XLEN_BITS-1:0] add_a, add_res;
  always_comb begin
    add_a   = opa_w << ctl.add_shamt;
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
  logic [XLEN_BITS-1:0] lg_b_raw, lg_b, lg_res;
  always_comb begin
    lg_b_raw = ctl.lg_bit_b ? (XLEN_BITS'(1) << shamt) : opb;
    lg_b     = ctl.lg_inv_b ? ~lg_b_raw : lg_b_raw;
    lg_res = (ctl.lg_and ? (opa & lg_b) : '0) | (ctl.lg_or ? (opa | lg_b) : '0)
           | (ctl.lg_xor ? (opa ^ lg_b) : '0);
  end

  logic [XLEN_BITS-1:0] shf_res, unary_res, mm_res, pack_res;
  logic [2*XLEN_BITS-1:0] clmul_prod;
  logic [XLEN_BITS-1:0] shf_x, cnt_x;
  logic [XLEN_BITS-1:0] clmul_res;

  // shifter input: rotates of a word run on {a, a}, the other word shifts on the extended opa_w
  always_comb begin
    shf_x = opa_w;
    cnt_x = opa;
    if (ctl.w_rot) shf_x = {opa[HW-1:0], opa[HW-1:0]};
    if (ctl.w_cnt) begin
      if (ctl.clz)       cnt_x = {opa[HW-1:0], {HW{1'b1}}};
      else if (ctl.ctz)  cnt_x = {HW'(1), opa[HW-1:0]};
      else               cnt_x = {{HW{1'b0}}, opa[HW-1:0]};
    end
  end

  alu_shift u_shift (
    .x(shf_x), .shamt(shamt), .left(ctl.shf_left), .rot(ctl.shf_rot), .arith(ctl.shf_arith), .y(shf_res)
  );
  alu_clmul u_clmul (.a(opa), .b(opb), .prod(clmul_prod));
  alu_bitcnt u_unary (
    .x(cnt_x), .sel_clz(ctl.clz), .sel_ctz(ctl.ctz), .sel_cpop(ctl.cpop), .sel_sext_b(ctl.sext_b),
    .sel_sext_h(ctl.sext_h), .sel_rev8(ctl.rev8), .sel_orcb(ctl.orcb), .y(unary_res)
  );

  always_comb begin
    mm_res    = pick_a ? opa : opb;
    // pack: XLEN/2-bit halves (packw: 16-bit halves, rv64 only); packh: bytes
    pack_res  = ctl.packh ? {{(XLEN_BITS - 16){1'b0}}, opb[7:0], opa[7:0]}
              : (ctl.w_res && XLEN_BITS == 64) ? XLEN_BITS'({opb[15:0], opa[15:0]})
              : {opb[XLEN_BITS/2-1:0], opa[XLEN_BITS/2-1:0]};
    clmul_res = ({XLEN_BITS{ctl.clmul}} & clmul_prod[XLEN_BITS-1:0])
              | ({XLEN_BITS{ctl.clmulr}} & clmul_prod[2*XLEN_BITS-2:XLEN_BITS-1])
              | ({XLEN_BITS{ctl.clmulh}} & clmul_prod[2*XLEN_BITS-1:XLEN_BITS]);
  end

  logic [XLEN_BITS-1:0] src [NSRC];
  always_comb begin
    src[0] = add_res;
    src[1] = {{(XLEN_BITS - 1){1'b0}}, ctl.slt ? lt_s : lt_u};
    src[2] = lg_res;
    src[3] = mm_res;
    src[4] = shf_res;
    src[5] = {{(XLEN_BITS - 1){1'b0}}, shf_res[0]};   // bext: (opa >> shamt) & 1, shifter run as a logical right shift
    src[6] = pack_res;
    src[7] = unary_res;
    src[8] = clmul_res;
  end

  // the logic-unit selects are one-hot among themselves, so OR-ing them as one source is exact
  logic [XLEN_BITS-1:0] res_raw;
  ttg_onehot_mux #(.N(NSRC), .W(XLEN_BITS)) u_res (
    .sel({ctl.clmul | ctl.clmulr | ctl.clmulh,
          ctl.clz | ctl.ctz | ctl.cpop | ctl.sext_b | ctl.sext_h | ctl.rev8 | ctl.orcb,
          ctl.pack | ctl.packh, ctl.bext, ctl.shf, ctl.mm,
          ctl.lg_and | ctl.lg_or | ctl.lg_xor, ctl.slt | ctl.sltu, ctl.add}),
    .data(src), .out(res_raw)
  );

  // rv64 *W: the 32-bit result is sign-extended
  assign result = ctl.w_res ? {{(XLEN_BITS - HW){res_raw[HW-1]}}, res_raw[HW-1:0]} : res_raw;

endmodule

`default_nettype wire
