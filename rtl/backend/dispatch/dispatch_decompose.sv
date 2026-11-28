// Ref: back-end/Dispatch.cpp  Dispatch::decompose_inst / make_dis_iss_uop
`default_nettype none

// Splits one instruction into its micro-ops. Every instruction yields at most one uop of each kind
// (INT, LD, STA, STD, BR, FP), so the result is a uop per kind plus a "has uop" flag per kind:
//   STORE -> STA+STD     JAL/JALR -> INT(add pc+4)+BR(jump)     AMO.LR -> LD     AMO.SC -> STA+STD
//   AMO.rmw -> LD+STA+STD     BR -> BR     LOAD -> LD     everything else -> one INT uop
module dispatch_decompose
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  dis_iss_uop_t               base,        // make_dis_iss_uop(): the instruction as one uop
  input  inst_type_e                 itype,
  input  dis_class_t                 cls,         // dis_classify(itype, amo op)
  input  logic                       is_rvc,      // 16-bit instruction: JAL/JALR link value 2, else 4
  input  logic [2:0]                 fp_cls,      // FP unit class of an FPOP instruction (FPC_*)
  input  logic                       me_elim,     // eliminated move: no uop at all, completes in the ROB at dispatch
  output logic [K_NUM-1:0]          has_k,
  output dis_iss_uop_t               uop_k [K_NUM],
  output logic [CPLT_MASK_W-1:0]     expect_mask  // ROB completion groups this instruction waits for
);

  logic         amo_swap;
  logic         amo_rmw;   // AMO that is neither LR nor SC

  always_comb begin
    amo_swap = (base.func7[6:2] == AMO_SWAP);
    amo_rmw  = cls.is_amo && (base.func7[6:2] != AMO_LR) && !cls.is_amo_sc;
    has_k[K_INT] = cls.to_int && !me_elim;
    has_k[K_LD]  = cls.is_load;
    has_k[K_STA] = cls.is_store;
    has_k[K_STD] = cls.is_store;
    has_k[K_BR]  = cls.to_br;
    has_k[K_FP]  = cls.to_fp;
  end

  // ---- K_INT: ALU-class ops, CSR/system ops, and the pc+4 half of JAL/JALR ----
  always_comb begin
    uop_k[K_INT] = base;
    case (itype)
      INST_MUL:        uop_k[K_INT].op = UOP_MUL;
      INST_DIV:        uop_k[K_INT].op = UOP_DIV;
      INST_CSR:        uop_k[K_INT].op = UOP_CSR;
      INST_FENCE:      uop_k[K_INT].op = UOP_FENCE;
      INST_ECALL:      uop_k[K_INT].op = UOP_ECALL;
      INST_MRET:       uop_k[K_INT].op = UOP_MRET;
      INST_SRET:       uop_k[K_INT].op = UOP_SRET;
      INST_SFENCE_VMA: uop_k[K_INT].op = UOP_SFENCE_VMA;
      INST_FENCE_I:    uop_k[K_INT].op = UOP_FENCE_I;
      INST_EBREAK:     uop_k[K_INT].op = UOP_EBREAK;
      INST_WFI:        uop_k[K_INT].op = UOP_WFI;
      INST_FPOP:       uop_k[K_INT].op = UOP_I2F;   // the only FP class issued from an integer port
      INST_JAL, INST_JALR: begin
        uop_k[K_INT].op      = UOP_ADD;
        uop_k[K_INT].imm     = is_rvc ? 32'd2 : 32'd4;
        uop_k[K_INT].src1_en = 1'b0;
        uop_k[K_INT].src2_en = 1'b0;
      end
      default: uop_k[K_INT].op = UOP_ADD;   // ADD and NOP
    endcase
  end

  // ---- K_LD: LOAD, AMO.LR, load half of AMO.rmw ----
  always_comb begin
    uop_k[K_LD] = base;
    uop_k[K_LD].op = UOP_LOAD;
    if (cls.is_amo) uop_k[K_LD].src2_en = 1'b0;
  end

  // ---- K_STA: address half of STORE / AMO.SC / AMO.rmw ----
  always_comb begin
    uop_k[K_STA] = base;
    uop_k[K_STA].op = UOP_STA;
    uop_k[K_STA].src2_en = 1'b0;                       // address uses src1 only
    if (cls.is_amo) uop_k[K_STA].dest_en = cls.is_amo_sc;  // SC returns its 0/1 on the STA writeback
  end

  // ---- K_STD: data half of STORE / AMO.SC / AMO.rmw ----
  always_comb begin
    uop_k[K_STD] = base;
    uop_k[K_STD].op = UOP_STD;
    if (cls.is_amo) begin
      uop_k[K_STD].is_atomic = 1'b1;
      uop_k[K_STD].dest_en   = 1'b0;
    end
    if (itype == INST_STORE) begin
      uop_k[K_STD].src1_en = 1'b0;
      uop_k[K_STD].src2_en = 1'b1;
    end
    if (cls.is_amo_sc) begin
      uop_k[K_STD].src1_en = 1'b0;
    end
    if (amo_rmw) begin   // data uop waits for the loaded old value (not for SWAP)
      uop_k[K_STD].src1_preg = base.dest_preg;
      uop_k[K_STD].src1_busy = !amo_swap;
    end
  end

  // ---- K_BR: conditional branch, or the jump half of JAL/JALR ----
  always_comb begin
    uop_k[K_BR] = base;
    uop_k[K_BR].op = UOP_BR;
    if (itype == INST_JAL || itype == INST_JALR) begin
      uop_k[K_BR].op      = UOP_JUMP;
      uop_k[K_BR].dest_en = 1'b0;
      if (itype == INST_JALR) uop_k[K_BR].src1_en = 1'b1;
    end
  end

  // ---- K_FP: FMA / FDIV / MISC units (F/D) ----
  always_comb begin
    uop_k[K_FP] = base;
    case (fp_cls)
      FPC_FDIV: uop_k[K_FP].op = UOP_FDIV;
      FPC_MISC: uop_k[K_FP].op = UOP_FMISC;
      default:  uop_k[K_FP].op = UOP_FMA;
    endcase
  end

  // ---- ROB completion groups: INT/LD -> G0, BR/STA -> G1, STD -> G2; SC completes G0 (result) + G2 ----
  always_comb begin
    expect_mask = '0;
    if (has_k[K_INT] || has_k[K_LD] || has_k[K_FP]) expect_mask = expect_mask | CPLT_G0;
    if (has_k[K_BR] || has_k[K_STA]) expect_mask = expect_mask | CPLT_G1;
    if (has_k[K_STD])                  expect_mask = expect_mask | CPLT_G2;
    if (cls.is_amo_sc)                   expect_mask = CPLT_G0 | CPLT_G2;
  end

endmodule

`default_nettype wire
