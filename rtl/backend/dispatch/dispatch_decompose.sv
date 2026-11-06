// Ref: back-end/Dispatch.cpp  Dispatch::decompose_inst / make_dis_iss_uop
`default_nettype none

// Splits one instruction into its micro-ops. Every instruction yields at most one uop per issue
// queue (INT, LD, STA, STD, BR), so the result is a uop per IQ plus a "has uop" flag per IQ:
//   STORE -> STA+STD     JAL/JALR -> INT(add pc+4)+BR(jump)     AMO.LR -> LD     AMO.SC -> STA+STD
//   AMO.rmw -> LD+STA+STD     BR -> BR     LOAD -> LD     everything else -> one INT uop
module dispatch_decompose
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  dis_iss_uop_t               base,        // make_dis_iss_uop(): the instruction as one uop
  input  inst_type_e                 itype,
  input  dis_class_t                 cls,         // dis_classify(itype, amo op)
  input  logic                       me_elim,     // eliminated move: no uop at all, completes in the ROB at dispatch
  output logic [IQ_NUM-1:0]          has_iq,
  output dis_iss_uop_t               uop_iq [IQ_NUM],
  output logic [CPLT_MASK_W-1:0]     expect_mask  // ROB completion groups this instruction waits for
);

  logic         amo_swap;
  logic         amo_rmw;   // AMO that is neither LR nor SC

  always_comb begin
    amo_swap = (base.func7[6:2] == AMO_SWAP);
    amo_rmw  = cls.is_amo && (base.func7[6:2] != AMO_LR) && !cls.is_amo_sc;
    has_iq[IQ_INT] = cls.to_int && !me_elim;
    has_iq[IQ_LD]  = cls.is_load;
    has_iq[IQ_STA] = cls.is_store;
    has_iq[IQ_STD] = cls.is_store;
    has_iq[IQ_BR]  = cls.to_br;
  end

  // ---- IQ_INT: ALU-class ops, CSR/system ops, and the pc+4 half of JAL/JALR ----
  always_comb begin
    uop_iq[IQ_INT] = base;
    case (itype)
      INST_MUL:        uop_iq[IQ_INT].op = UOP_MUL;
      INST_DIV:        uop_iq[IQ_INT].op = UOP_DIV;
      INST_FP:         uop_iq[IQ_INT].op = UOP_FP;
      INST_CSR:        uop_iq[IQ_INT].op = UOP_CSR;
      INST_FENCE:      uop_iq[IQ_INT].op = UOP_FENCE;
      INST_ECALL:      uop_iq[IQ_INT].op = UOP_ECALL;
      INST_MRET:       uop_iq[IQ_INT].op = UOP_MRET;
      INST_SRET:       uop_iq[IQ_INT].op = UOP_SRET;
      INST_SFENCE_VMA: uop_iq[IQ_INT].op = UOP_SFENCE_VMA;
      INST_FENCE_I:    uop_iq[IQ_INT].op = UOP_FENCE_I;
      INST_EBREAK:     uop_iq[IQ_INT].op = UOP_EBREAK;
      INST_WFI:        uop_iq[IQ_INT].op = UOP_WFI;
      INST_JAL, INST_JALR: begin
        uop_iq[IQ_INT].op      = UOP_ADD;
        uop_iq[IQ_INT].imm     = 32'd4;
        uop_iq[IQ_INT].src1_en = 1'b0;
        uop_iq[IQ_INT].src2_en = 1'b0;
      end
      default: uop_iq[IQ_INT].op = UOP_ADD;   // ADD and NOP
    endcase
  end

  // ---- IQ_LD: LOAD, AMO.LR, load half of AMO.rmw ----
  always_comb begin
    uop_iq[IQ_LD] = base;
    uop_iq[IQ_LD].op = UOP_LOAD;
    if (cls.is_amo) uop_iq[IQ_LD].src2_en = 1'b0;
  end

  // ---- IQ_STA: address half of STORE / AMO.SC / AMO.rmw ----
  always_comb begin
    uop_iq[IQ_STA] = base;
    uop_iq[IQ_STA].op = UOP_STA;
    uop_iq[IQ_STA].src2_en = 1'b0;                       // address uses src1 only
    if (cls.is_amo) uop_iq[IQ_STA].dest_en = cls.is_amo_sc;  // SC returns its 0/1 on the STA writeback
  end

  // ---- IQ_STD: data half of STORE / AMO.SC / AMO.rmw ----
  always_comb begin
    uop_iq[IQ_STD] = base;
    uop_iq[IQ_STD].op = UOP_STD;
    if (cls.is_amo) begin
      uop_iq[IQ_STD].is_atomic = 1'b1;
      uop_iq[IQ_STD].dest_en   = 1'b0;
    end
    if (itype == INST_STORE) begin
      uop_iq[IQ_STD].src1_en = 1'b0;
      uop_iq[IQ_STD].src2_en = 1'b1;
    end
    if (cls.is_amo_sc) begin
      uop_iq[IQ_STD].src1_en = 1'b0;
    end
    if (amo_rmw) begin   // data uop waits for the loaded old value (not for SWAP)
      uop_iq[IQ_STD].src1_preg = base.dest_preg;
      uop_iq[IQ_STD].src1_busy = !amo_swap;
    end
  end

  // ---- IQ_BR: conditional branch, or the jump half of JAL/JALR ----
  always_comb begin
    uop_iq[IQ_BR] = base;
    uop_iq[IQ_BR].op = UOP_BR;
    if (itype == INST_JAL || itype == INST_JALR) begin
      uop_iq[IQ_BR].op      = UOP_JUMP;
      uop_iq[IQ_BR].dest_en = 1'b0;
      if (itype == INST_JALR) uop_iq[IQ_BR].src1_en = 1'b1;
    end
  end

  // ---- ROB completion groups: INT/LD -> G0, BR/STA -> G1, STD -> G2; SC completes G0 (result) + G2 ----
  always_comb begin
    expect_mask = '0;
    if (has_iq[IQ_INT] || has_iq[IQ_LD]) expect_mask = expect_mask | CPLT_G0;
    if (has_iq[IQ_BR] || has_iq[IQ_STA]) expect_mask = expect_mask | CPLT_G1;
    if (has_iq[IQ_STD])                  expect_mask = expect_mask | CPLT_G2;
    if (cls.is_amo_sc)                   expect_mask = CPLT_G0 | CPLT_G2;
  end

endmodule

`default_nettype wire
