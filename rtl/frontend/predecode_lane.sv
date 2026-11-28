// Ref: front-end/predecode.cpp  predecode_comb (one lane); back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (br_type)
`default_nettype none

// Control-flow decode of one 32-bit instruction word (the only branch decoder of the front end).
//   kind (bpu_pkg BR_*): beq..bgeu = DIRECT, jal rd=ra = CALL, other jal = JAL, jalr x0,ra,0 = RET, other jalr rd=ra =
//   ICALL, other jalr = IDIRECT, everything else = NONCTL (the same rules the back end applies to a committed branch).
//   target: pc + the J-type / B-type immediate for jal / conditional branches, 0 otherwise (jalr has no direct target).
// The predecode type of the checker (front_pkg PREDECODE_*) and the call / return of front_pd_info derive from kind.
module predecode_lane import ttg_cfg_pkg::*; import front_pkg::*; import bpu_pkg::*; (
  input  logic [XLEN_BITS-1:0] pc,
  input  logic [31:0]          inst,
  output logic [KIND_W-1:0]    kind,
  output logic [XLEN_BITS-1:0] target
);

  logic        is_jal, is_branch, is_jalr, rd_ra, is_ret;
  logic [31:0] imm_sel;

  always_comb begin
    is_jal    = (inst[6:0] == OPCODE_JAL);
    is_branch = (inst[6:0] == OPCODE_BRANCH);
    is_jalr   = (inst[6:0] == OPCODE_JALR);
    rd_ra     = (inst[11:7] == 5'd1);
    is_ret    = (inst[19:15] == 5'd1) && (inst[11:7] == 5'd0) && (inst[31:20] == 12'd0);
    kind      = BR_NONCTL;
    if (is_branch) kind = BR_DIRECT;
    if (is_jal)    kind = rd_ra ? BR_CALL : BR_JAL;
    if (is_jalr)   kind = is_ret ? BR_RET : rd_ra ? BR_ICALL : BR_IDIRECT;
    // J-type immediate {imm20, imm19:12, imm11, imm10:1, 0} / B-type {imm12, imm11, imm10:5, imm4:1, 0}, sign-extended
    imm_sel = ({32{is_jal}}    & {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0}) |
              ({32{is_branch}} & {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0});
    target  = (is_jal || is_branch) ? (pc + XLEN_BITS'($signed(imm_sel))) : '0;
  end

endmodule

`default_nettype wire
