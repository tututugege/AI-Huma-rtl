// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (BPA_REPAIR br_type), core_back2front class_br_type
`default_nettype none

// BPU branch type of one instruction word, decided from the instruction bits (the same rules the back end applies to a
// committed branch): beq..bgeu = conditional, jal rd=ra = call, other jal = jal, jalr x0,ra,0 = return, jalr rd=ra =
// indirect call, other jalr = indirect, everything else = not a control instruction.  Stored per slot with the fetch
// group so that the back end can hand it back with a mispredict.
module front_slot_kind import front_pkg::*; import bpu_pkg::*; (
  /* verilator lint_off UNUSEDSIGNAL */   // only opcode, rd, rs1 and the 12-bit immediate decide the type
  input  logic [31:0]          inst,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [KIND_W-1:0]    kind
);

  logic is_ret;

  always_comb begin
    is_ret = (inst[19:15] == 5'd1) && (inst[11:7] == 5'd0) && (inst[31:20] == 12'd0);
    kind   = BR_NONCTL;
    case (inst[6:0])
      OPCODE_BRANCH: kind = BR_DIRECT;
      OPCODE_JAL:    kind = (inst[11:7] == 5'd1) ? BR_CALL : BR_JAL;
      OPCODE_JALR:   kind = is_ret ? BR_RET : (inst[11:7] == 5'd1) ? BR_ICALL : BR_IDIRECT;
      default:       kind = BR_NONCTL;
    endcase
  end

endmodule

`default_nettype wire
