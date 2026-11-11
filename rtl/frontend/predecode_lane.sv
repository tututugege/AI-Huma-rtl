// Ref: front-end/predecode.cpp  predecode_comb (one lane)
`default_nettype none

// Predecode of one fetch-group lane: classify the instruction as jal / conditional branch / jalr / other and, for jal
// and branches, compute the direct target pc + imm.  An invalid lane (past the end of the fetch group) gives
// NON_BRANCH / 0 (front_top.cpp:1631-1634).
module predecode_lane import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic [XLEN_BITS-1:0] pc,
  input  logic [31:0] inst,
  input  logic        inst_valid,
  output logic [1:0]  predecode_type,
  output logic [XLEN_BITS-1:0] predecode_target_address
);

  logic [6:0]  opcode;
  logic        is_jal;
  logic        is_branch;
  logic        is_jalr;
  logic [31:0] imm_jal;
  logic [31:0] imm_branch;
  logic [31:0] imm_sel;

  assign opcode    = inst[6:0];
  assign is_jal    = inst_valid && (opcode == OPCODE_JAL);
  assign is_branch = inst_valid && (opcode == OPCODE_BRANCH);
  assign is_jalr   = inst_valid && (opcode == OPCODE_JALR);

  // J-type immediate, sign-extended 21 bits: {imm20, imm19:12, imm11, imm10:1, 0}
  assign imm_jal    = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};
  // B-type immediate, sign-extended 13 bits: {imm12, imm11, imm10:5, imm4:1, 0}
  assign imm_branch = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};

  always_comb begin
    imm_sel        = ({32{is_jal}} & imm_jal) | ({32{is_branch}} & imm_branch);
    predecode_type = PREDECODE_NON_BRANCH;
    if (is_jal)    predecode_type = PREDECODE_JAL;
    if (is_branch) predecode_type = PREDECODE_DIRECT_JUMP_NO_JAL;
    if (is_jalr)   predecode_type = PREDECODE_JALR;
    // jalr has no direct target (0); non-branch lanes have 0
    predecode_target_address = (is_jal || is_branch) ? (pc + XLEN_BITS'($signed(imm_sel))) : '0;
  end

endmodule

`default_nettype wire
