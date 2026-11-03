// Ref: back-end/Exu/include/Fu.h  AluUnit::impl_compute (the op/func3/func7 selection tree)
`default_nettype none

// Decode (op, func3, func7, src2_is_imm, imm[4:0]) into the unit-select bits of alu_ctl_t.  The C++ if/else chains
// are mutually exclusive by construction (distinct func7 values), so every chain becomes independent AND terms and
// the "else" arm is the complement of the listed arms.  Encodings the C++ leaves unwritten (result stays 0) select
// nothing and therefore give 0, exactly like the C++.
// The ALU port only ever sees ADD/FENCE/ECALL/EBREAK/SFENCE_VMA/FENCE_I/MRET/SRET/WFI: UOP_JUMP never reaches it
// (OP_MASK_ALU), so the C++ `op == UOP_JUMP -> operand2 = 4` special case is not translated (docs/modules/exu_int.md).
module alu_decode
  import exu_fu_pkg::*;
(
  input  logic [OP_W-1:0] op,
  input  logic [2:0]      func3,
  input  logic [6:0]      func7,
  input  logic            src2_is_imm,
  input  logic [4:0]      imm_lo,    // imm[4:0]: sub-opcode of the Zbb unary ops, shamt check of rev8 / orc.b
  output alu_ctl_t        ctl
);

  localparam logic [6:0] F7_BASE   = 7'h00;  // plain RV32I
  localparam logic [6:0] F7_ALT    = 7'h20;  // sub / sra / xnor / orn / andn
  localparam logic [6:0] F7_SHADD  = 7'h10;  // Zba shNadd
  localparam logic [6:0] F7_MINMAX = 7'h05;  // Zbb min/max, Zbc clmul*
  localparam logic [6:0] F7_PACK   = 7'h04;  // Zbb pack/packh
  localparam logic [6:0] F7_ROT    = 7'h30;  // Zbb rol/ror, unary ops
  localparam logic [6:0] F7_BCLR   = 7'h24;  // Zbs bclr/bext
  localparam logic [6:0] F7_BSET   = 7'h14;  // Zbs bset, Zbb orc.b
  localparam logic [6:0] F7_BINV   = 7'h34;  // Zbs binv, Zbb rev8

  // ---- field predicates ----
  logic op_is_add, op_is_wfi, imm_form, reg_form;
  logic f3_sub, f3_sll, f3_slt, f3_sltu, f3_xor, f3_srl, f3_or, f3_and;
  logic f7_base, f7_bclr, f7_bset, f7_binv, f7_rot;
  logic alt_r, shadd_r, mm_r, pack_r;  // register-form (non-immediate) Zb* encodings
  always_comb begin
    op_is_add = (op == UOP_ADD);
    op_is_wfi = (op == UOP_WFI);
    imm_form  = src2_is_imm;
    reg_form  = !src2_is_imm;
    f3_sub    = (func3 == 3'd0);
    f3_sll    = (func3 == 3'd1);
    f3_slt    = (func3 == 3'd2);
    f3_sltu   = (func3 == 3'd3);
    f3_xor    = (func3 == 3'd4);
    f3_srl    = (func3 == 3'd5);
    f3_or     = (func3 == 3'd6);
    f3_and    = (func3 == 3'd7);
    f7_base   = (func7 == F7_BASE);
    f7_bclr   = (func7 == F7_BCLR);
    f7_bset   = (func7 == F7_BSET);
    f7_binv   = (func7 == F7_BINV);
    f7_rot    = (func7 == F7_ROT);
    alt_r     = (func7 == F7_ALT) && reg_form;
    shadd_r   = (func7 == F7_SHADD) && reg_form;
    mm_r      = (func7 == F7_MINMAX) && reg_form;
    pack_r    = (func7 == F7_PACK) && reg_form;
  end

  // ---- shifts / rotates / single-bit ops (func3 = 1 and 5) ----
  logic sll_s, rol_s, srl_s, sra_s, ror_s, bclr_s, bset_s, binv_s, bext_s, unary_s, clmul_s, rev8_s, orcb_s;
  logic srl_other;
  always_comb begin
    sll_s   = f3_sll && f7_base;
    rol_s   = f3_sll && f7_rot && reg_form;
    bclr_s  = f3_sll && f7_bclr;
    bset_s  = f3_sll && f7_bset;
    binv_s  = f3_sll && f7_binv;
    clmul_s = f3_sll && (func7 == F7_MINMAX);
    unary_s = f3_sll && f7_rot && imm_form;
    // func3 = 5 chain: srl | sra(reg) | srai | ror | bext | rev8 | orc.b | minu | else srl
    sra_s      = f3_srl && (alt_r || (func7[5] && imm_form && !(f7_rot || f7_bclr || f7_binv || f7_bset)));
    ror_s      = f3_srl && f7_rot;
    bext_s     = f3_srl && f7_bclr;
    rev8_s     = f3_srl && f7_binv && imm_form && (imm_lo == 5'd24);
    orcb_s     = f3_srl && f7_bset && imm_form && (imm_lo == 5'd7);
    // every func7/imm combination that has an arm of its own (also rev8 / orc.b with a wrong shamt: result 0)
    srl_other  = alt_r || (func7[5] && imm_form) || f7_rot || f7_bclr || (f7_binv && imm_form)
              || (f7_bset && imm_form) || mm_r;
    srl_s      = f3_srl && !srl_other;
  end

  // ---- assemble the control word ----
  always_comb begin
    ctl = '0;
    if (op_is_add) begin
      ctl.add       = f3_sub || (f3_slt && shadd_r) || (f3_xor && shadd_r) || (f3_or && shadd_r);
      ctl.sub       = f3_sub && func7[5] && reg_form;
      ctl.add_shamt = {shadd_r && (f3_xor || f3_or), shadd_r && (f3_slt || f3_or)};  // sh1add=1, sh2add=2, sh3add=3
      ctl.slt       = f3_slt && !(shadd_r || mm_r);
      ctl.sltu      = f3_sltu && !mm_r;
      ctl.lg_and    = (f3_and && !(mm_r || pack_r)) || bclr_s;
      ctl.lg_or     = (f3_or && !(mm_r || shadd_r)) || bset_s;
      ctl.lg_xor    = (f3_xor && !(shadd_r || mm_r || pack_r)) || binv_s;
      ctl.lg_inv_b  = (alt_r && (f3_and || f3_or || f3_xor)) || bclr_s;
      ctl.lg_bit_b  = bclr_s || bset_s || binv_s;
      ctl.mm        = mm_r && (f3_xor || f3_or || f3_srl || f3_and);
      ctl.mm_max    = mm_r && (f3_or || f3_and);
      ctl.mm_uns    = mm_r && (f3_srl || f3_and);
      ctl.shf       = sll_s || rol_s || srl_s || sra_s || ror_s;
      ctl.shf_left  = sll_s || rol_s;
      ctl.shf_rot   = rol_s || ror_s;
      ctl.shf_arith = sra_s;
      ctl.bext      = bext_s;
      ctl.pack      = f3_xor && pack_r;
      ctl.packh     = f3_and && pack_r;
      ctl.clz       = unary_s && (imm_lo == 5'd0);
      ctl.ctz       = unary_s && (imm_lo == 5'd1);
      ctl.cpop      = unary_s && (imm_lo == 5'd2);
      ctl.sext_b    = unary_s && (imm_lo == 5'd4);
      ctl.sext_h    = unary_s && (imm_lo == 5'd5);
      ctl.rev8      = rev8_s;
      ctl.orcb      = orcb_s;
      ctl.clmul     = clmul_s;
      ctl.clmulr    = f3_slt && mm_r;
      ctl.clmulh    = f3_sltu && mm_r;
    end else begin
      ctl.add       = !op_is_wfi;  // FENCE/ECALL/...: operand1 + operand2; WFI: 0
    end
  end

endmodule

`default_nettype wire
