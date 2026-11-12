// Ref: back-end/Idu.cpp  class Idu::decode (control part: type / enables / func3 / areg fields)
`default_nettype none

// Instruction -> control word. The opcode/funct fields are first classified into ONE mutually exclusive class
// (one-hot, NCLS bits); every control bit is then a lookup in a constant table indexed by that class (AND-OR mux).
// The C++ `switch (opcode)` + nested if/else chains become: class one-hot (below) + ROM (further below).
module idu_ctrl_decode import ttg_cfg_pkg::*; (
  input  logic [31:0] inst,
  output logic [4:0]  uop_type,
  output logic        dest_en,
  output logic        src1_en,
  output logic        src2_en,
  output logic        src1_is_pc,
  output logic        src2_is_imm,
  output logic        is_word,           // rv64 OP-IMM-32 / OP-32: 32-bit operation, result sign-extended
  output logic        is_atomic,
  output logic [2:0]  func3,
  output logic [5:0]  dest_areg,
  output logic [5:0]  src1_areg,
  output logic [5:0]  src2_areg,
  output logic        illegal_inst,
  output logic        is_branch,
  output logic [5:0]  imm_sel,           // one-hot (or none): U, J, I, B, S, CSR-rs1-field
  // F/D (all zero when the core has no FP register file, FPRF_NUM == 0)
  output logic        dest_fp,           // FP register destination (f0 is a real register)
  output logic        src1_fp,
  output logic        src2_fp,
  output logic        src3_en,           // fused multiply-add: third FP source in src3_areg
  output logic [4:0]  src3_areg,
  output logic [2:0]  fp_cls             // unit class: FPC_*
);

  // ---- InstType encoding (Ref: back-end/include/types.h enum InstType) ----
  localparam logic [4:0] T_NOP = 5'd0, T_JAL = 5'd1, T_JALR = 5'd2, T_ADD = 5'd3, T_BR = 5'd4, T_LOAD = 5'd5,
                         T_STORE = 5'd6, T_CSR = 5'd7, T_FENCE = 5'd8, T_ECALL = 5'd9, T_EBREAK = 5'd10,
                         T_WFI = 5'd11, T_SFENCE_VMA = 5'd12, T_FENCE_I = 5'd13, T_MRET = 5'd14,
                         T_SRET = 5'd15, T_MUL = 5'd16, T_DIV = 5'd17, T_AMO = 5'd18, T_FPOP = 5'd19;
  // FpCls (Ref: base_types.h)
  localparam logic [2:0] FPC_NONE = 3'd0, FPC_FMA = 3'd1, FPC_FDIV = 3'd2, FPC_MISC = 3'd3, FPC_I2F = 3'd4;

  // ---- major opcodes (Ref: include/RISCV.h enum_number_opcode) ----
  localparam logic [6:0] OPC_LUI = 7'b0110111, OPC_AUIPC = 7'b0010111, OPC_JAL = 7'b1101111,
                         OPC_JALR = 7'b1100111, OPC_BRANCH = 7'b1100011, OPC_LOAD = 7'b0000011,
                         OPC_STORE = 7'b0100011, OPC_OPIMM = 7'b0010011, OPC_OP = 7'b0110011,
                         OPC_FENCE = 7'b0001111, OPC_SYSTEM = 7'b1110011, OPC_AMO = 7'b0101111,
                         OPC_OPIMM32 = 7'b0011011, OPC_OP32 = 7'b0111011,
                         OPC_LOAD_FP = 7'b0000111, OPC_STORE_FP = 7'b0100111, OPC_FMADD = 7'b1000011,
                         OPC_FMSUB = 7'b1000111, OPC_FNMSUB = 7'b1001011, OPC_FNMADD = 7'b1001111,
                         OPC_OP_FP = 7'b1010011;

  // exact encodings (Ref: include/RISCV.h INST_*)
  localparam logic [31:0] INST_ECALL = 32'h00000073, INST_EBREAK = 32'h00100073, INST_MRET = 32'h30200073,
                          INST_SRET = 32'h10200073, INST_WFI = 32'h10500073;
  localparam logic [4:0] AMO_LR = 5'b00010, AMO_SC = 5'b00011;   // funct7[6:2]

  // CSR addresses implemented by the reference CSR file (Ref: Exu/include/Csr.h enum_number_csr_code, 21 entries)
  localparam int NUM_KNOWN_CSR = 21;
  localparam logic [11:0] KNOWN_CSR [NUM_KNOWN_CSR] = '{
    12'h305, 12'h341, 12'h342, 12'h304, 12'h344, 12'h343, 12'h340, 12'h300, 12'h303, 12'h302, 12'h141,
    12'h105, 12'h142, 12'h140, 12'h143, 12'h100, 12'h104, 12'h144, 12'h180, 12'hf14, 12'h301};
  // fflags / frm / fcsr: executed by the function model, no timing effect here; every other CSR outside KNOWN_CSR traps
  localparam logic [11:0] CSR_FFLAGS = 12'h001, CSR_FCSR = 12'h003;

  // ---- classes (index into the one-hot `cls` and into ROM) ----
  localparam int CLS_LUI = 0, CLS_AUIPC = 1, CLS_JAL = 2, CLS_JALR = 3, CLS_BR = 4, CLS_LOAD = 5, CLS_STORE = 6,
                 CLS_OPIMM = 7, CLS_OP_ALU = 8, CLS_OP_MUL = 9, CLS_OP_DIV = 10, CLS_FENCE = 11, CLS_FENCE_I = 12,
                 CLS_CSR = 13, CLS_CSR_NOP = 14, CLS_ECALL = 15, CLS_EBREAK = 16, CLS_MRET = 17, CLS_WFI = 18,
                 CLS_SRET = 19, CLS_SFENCE = 20, CLS_SYS_NOP = 21, CLS_AMO = 22, CLS_AMO_LR = 23,
                 CLS_OPIMM32 = 24, CLS_OP32_ALU = 25, CLS_OP32_MUL = 26, CLS_OP32_DIV = 27,
                 CLS_FLOAD = 28, CLS_FSTORE = 29, CLS_FMA3 = 30, CLS_FP_FMA = 31, CLS_FP_FDIV = 32, CLS_FP_FSQRT = 33,
                 CLS_FP_MISC2 = 34, CLS_FP_MISC1 = 35, CLS_FP_CMP = 36, CLS_FP_TOINT = 37, CLS_FP_I2F = 38,
                 CLS_ILLEGAL = 39, NCLS = 40;

  // ---- ROM word: {type[4:0], dest_en, src1_en, src2_en, src1_is_pc, src2_is_imm, is_atomic, func3_zero,
  //                  src1_areg_zero, illegal, is_branch, imm_sel[5:0]} ----
  localparam int ROMW = 21;
  localparam logic [5:0] IMM_NONE = 6'b000000, IMM_U = 6'b000001, IMM_J = 6'b000010, IMM_I = 6'b000100,
                         IMM_B = 6'b001000, IMM_S = 6'b010000, IMM_CSR = 6'b100000;

  //                                   type  dst s1 s2 s1pc s2imm atom f3z s1z ill br   imm
  function automatic logic [ROMW-1:0] row(input logic [4:0] ty, input logic dst, input logic s1,
      input logic s2, input logic s1pc, input logic s2imm, input logic atom, input logic f3z,
      input logic s1z, input logic ill, input logic br, input logic [5:0] imm);
    return {ty, dst, s1, s2, s1pc, s2imm, atom, f3z, s1z, ill, br, imm};
  endfunction

  localparam logic [ROMW-1:0] ROM [NCLS] = '{
    CLS_LUI:      row(T_ADD,        1, 1, 0, 0, 1, 0, 1, 1, 0, 0, IMM_U),
    CLS_AUIPC:    row(T_ADD,        1, 0, 0, 1, 1, 0, 1, 0, 0, 0, IMM_U),
    CLS_JAL:      row(T_JAL,        1, 0, 0, 1, 1, 0, 1, 0, 0, 0, IMM_J),
    CLS_JALR:     row(T_JALR,       1, 1, 0, 1, 1, 0, 1, 0, 0, 1, IMM_I),
    CLS_BR:       row(T_BR,         0, 1, 1, 0, 1, 0, 0, 0, 0, 1, IMM_B),
    CLS_LOAD:     row(T_LOAD,       1, 1, 0, 0, 1, 0, 0, 0, 0, 0, IMM_I),
    CLS_STORE:    row(T_STORE,      0, 1, 1, 0, 1, 0, 0, 0, 0, 0, IMM_S),
    CLS_OPIMM:    row(T_ADD,        1, 1, 0, 0, 1, 0, 0, 0, 0, 0, IMM_I),
    CLS_OP_ALU:   row(T_ADD,        1, 1, 1, 0, 0, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_OP_MUL:   row(T_MUL,        1, 1, 1, 0, 0, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_OP_DIV:   row(T_DIV,        1, 1, 1, 0, 0, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_FENCE:    row(T_FENCE,      0, 0, 0, 0, 1, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_FENCE_I:  row(T_FENCE_I,    0, 0, 0, 0, 1, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_CSR:      row(T_CSR,        1, 1, 1, 0, 1, 0, 0, 0, 0, 0, IMM_CSR),
    CLS_CSR_NOP:  row(T_NOP,        0, 0, 0, 0, 1, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_ECALL:    row(T_ECALL,      0, 0, 0, 0, 1, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_EBREAK:   row(T_EBREAK,     0, 0, 0, 0, 1, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_MRET:     row(T_MRET,       0, 0, 0, 0, 1, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_WFI:      row(T_WFI,        0, 0, 0, 0, 1, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_SRET:     row(T_SRET,       0, 0, 0, 0, 1, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_SFENCE:   row(T_SFENCE_VMA, 0, 1, 1, 0, 1, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_SYS_NOP:  row(T_NOP,        0, 0, 0, 0, 1, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_AMO:      row(T_AMO,        1, 1, 1, 0, 1, 1, 0, 0, 0, 0, IMM_NONE),
    CLS_AMO_LR:   row(T_AMO,        1, 1, 0, 0, 1, 1, 0, 0, 0, 0, IMM_NONE),
    CLS_OPIMM32:  row(T_ADD,        1, 1, 0, 0, 1, 0, 0, 0, 0, 0, IMM_I),
    CLS_OP32_ALU: row(T_ADD,        1, 1, 1, 0, 0, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_OP32_MUL: row(T_MUL,        1, 1, 1, 0, 0, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_OP32_DIV: row(T_DIV,        1, 1, 1, 0, 0, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_FLOAD:    row(T_LOAD,       1, 1, 0, 0, 1, 0, 0, 0, 0, 0, IMM_I),
    CLS_FSTORE:   row(T_STORE,      0, 1, 1, 0, 1, 0, 0, 0, 0, 0, IMM_S),
    CLS_FMA3:     row(T_FPOP,       1, 1, 1, 0, 0, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_FP_FMA:   row(T_FPOP,       1, 1, 1, 0, 0, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_FP_FDIV:  row(T_FPOP,       1, 1, 1, 0, 0, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_FP_FSQRT: row(T_FPOP,       1, 1, 0, 0, 0, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_FP_MISC2: row(T_FPOP,       1, 1, 1, 0, 0, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_FP_MISC1: row(T_FPOP,       1, 1, 0, 0, 0, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_FP_CMP:   row(T_FPOP,       1, 1, 1, 0, 0, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_FP_TOINT: row(T_FPOP,       1, 1, 0, 0, 0, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_FP_I2F:   row(T_FPOP,       1, 1, 0, 0, 0, 0, 0, 0, 0, 0, IMM_NONE),
    CLS_ILLEGAL:  row(T_NOP,        0, 0, 0, 0, 1, 0, 0, 0, 1, 0, IMM_NONE)};

  // ---- F/D side table: {dest_fp, src1_fp, src2_fp, src3_en, fp_cls[2:0]} per class (Ref: Idu::decode) ----
  localparam int FROMW = 7;
  function automatic logic [FROMW-1:0] frow(input logic d, input logic s1, input logic s2, input logic s3,
                                            input logic [2:0] c);
    return {d, s1, s2, s3, c};
  endfunction
  localparam logic [FROMW-1:0] FROM [NCLS] = '{
    CLS_FLOAD:    frow(1, 0, 0, 0, FPC_NONE),
    CLS_FSTORE:   frow(0, 0, 1, 0, FPC_NONE),
    CLS_FMA3:     frow(1, 1, 1, 1, FPC_FMA),
    CLS_FP_FMA:   frow(1, 1, 1, 0, FPC_FMA),
    CLS_FP_FDIV:  frow(1, 1, 1, 0, FPC_FDIV),
    CLS_FP_FSQRT: frow(1, 1, 0, 0, FPC_FDIV),
    CLS_FP_MISC2: frow(1, 1, 1, 0, FPC_MISC),
    CLS_FP_MISC1: frow(1, 1, 0, 0, FPC_MISC),
    CLS_FP_CMP:   frow(0, 1, 1, 0, FPC_MISC),
    CLS_FP_TOINT: frow(0, 1, 0, 0, FPC_MISC),
    CLS_FP_I2F:   frow(1, 0, 0, 0, FPC_I2F),
    default:      frow(0, 0, 0, 0, FPC_NONE)};

  // ---- instruction fields ----
  logic [6:0]  opcode;
  logic [2:0]  funct3;
  logic [6:0]  funct7;
  logic [4:0]  rd_idx, rs1_idx;
  logic [11:0] csr_idx;
  logic [4:0]  amo_op;

  always_comb begin
    opcode  = inst[6:0];
    funct3  = inst[14:12];
    funct7  = inst[31:25];
    rd_idx  = inst[11:7];
    rs1_idx = inst[19:15];
    csr_idx = inst[31:20];
    amo_op  = inst[31:27];
  end

  logic op_system;
  assign op_system   = (opcode == OPC_SYSTEM);

  // ---- SYSTEM opcode sub-decode ----
  logic [NUM_KNOWN_CSR-1:0] csr_hit;
  logic csr_known, csr_form, csr_imm_form, sys_csr, sys_plain, csr_illegal;
  logic is_ecall, is_ebreak, is_mret, is_wfi, is_sret, is_sfence;

  for (genvar c = 0; c < NUM_KNOWN_CSR; c++) begin : g_csr_hit
    assign csr_hit[c] = (csr_idx == KNOWN_CSR[c]);
  end

  assign csr_known    = |csr_hit;
  assign csr_form     = funct3[0] | funct3[1];                 // csrrw/s/c(i); funct3 = 000/100 is non-CSR
  assign csr_imm_form = funct3[2] & csr_form;                  // csrrwi/si/ci
  assign csr_illegal  = (csr_idx < CSR_FFLAGS) | (csr_idx > CSR_FCSR);   // the CSR_NOP class holds only unknown CSRs
  assign sys_csr      = op_system & csr_form;
  assign sys_plain    = op_system & ~csr_form;
  assign is_ecall     = (inst == INST_ECALL);
  assign is_ebreak    = (inst == INST_EBREAK);
  assign is_mret      = (inst == INST_MRET);
  assign is_wfi       = (inst == INST_WFI);
  assign is_sret      = (inst == INST_SRET);
  assign is_sfence    = (funct7 == 7'b0001001) & (funct3 == 3'b000) & (rd_idx == 5'd0);

  // ---- class one-hot (mutually exclusive by construction; SYSTEM encodings differ in funct7/imm) ----
  logic [NCLS-1:0] cls;

  assign cls[CLS_LUI]      = (opcode == OPC_LUI);
  assign cls[CLS_AUIPC]    = (opcode == OPC_AUIPC);
  assign cls[CLS_JAL]      = (opcode == OPC_JAL);
  assign cls[CLS_JALR]     = (opcode == OPC_JALR);
  assign cls[CLS_BR]       = (opcode == OPC_BRANCH);
  assign cls[CLS_LOAD]     = (opcode == OPC_LOAD);
  assign cls[CLS_STORE]    = (opcode == OPC_STORE);
  assign cls[CLS_OPIMM]    = (opcode == OPC_OPIMM);
  assign cls[CLS_OP_ALU]   = (opcode == OPC_OP) & (funct7 != 7'd1);
  assign cls[CLS_OP_MUL]   = (opcode == OPC_OP) & (funct7 == 7'd1) & ~funct3[2];
  assign cls[CLS_OP_DIV]   = (opcode == OPC_OP) & (funct7 == 7'd1) & funct3[2];
  assign cls[CLS_FENCE]    = (opcode == OPC_FENCE) & (funct3 != 3'b001);
  assign cls[CLS_FENCE_I]  = (opcode == OPC_FENCE) & (funct3 == 3'b001);
  assign cls[CLS_CSR]      = sys_csr & csr_known;
  assign cls[CLS_CSR_NOP]  = sys_csr & ~csr_known;
  assign cls[CLS_ECALL]    = sys_plain & is_ecall;
  assign cls[CLS_EBREAK]   = sys_plain & is_ebreak;
  assign cls[CLS_MRET]     = sys_plain & is_mret;
  assign cls[CLS_WFI]      = sys_plain & is_wfi;
  assign cls[CLS_SRET]     = sys_plain & is_sret;
  assign cls[CLS_SFENCE]   = sys_plain & is_sfence;
  assign cls[CLS_SYS_NOP]  = sys_plain & ~(is_ecall | is_ebreak | is_mret | is_wfi | is_sret | is_sfence);
  assign cls[CLS_AMO]      = (opcode == OPC_AMO) & (amo_op != AMO_LR);
  assign cls[CLS_AMO_LR]   = (opcode == OPC_AMO) & (amo_op == AMO_LR);
  // rv32: Zfinx FP in the OP-FP opcode; rv64: no F/D yet (OP-FP is illegal), 32-bit ops in OP-IMM-32 / OP-32
  localparam bit RV64 = (XLEN_BITS == 64);
  assign cls[CLS_OPIMM32]  = RV64 & (opcode == OPC_OPIMM32);
  assign cls[CLS_OP32_ALU] = RV64 & (opcode == OPC_OP32) & (funct7 != 7'd1);
  assign cls[CLS_OP32_MUL] = RV64 & (opcode == OPC_OP32) & (funct7 == 7'd1) & ~funct3[2];
  assign cls[CLS_OP32_DIV] = RV64 & (opcode == OPC_OP32) & (funct7 == 7'd1) & funct3[2];
  // F/D (Ref: Idu::decode): fmt = funct7[1:0] (0 = S, 1 = D, rest reserved); the class comes from funct5 = funct7[6:2]
  localparam bit HAS_FP = (FPRF_NUM != 0);
  logic fmt_ok, fp_width_ok, op_fp;
  logic [4:0] f5;
  assign f5          = funct7[6:2];
  assign fmt_ok      = ~funct7[1];
  assign fp_width_ok = (funct3 == 3'd2) | (funct3 == 3'd3);   // flw / fld / fsw / fsd
  assign op_fp       = HAS_FP & (opcode == OPC_OP_FP) & fmt_ok;
  assign cls[CLS_FLOAD]    = HAS_FP & (opcode == OPC_LOAD_FP) & fp_width_ok;
  assign cls[CLS_FSTORE]   = HAS_FP & (opcode == OPC_STORE_FP) & fp_width_ok;
  assign cls[CLS_FMA3]     = HAS_FP & ((opcode == OPC_FMADD) | (opcode == OPC_FMSUB) | (opcode == OPC_FNMSUB) |
                                       (opcode == OPC_FNMADD)) & fmt_ok;
  assign cls[CLS_FP_FMA]   = op_fp & (f5 <= 5'd2);                              // fadd fsub fmul
  assign cls[CLS_FP_FDIV]  = op_fp & (f5 == 5'd3);
  assign cls[CLS_FP_FSQRT] = op_fp & (f5 == 5'h0b);
  assign cls[CLS_FP_MISC2] = op_fp & ((f5 == 5'd4) | (f5 == 5'd5));             // fsgnj*, fmin / fmax
  assign cls[CLS_FP_MISC1] = op_fp & (f5 == 5'd8);                              // fcvt.s.d / fcvt.d.s
  assign cls[CLS_FP_CMP]   = op_fp & (f5 == 5'h14);                             // feq / flt / fle
  assign cls[CLS_FP_TOINT] = op_fp & ((f5 == 5'h18) | (f5 == 5'h1c));           // fcvt.int.fmt, fmv.x.*, fclass
  assign cls[CLS_FP_I2F]   = op_fp & ((f5 == 5'h1a) | (f5 == 5'h1e));           // fcvt.fmt.int, fmv.*.x
  assign cls[CLS_ILLEGAL]  = ~|cls[NCLS-2:0];   // opcode not listed above

  // ---- table lookup ----
  logic [ROMW-1:0] rom_word;
  logic [FROMW-1:0] from_word;
  logic rom_dest_en, rom_src2_en, rom_src2_is_imm, rom_func3_zero, rom_src1_zero, rom_illegal;

  ttg_onehot_mux #(.N(NCLS), .W(ROMW)) u_rom_mux (.sel(cls), .data(ROM), .out(rom_word));
  ttg_onehot_mux #(.N(NCLS), .W(FROMW)) u_from_mux (.sel(cls), .data(FROM), .out(from_word));

  // ---- outputs (Ref: tail of Idu::decode: AMO rd==0 rename, dest_areg==0 kills dest_en, load/store flags) ----
  logic amo_rd_x0_rename;

  always_comb begin
    {uop_type, rom_dest_en, src1_en, rom_src2_en, src1_is_pc, rom_src2_is_imm, is_atomic, rom_func3_zero,
     rom_src1_zero, rom_illegal, is_branch, imm_sel} = rom_word;
    // SYSTEM opcode overrides src2_is_imm with "CSR immediate form" and masks src2_en of csrrwi/si/ci
    src2_is_imm = op_system ? csr_imm_form : rom_src2_is_imm;
    is_word     = cls[CLS_OPIMM32] | cls[CLS_OP32_ALU] | cls[CLS_OP32_MUL] | cls[CLS_OP32_DIV];
    src2_en     = rom_src2_en & ~(op_system & csr_imm_form);
    func3       = rom_func3_zero ? 3'd0 : funct3;
    // AMO (not LR/SC) with rd == x0 writes pseudo areg 32 (keeps dest_en); everything else keeps rd
    amo_rd_x0_rename = cls[CLS_AMO] & (rd_idx == 5'd0) & (amo_op != AMO_SC);
    dest_areg    = amo_rd_x0_rename ? 6'd32 : {1'b0, rd_idx};
    {dest_fp, src1_fp, src2_fp, src3_en, fp_cls} = from_word;
    src3_areg    = inst[31:27] & {5{src3_en}};
    dest_en      = rom_dest_en & ((dest_areg != 6'd0) | dest_fp);   // x0 is not written, f0 is a register
    src1_areg    = rom_src1_zero ? 6'd0 : {1'b0, rs1_idx};
    src2_areg    = {1'b0, inst[24:20]};
    illegal_inst = rom_illegal | (cls[CLS_CSR_NOP] & csr_illegal);
  end

endmodule

`default_nettype wire
