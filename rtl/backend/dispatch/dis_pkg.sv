// Ref: back-end/Dispatch.cpp  class Dispatch (types shared by the dispatch_* modules)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */  // constants package: not every constant is used by every top
package dis_pkg;
  import ttg_cfg_pkg::*;

  // ---- geometry (all derived from ttg_cfg_pkg / reference config.h) -----------------------------
  localparam int NUM_SLOTS = DECODE_WIDTH;                  // dispatch lanes == decode lanes
  // issue queues (the numbering of dis2iss / iss2dis): the memory queue holds the loads and the store addresses
  localparam int IQ_NUM  = 6;
  localparam int IQ_INT  = 0;
  localparam int IQ_MEM  = 1;
  localparam int IQ_STD  = 2;
  localparam int IQ_BR   = 3;
  localparam int IQ_FP   = 4;
  localparam int IQ_INT1 = 5;                               // the second integer queue
  // kinds of uop an instruction is split into (dispatch_decompose): at most one uop of each kind per instruction; the
  // kinds LD and STA both go to the memory queue (an AMO sends both), INT goes to IQ_INT or IQ_INT1
  localparam int K_NUM = 6;
  localparam int K_INT = 0;
  localparam int K_LD  = 1;
  localparam int K_STA = 2;
  localparam int K_STD = 3;
  localparam int K_BR  = 4;
  localparam int K_FP  = 5;
  localparam int IQ_PORTS = MAX_IQ_DISPATCH_WIDTH;          // request ports per IQ
  localparam int IQ_POS_W = $clog2(2 * NUM_SLOTS + 1);      // full pre-fire IQ queue position (no mod-8 alias for AMOs)
  localparam int STQ_PORTS = MAX_STQ_DISPATCH_WIDTH;
  localparam int LDQ_PORTS = MAX_LDQ_DISPATCH_WIDTH;
  localparam int STQ_PORT_W = $clog2(STQ_PORTS);
  localparam int LDQ_PORT_W = $clog2(LDQ_PORTS);
  localparam int STQ_FREE_W = $clog2(STQ_SIZE + 1);         // bit_width_for_count(STQ_SIZE + 1)
  localparam int LDQ_FREE_W = $clog2(LDQ_SIZE + 1);
  localparam int STQ_POS_W = STQ_IDX_WIDTH + 1;             // STQ ring position incl. wrap carry
  // iss_awake already includes the LSU_LOAD_WB_WIDTH prf_awake channels at [0..LSU_LOAD_WB_WIDTH-1];
  // LSU drives 14 wake channels: [0..3] L1 spec, [4..7] L3, [8..11] L2b STLF / L2a fallback, [12..13] WBP.
  localparam int NUM_LSU_WAKE  = 3 * LSU_LDU_COUNT + 2;
  localparam int NUM_WAKE      = MAX_WAKEUP_PORTS + NUM_LSU_WAKE;
  // the one definition of the InstType / UopType encodings and widths (rob_pkg, ren_pkg, isu_pkg, exu_ctrl_pkg,
  // exu_fu_pkg and prf refer to these; values are those of types.h / base_types.h)
  localparam int INST_TYPE_W = 5;                           // bit_width_for_count(20 InstType values)
  localparam int UOP_TYPE_W = 5;                            // bit_width_for_count(21 UopType values)
  localparam int CPLT_MASK_W = 3;                           // ROB_CPLT_MASK_WIDTH

  localparam logic [CPLT_MASK_W-1:0] CPLT_G0 = 3'b001;      // INT / LD completions
  localparam logic [CPLT_MASK_W-1:0] CPLT_G1 = 3'b010;      // BR / STA completions
  localparam logic [CPLT_MASK_W-1:0] CPLT_G2 = 3'b100;      // STD completions

  localparam logic [4:0] AMO_SWAP = 5'b00001;               // amo_op of amo*
  localparam logic [4:0] AMO_LR = 5'b00010;
  localparam logic [4:0] AMO_SC = 5'b00011;

  typedef enum logic [INST_TYPE_W-1:0] {
    INST_NOP = 5'd0, INST_JAL, INST_JALR, INST_ADD, INST_BR, INST_LOAD, INST_STORE, INST_CSR,
    INST_FENCE, INST_ECALL, INST_EBREAK, INST_WFI, INST_SFENCE_VMA, INST_FENCE_I, INST_MRET,
    INST_SRET, INST_MUL, INST_DIV, INST_AMO, INST_FPOP
  } inst_type_e;

  typedef enum logic [UOP_TYPE_W-1:0] {
    UOP_JUMP = 5'd0, UOP_ADD, UOP_BR, UOP_LOAD, UOP_STA, UOP_STD, UOP_CSR, UOP_FENCE, UOP_ECALL,
    UOP_EBREAK, UOP_SFENCE_VMA, UOP_FENCE_I, UOP_MRET, UOP_SRET, UOP_MUL, UOP_DIV, UOP_WFI,
    UOP_FMA, UOP_FMISC, UOP_FDIV, UOP_I2F
  } uop_op_e;
  localparam int UOP_TYPE_NUM = int'(UOP_I2F) + 1;          // MAX_UOP_TYPE = 21 (F/D is always built)
  typedef logic [UOP_TYPE_NUM-1:0] uop_set_t;                // one bit per UopType (capability / ready masks)

  // capability mask of physical issue port p (config.h GLOBAL_ISSUE_PORT_CONFIG; ports 0..5 are the INT cluster, CSR
  // is hard-bound to port 0). The one copy of this table: isu_pkg::port_cap and exu_ctrl_pkg read it.
  function automatic uop_set_t issue_port_cap(int p);
    case (p)
      0: return uop_set_t'(OP_MASK_ALU | OP_MASK_MUL | OP_MASK_CSR);
      1: return uop_set_t'(OP_MASK_ALU | OP_MASK_DIV);
      2: return uop_set_t'(OP_MASK_ALU | OP_MASK_MUL | OP_MASK_I2F);
      3: return uop_set_t'(OP_MASK_ALU | OP_MASK_I2F);
      4, 5: return uop_set_t'(OP_MASK_ALU);
      default: begin
        // F/D ports (last): two FMA + MISC pipes, then a divide / square-root unit that also takes MISC
        if (p >= IQ_FP_PORT_BASE)
          return (p == ISSUE_WIDTH - 1) ? uop_set_t'(OP_MASK_FDIV | OP_MASK_FMISC)
                                        : uop_set_t'(OP_MASK_FMA | OP_MASK_FMISC);
        else if (p >= IQ_BR_PORT_BASE) return uop_set_t'(OP_MASK_BR);
        else if (p >= IQ_STD_PORT_BASE) return uop_set_t'(OP_MASK_STD);
        else if (p >= IQ_AGU_PORT_BASE + LSU_LDU_COUNT) return uop_set_t'(OP_MASK_STA);
        else if (p >= IQ_AGU_PORT_BASE + LSU_LDU_COUNT - LSU_AGU_SHARED) return uop_set_t'(OP_MASK_LD | OP_MASK_STA);
        else return uop_set_t'(OP_MASK_LD);
      end
    endcase
  endfunction

  // FpCls (Ref: base_types.h): which unit class an OP-FP / fused instruction needs
  localparam logic [2:0] FPC_NONE = 3'd0, FPC_FMA = 3'd1, FPC_FDIV = 3'd2, FPC_MISC = 3'd3, FPC_I2F = 3'd4;

  // One renamed instruction as held in the dispatch register stage (RenDisIO::RenDisInst minus
  // perf/debug sidebands and the dead expect/cplt masks and src2_areg).
  typedef struct packed {
    logic [XLEN_BITS-1:0]               diag_val;
    logic [AREG_IDX_WIDTH-1:0] dest_areg;
    logic [AREG_IDX_WIDTH-1:0] src1_areg;
    logic [PRF_IDX_WIDTH-1:0]  dest_preg;
    logic [PRF_IDX_WIDTH-1:0]  src1_preg;
    logic [PRF_IDX_WIDTH-1:0]  src2_preg;
    logic [PRF_IDX_WIDTH-1:0]  src3_preg;     // F/D: third source of a fused multiply-add (valid while src3_en)
    logic                      me_elim;       // move elimination: dest_preg is src1_preg, no uop
    logic                      dest_fp;       // F/D: the registers above are FP tags (FP_TAG_BASE+)
    logic                      src1_fp;
    logic                      src2_fp;
    logic                      src3_en;
    logic [2:0]                fp_cls;
    logic [FTQ_IDX_WIDTH-1:0]  ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic                      ftq_is_last;
    inst_type_e                itype;
    logic                      dest_en;
    logic                      src1_en;
    logic                      src2_en;
    logic                      is_atomic;
    logic                      src1_is_pc;
    logic                      src2_is_imm;
    logic                      is_word;
    logic [2:0]                func3;
    logic [6:0]                func7;
    logic [31:0]               imm;
    logic [CSR_IDX_WIDTH-1:0]  csr_idx;
    logic                      page_fault_inst;
    logic                      pf_inst_hi;
    logic                      illegal_inst;
    logic [LSU_MDP_BITS-1:0]   mdp;
    logic [31:0]               pc;           // wait-table index of the PC (loads only use it)
    logic                      is_rvc;        // 16-bit instruction (RVC=1): the link value of JAL/JALR is 2
  } dis_inst_t;

  // Resources assigned to a slot in the allocation stage (ROB line slot, STQ/LDQ entries).
  typedef struct packed {
    logic [ROB_IDX_WIDTH-1:0]  rob_idx;
    logic                      rob_flag;
    logic [STQ_IDX_WIDTH-1:0]  stq_idx;
    logic                      stq_flag;
    logic [LDQ_IDX_WIDTH-1:0]  ldq_idx;
  } dis_res_t;

  // One micro-op as sent to an issue queue (DisIssIO::DisIssUop).
  typedef struct packed {
    logic [PRF_IDX_WIDTH-1:0]  dest_preg;
    logic [PRF_IDX_WIDTH-1:0]  src1_preg;
    logic [PRF_IDX_WIDTH-1:0]  src2_preg;
    logic [PRF_IDX_WIDTH-1:0]  src3_preg;
    logic [FTQ_IDX_WIDTH-1:0]  ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic                      is_atomic;
    logic                      dest_en;
    logic                      src1_en;
    logic                      src2_en;
    logic                      src3_en;
    logic                      src1_busy;
    logic                      src2_busy;
    logic                      src3_busy;
    logic                      dest_fp;       // F/D domain bits: the register is in the FP file
    logic                      src1_fp;
    logic                      src2_fp;
    logic                      src1_is_pc;
    logic                      src2_is_imm;
    logic                      is_word;
    logic [2:0]                func3;
    logic [6:0]                func7;
    logic [31:0]               imm;
    logic [CSR_IDX_WIDTH-1:0]  csr_idx;
    logic [ROB_IDX_WIDTH-1:0]  rob_idx;
    logic [STQ_IDX_WIDTH-1:0]  stq_idx;
    logic                      stq_flag;
    logic [LDQ_IDX_WIDTH-1:0]  ldq_idx;
    logic                      rob_flag;
    uop_op_e                   op;
  } dis_iss_uop_t;

  // One dispatched instruction as sent to the ROB (DisRobIO::DisRobUop, fields ROB actually consumes).
  typedef struct packed {
    logic [XLEN_BITS-1:0]        diag_val;
    logic [AREG_IDX_WIDTH-1:0]   dest_areg;
    logic [AREG_IDX_WIDTH-1:0]   src1_areg;
    logic                        dest_fp;
    logic                        fs_need;
    logic [FTQ_IDX_WIDTH-1:0]    ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic                        ftq_is_last;
    logic [INST_TYPE_W-1:0]      itype;
    logic                        dest_en;
    logic                        is_amo_lr;
    logic [31:0]                 imm;
    logic [ROB_IDX_WIDTH-1:0]    rob_idx;
    logic [STQ_IDX_WIDTH-1:0]    stq_idx;
    logic                        stq_flag;
    logic [CPLT_MASK_W-1:0]      expect_mask;
    logic                        rob_flag;
    logic                        page_fault_inst;
    logic                        pf_inst_hi;
    logic                        illegal_inst;
  } dis_rob_uop_t;

  // Static instruction classification (is_load/is_store/is_CSR/decompose routing in the C++).
  typedef struct packed {
    logic is_load;     // LOAD or any AMO except SC: needs an LDQ entry
    logic is_store;    // STORE or any AMO except LR: needs an STQ entry (and an STA + STD uop)
    logic is_amo;
    logic is_amo_sc;
    logic to_int;      // has a uop for IQ_INT
    logic to_fp;       // has a uop for IQ_FP (FMA / FDIV / MISC)
    logic to_br;       // has a uop for IQ_BR
  } dis_class_t;

  function automatic dis_class_t dis_classify(input inst_type_e t, input logic [4:0] amo_op,
                                              input logic [2:0] fp_cls);
    dis_class_t c;
    logic fpop;
    c.is_amo    = (t == INST_AMO);
    c.is_amo_sc = c.is_amo && (amo_op == AMO_SC);
    c.is_load   = (t == INST_LOAD) || (c.is_amo && (amo_op != AMO_SC));
    c.is_store  = (t == INST_STORE) || (c.is_amo && (amo_op != AMO_LR));
    c.to_br     = (t == INST_BR) || (t == INST_JAL) || (t == INST_JALR);
    fpop        = (t == INST_FPOP);
    c.to_fp     = fpop && (fp_cls != FPC_I2F);
    // integer -> FP moves / conversions are integer-queue uops (UOP_I2F); every other FP instruction goes to IQ_FP
    c.to_int    = (t != INST_BR) && (t != INST_LOAD) && (t != INST_STORE) && !c.is_amo && !c.to_fp;
    return c;
  endfunction

  // is_CSR(): CSR / MRET / ECALL / EBREAK dispatch only into an empty ROB and alone-first in the group
  function automatic logic dis_is_csr_like(input inst_type_e t);
    return (t == INST_CSR) || (t == INST_MRET) || (t == INST_ECALL) || (t == INST_EBREAK);
  endfunction

endpackage

`default_nettype wire
