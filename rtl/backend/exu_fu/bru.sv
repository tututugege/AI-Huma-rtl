// Ref: back-end/Exu/include/Fu.h  BruUnit
`default_nettype none

// Branch unit: condition, target, taken/mispredict verdict against the FTQ prediction.  The unit's `result` is never
// written by the C++ (stays 0), so there is no result port.  The mispredict rule is the
// real (non-oracle) comparison against the FTQ prediction.  The BRU port only sees UOP_BR / UOP_JUMP (OP_MASK_BR).
module bru
  import exu_fu_pkg::*;
  import ttg_cfg_pkg::*;
(
  input  logic            en,
  input  logic            consume,
  input  logic [OP_W-1:0] op,
  input  logic [2:0]      func3,
  input  logic            src1_en,
  input  logic [XLEN_BITS-1:0]     src1_rdata,
  input  logic [XLEN_BITS-1:0]     src2_rdata,
  input  logic [XLEN_BITS-1:0]     pc,
  input  logic [31:0]     imm,
  input  logic            ftq_pred_taken,
  input  logic [XLEN_BITS-1:0]     ftq_next_pc,
  output logic            complete,
  output logic            ready,
  output logic            br_taken,
  output logic            mispred,
  output logic [XLEN_BITS-1:0]     diag_val
);

  exu_fu_sc_ctl u_ctl (.en(en), .consume(consume), .complete(complete), .ready(ready));

  logic        is_br, is_jump, cond_eq, cond_lt_s, cond_lt_u, cond_taken;
  logic [XLEN_BITS-1:0] pc_plus4, target, imm_x;
  assign imm_x = XLEN_BITS'($signed(imm));

  // Ref: BruUnit::impl_compute  (condition of a conditional branch)
  always_comb begin
    is_br     = (op == UOP_BR);
    is_jump   = (op == UOP_JUMP);
    cond_eq   = (src1_rdata == src2_rdata);
    cond_lt_s = $signed(src1_rdata) < $signed(src2_rdata);  // BLT/BGE compare as signed
    cond_lt_u = src1_rdata < src2_rdata;
    case (func3)
      3'b000:  cond_taken = cond_eq;
      3'b001:  cond_taken = !cond_eq;
      3'b100:  cond_taken = cond_lt_s;
      3'b101:  cond_taken = !cond_lt_s;
      3'b110:  cond_taken = cond_lt_u;
      3'b111:  cond_taken = !cond_lt_u;
      default: cond_taken = 1'b1;   // func3 = 2/3 are not branch encodings; the C++ keeps its initial "taken"
    endcase
  end

  // Ref: BruUnit::impl_compute  (target, taken, verdict)
  always_comb begin
    pc_plus4 = pc + XLEN_BITS'(4);
    // JALR (src1_en) targets (rs1 + imm) with bit 0 cleared; JAL and conditional branches are pc-relative
    target   = (is_jump && src1_en) ? ((src1_rdata + imm_x) & ~XLEN_BITS'(1)) : (pc + imm_x);
    br_taken = is_jump || (is_br && cond_taken);
    diag_val = br_taken ? target : pc_plus4;
    // correct prediction = predicted taken to the right target, or predicted not-taken and not taken
    mispred  = br_taken ? !(ftq_pred_taken && (ftq_next_pc == target)) : ftq_pred_taken;
  end

endmodule

`default_nettype wire
