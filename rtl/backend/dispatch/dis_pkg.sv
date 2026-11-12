// Ref: back-end/Dispatch.cpp  class Dispatch (types shared by the dispatch_* modules)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */  // constants package: not every constant is used by every top
package dis_pkg;
  import ttg_cfg_pkg::*;

  // ---- geometry (all derived from ttg_cfg_pkg / reference config.h) -----------------------------
  localparam int NUM_SLOTS = DECODE_WIDTH;                  // dispatch lanes == decode lanes
  localparam int SLOT_IDX_W = $clog2(NUM_SLOTS);
  localparam int IQ_NUM = 5;                                // IQ_INT, IQ_LD, IQ_STA, IQ_STD, IQ_BR
  localparam int IQ_INT = 0;
  localparam int IQ_LD = 1;
  localparam int IQ_STA = 2;
  localparam int IQ_STD = 3;
  localparam int IQ_BR = 4;
  localparam int IQ_PORTS = MAX_IQ_DISPATCH_WIDTH;          // request ports per IQ
  localparam int IQ_PORT_W = $clog2(IQ_PORTS);
  localparam int STQ_PORTS = MAX_STQ_DISPATCH_WIDTH;
  localparam int LDQ_PORTS = MAX_LDQ_DISPATCH_WIDTH;
  localparam int STQ_PORT_W = $clog2(STQ_PORTS);
  localparam int LDQ_PORT_W = $clog2(LDQ_PORTS);
  localparam int STQ_FREE_W = $clog2(STQ_SIZE + 1);         // bit_width_for_count(STQ_SIZE + 1)
  localparam int LDQ_FREE_W = $clog2(LDQ_SIZE + 1);
  localparam int STQ_POS_W = STQ_IDX_WIDTH + 1;             // STQ ring position incl. wrap carry
  localparam int NUM_WAKE = LSU_LOAD_WB_WIDTH + MAX_WAKEUP_PORTS + 2 * LSU_LDU_COUNT;  // prf + iss + LSU wakes
  localparam int ROB_BANK_W = $clog2(ROB_BANK_NUM);         // lane bits inside a ROB line
  localparam int ROB_LINE_W = ROB_IDX_WIDTH - ROB_BANK_W;   // ROB line (enqueue group) index bits
  localparam int INST_TYPE_W = 5;                           // bit_width_for_count(20 InstType values)
  localparam int UOP_TYPE_W = 5;                            // bit_width_for_count(18 UopType values)
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
    UOP_EBREAK, UOP_SFENCE_VMA, UOP_FENCE_I, UOP_MRET, UOP_SRET, UOP_MUL, UOP_DIV, UOP_WFI
  } uop_op_e;

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
    logic [PRF_IDX_WIDTH-1:0]  old_dest_preg;
    logic                      me_elim;       // move elimination: dest_preg is src1_preg, no uop
    logic                      dest_fp;       // F/D: the registers above are FP tags (FP_TAG_BASE+)
    logic                      src1_fp;
    logic                      src2_fp;
    logic                      src3_en;
    logic                      src3_busy;
    logic [2:0]                fp_cls;
    logic [FTQ_IDX_WIDTH-1:0]  ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic                      ftq_is_last;
    inst_type_e                itype;
    logic                      dest_en;
    logic                      src1_en;
    logic                      src2_en;
    logic                      is_atomic;
    logic                      src1_busy;
    logic                      src2_busy;
    logic                      src1_is_pc;
    logic                      src2_is_imm;
    logic                      is_word;
    logic [2:0]                func3;
    logic [6:0]                func7;
    logic [31:0]               imm;
    logic [BR_TAG_WIDTH-1:0]   br_id;
    logic [BR_MASK_WIDTH-1:0]  br_mask;
    logic [CSR_IDX_WIDTH-1:0]  csr_idx;
    logic                      page_fault_inst;
    logic                      illegal_inst;
    logic [LSU_MDP_BITS-1:0]   mdp;           // wait-table index of the PC (LSU_MEMSPEC; loads only use it)
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
    logic [FTQ_IDX_WIDTH-1:0]  ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic                      is_atomic;
    logic                      dest_en;
    logic                      src1_en;
    logic                      src2_en;
    logic                      src1_busy;
    logic                      src2_busy;
    logic                      src1_is_pc;
    logic                      src2_is_imm;
    logic                      is_word;
    logic [2:0]                func3;
    logic [6:0]                func7;
    logic [31:0]               imm;
    logic [BR_TAG_WIDTH-1:0]   br_id;
    logic [BR_MASK_WIDTH-1:0]  br_mask;
    logic [CSR_IDX_WIDTH-1:0]  csr_idx;
    logic [ROB_IDX_WIDTH-1:0]  rob_idx;
    logic [STQ_IDX_WIDTH-1:0]  stq_idx;
    logic                      stq_flag;
    logic [LDQ_IDX_WIDTH-1:0]  ldq_idx;
    logic                      rob_flag;
    uop_op_e                   op;
  } dis_iss_uop_t;

  // Static instruction classification (is_load/is_store/is_CSR/decompose routing in the C++).
  typedef struct packed {
    logic is_load;     // LOAD or any AMO except SC: needs an LDQ entry
    logic is_store;    // STORE or any AMO except LR: needs an STQ entry (and an STA + STD uop)
    logic is_amo;
    logic is_amo_sc;
    logic to_int;      // has a uop for IQ_INT
    logic to_br;       // has a uop for IQ_BR
  } dis_class_t;

  function automatic dis_class_t dis_classify(input inst_type_e t, input logic [4:0] amo_op);
    dis_class_t c;
    c.is_amo    = (t == INST_AMO);
    c.is_amo_sc = c.is_amo && (amo_op == AMO_SC);
    c.is_load   = (t == INST_LOAD) || (c.is_amo && (amo_op != AMO_SC));
    c.is_store  = (t == INST_STORE) || (c.is_amo && (amo_op != AMO_LR));
    c.to_br     = (t == INST_BR) || (t == INST_JAL) || (t == INST_JALR);
    c.to_int    = (t != INST_BR) && (t != INST_LOAD) && (t != INST_STORE) && !c.is_amo;
    return c;
  endfunction

  // is_CSR(): CSR / MRET / ECALL / EBREAK dispatch only into an empty ROB and alone-first in the group
  function automatic logic dis_is_csr_like(input inst_type_e t);
    return (t == INST_CSR) || (t == INST_MRET) || (t == INST_ECALL) || (t == INST_EBREAK);
  endfunction

endpackage

`default_nettype wire
