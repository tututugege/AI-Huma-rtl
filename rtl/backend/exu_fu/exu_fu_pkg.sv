// Ref: back-end/Exu/include/Fu.h  AluUnit/BruUnit/SduUnit (constants shared by the exu_fu leaf modules)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */  // package constants are used by other files; a package linted alone looks unused

package exu_fu_pkg;

  import ttg_cfg_pkg::*;

  // ---- uop types (back-end/include/base_types.h enum UopType); UOP_TYPE_WIDTH = 5 ----
  localparam int OP_W = 5;
  localparam logic [OP_W-1:0] UOP_JUMP = OP_W'(0);
  localparam logic [OP_W-1:0] UOP_ADD  = OP_W'(1);
  localparam logic [OP_W-1:0] UOP_BR   = OP_W'(2);
  localparam logic [OP_W-1:0] UOP_WFI  = OP_W'(16);

  // ---- AMO operations = funct7[6:2] (back-end/include/types.h namespace AmoOp) ----
  localparam int AMO_W = 5;
  localparam logic [AMO_W-1:0] AMO_ADD  = AMO_W'(5'b00000);
  localparam logic [AMO_W-1:0] AMO_XOR  = AMO_W'(5'b00100);
  localparam logic [AMO_W-1:0] AMO_OR   = AMO_W'(5'b01000);
  localparam logic [AMO_W-1:0] AMO_AND  = AMO_W'(5'b01100);
  localparam logic [AMO_W-1:0] AMO_MIN  = AMO_W'(5'b10000);
  localparam logic [AMO_W-1:0] AMO_MAX  = AMO_W'(5'b10100);
  localparam logic [AMO_W-1:0] AMO_MINU = AMO_W'(5'b11000);
  localparam logic [AMO_W-1:0] AMO_MAXU = AMO_W'(5'b11100);

  // ---- number of instances of the FU kinds that ttg_cfg_pkg does not export (count of ports in
  //      GLOBAL_ISSUE_PORT_CONFIG whose support_mask has OP_MASK_MUL / OP_MASK_DIV: config.h:371-398) ----
  localparam int MUL_NUM = 2;
  localparam int DIV_NUM = 2;

  // ---- ALU: one-hot-ish control decoded from (op, func3, func7, src2_is_imm, imm[4:0]) by alu_decode ----
  typedef struct packed {
    logic       add;       // adder result (add / sub / shNadd; also every non-ADD, non-WFI op)
    logic       sub;       // adder subtracts operand2
    logic [1:0] add_shamt; // operand1 << add_shamt before the adder (sh1add/sh2add/sh3add)
    logic       slt;       // signed  less-than, zero-extended
    logic       sltu;      // unsigned less-than, zero-extended
    logic       lg_and;    // bitwise unit selected: and / or / xor of operand1 and B
    logic       lg_or;
    logic       lg_xor;
    logic       lg_inv_b;  // B = ~operand2   (andn, orn, xnor, bclr)
    logic       lg_bit_b;  // B = 1 << shamt  (bclr, bset, binv)
    logic       mm;        // min/max family selected
    logic       mm_max;    // max (else min)
    logic       mm_uns;    // unsigned compare
    logic       shf;       // funnel shifter result (sll/srl/sra/rol/ror)
    logic       shf_left;
    logic       shf_rot;
    logic       shf_arith;
    logic       bext;      // (operand1 >> shamt) & 1
    logic       pack;
    logic       packh;
    logic       clz;
    logic       ctz;
    logic       cpop;
    logic       sext_b;
    logic       sext_h;
    logic       rev8;
    logic       orcb;
    logic       clmul;
    logic       clmulr;
    logic       clmulh;
    // rv64 *W instructions (is_word): operand preconditioning and result sign-extension
    logic       w_res;     // result = sext32(result[31:0])
    logic       w_zext_a;  // operand1 = zext32(operand1) before the adder / shifter (add.uw, shNadd.uw, slli.uw, srlw)
    logic       w_sext_a;  // operand1 = sext32(operand1) before the shifter (sraw)
    logic       w_rot;     // 32-bit rotate: shifter input {a[31:0], a[31:0]}
    logic       w_shamt5;  // shift amount is operand2[4:0] (else operand2[5:0] on rv64)
    logic       w_cnt;     // clzw / ctzw / cpopw: bit-count unit sees the low word only
  } alu_ctl_t;

  // ---- payload of a multi-cycle FU entry: the ExuInst fields the Exu consumers read for a MUL/DIV uop
  //      (to_exe_prf_wb_uop / to_exu_rob_uop; every other ExuInst field of a MUL/DIV is constant 0 or unread) ----
  typedef struct packed {
    logic [XLEN_BITS-1:0]                result;
    logic [ROB_IDX_WIDTH-1:0]   rob_idx;
    logic [PRF_IDX_WIDTH-1:0]   dest_preg;
    logic                       dest_en;
    logic [BR_MASK_WIDTH-1:0]   br_mask;
  } fu_uop_t;
  // payload of an F/D unit entry: the 64-bit FP register value (or the integer result in its low bits), the flags
  typedef struct packed {
    logic [63:0]                fresult;
    logic [4:0]                 fflags;
    logic                       illegal;
    logic [ROB_IDX_WIDTH-1:0]   rob_idx;
    logic [PRF_IDX_WIDTH-1:0]   dest_preg;
    logic                       dest_en;
    logic [BR_MASK_WIDTH-1:0]   br_mask;
  } fp_uop_t;

endpackage

`default_nettype wire
