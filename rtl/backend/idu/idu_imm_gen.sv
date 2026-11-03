// Ref: back-end/Idu.cpp  class Idu::decode (immediate generation: immU/immJ/immI/immB/immS macros)
`default_nettype none

// Builds all RISC-V immediate formats from the instruction word and picks one with the one-hot select.
module idu_imm_gen (
  input  logic [31:7] inst,      // opcode bits [6:0] do not take part in any immediate
  input  logic [6:0]  imm_sel,    // one-hot or none: U, J, I, B, S, CSR rs1 field, FP rs2 field
  output logic [31:0] imm
);

  logic [31:0] imm_u, imm_j, imm_i, imm_b, imm_s, imm_csr, imm_rs2;
  logic [31:0] imm_cand [7];

  always_comb begin
    imm_u   = {inst[31:12], 12'd0};
    imm_j   = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};
    imm_i   = {{20{inst[31]}}, inst[31:20]};
    imm_b   = {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};
    imm_s   = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    imm_csr = {27'd0, inst[19:15]};
    imm_rs2 = {27'd0, inst[24:20]};
    imm_cand[0] = imm_u;
    imm_cand[1] = imm_j;
    imm_cand[2] = imm_i;
    imm_cand[3] = imm_b;
    imm_cand[4] = imm_s;
    imm_cand[5] = imm_csr;
    imm_cand[6] = imm_rs2;
  end

  ttg_onehot_mux #(.N(7), .W(32)) u_imm_mux (.sel(imm_sel), .data(imm_cand), .out(imm));

endmodule

`default_nettype wire
