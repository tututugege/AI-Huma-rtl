// Ref: back-end/Idu.cpp  class Idu::decode (immediate generation: immU/immJ/immI/immB/immS macros)
`default_nettype none

// Builds all RISC-V immediate formats from the instruction word and picks one with the one-hot select.
module idu_imm_gen (
  input  logic [31:2] inst,      // bits [1:0] are always 11; only the F/D format uses the opcode bits [6:2]
  input  logic [6:0]  imm_sel,    // one-hot or none: U, J, I, B, S, CSR rs1 field, F/D instruction bits
  output logic [31:0] imm
);

  logic [31:0] imm_u, imm_j, imm_i, imm_b, imm_s, imm_csr, imm_fp;
  logic [31:0] imm_cand [7];

  always_comb begin
    imm_u   = {inst[31:12], 12'd0};
    imm_j   = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};
    imm_i   = {{20{inst[31]}}, inst[31:20]};
    imm_b   = {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};
    imm_s   = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    imm_csr = {27'd0, inst[19:15]};
    imm_fp  = {15'd0, inst[6:2], inst[31:20]};   // which FP opcode, and funct7 | rs2 (the FP units decode them)
    imm_cand[0] = imm_u;
    imm_cand[1] = imm_j;
    imm_cand[2] = imm_i;
    imm_cand[3] = imm_b;
    imm_cand[4] = imm_s;
    imm_cand[5] = imm_csr;
    imm_cand[6] = imm_fp;
  end

  ttg_onehot_mux #(.N(7), .W(32)) u_imm_mux (.sel(imm_sel), .data(imm_cand), .out(imm));

endmodule

`default_nettype wire
