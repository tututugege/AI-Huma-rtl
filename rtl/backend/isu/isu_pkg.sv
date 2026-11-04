// Ref: back-end/Isu.cpp  class Isu; back-end/include/IssueQueue.h  class IssueQueue (types and static configuration)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */  // constants package: not every constant is used by every top
package isu_pkg;
  import ttg_cfg_pkg::*;

  // ---- operation classes (base_types.h UopType) ------------------------------------------------
  localparam int OP_W = 5;                                  // UOP_TYPE_WIDTH
  localparam int OP_NUM = 18;                               // MAX_UOP_TYPE
  localparam int UOP_MUL = 14;
  localparam int UOP_DIV = 15;
  localparam int UOP_FP = 17;
  typedef logic [OP_NUM-1:0] op_set_t;                      // one bit per UopType (capability / ready masks)
  typedef logic [OP_W-1:0]   op_t;

  localparam op_set_t MASK_ALU = op_set_t'(OP_MASK_ALU);
  localparam op_set_t MASK_MUL = op_set_t'(OP_MASK_MUL);
  localparam op_set_t MASK_DIV = op_set_t'(OP_MASK_DIV);
  localparam op_set_t MASK_FP = op_set_t'(OP_MASK_FP);

  // ---- issue queues and issue ports (config.h GLOBAL_IQ_CONFIG / GLOBAL_ISSUE_PORT_CONFIG) ----------
  localparam int IQ_NUM = 5;                                // IQ_INT, IQ_LD, IQ_STA, IQ_STD, IQ_BR
  localparam int IQ_DISPATCH_WIDTH = DECODE_WIDTH;          // enqueue lanes per IQ
  localparam int WAKE_NUM = MAX_WAKEUP_PORTS;               // iss_awake channels
  localparam int READY_NUM_W = IQ_READY_NUM_WIDTH;          // iss2dis.ready_num width

  function automatic int iq_size(int q);
    return (q == 0) ? 128 : 64;
  endfunction

  function automatic int iq_port_base(int q);
    case (q)
      0: return IQ_ALU_PORT_BASE;
      1: return IQ_LD_PORT_BASE;
      2: return IQ_STA_PORT_BASE;
      3: return IQ_STD_PORT_BASE;
      default: return IQ_BR_PORT_BASE;
    endcase
  endfunction

  function automatic int iq_port_num(int q);
    case (q)
      0: return ALU_NUM;
      1: return LSU_LDU_COUNT;
      2: return LSU_STA_COUNT;
      3: return LSU_SDU_COUNT;
      default: return BRU_NUM;
    endcase
  endfunction

  // capability mask of physical issue port p (config.h GLOBAL_ISSUE_PORT_CONFIG, ports 0..5 are the INT cluster)
  function automatic op_set_t port_cap(int p);
    case (p)
      0: return op_set_t'(OP_MASK_ALU | OP_MASK_MUL | OP_MASK_CSR);
      1: return op_set_t'(OP_MASK_ALU | OP_MASK_DIV | OP_MASK_FP);
      2: return op_set_t'(OP_MASK_ALU | OP_MASK_MUL);
      3: return op_set_t'(OP_MASK_ALU | OP_MASK_DIV);
      4, 5: return op_set_t'(OP_MASK_ALU);
      default: begin
        if (p >= IQ_BR_PORT_BASE) return op_set_t'(OP_MASK_BR);
        else if (p >= IQ_STD_PORT_BASE) return op_set_t'(OP_MASK_STD);
        else if (p >= IQ_STA_PORT_BASE) return op_set_t'(OP_MASK_STA);
        else return op_set_t'(OP_MASK_LD);
      end
    endcase
  endfunction

  // number of issue ports whose capability intersects `mask` / how many such ports come before port p
  function automatic int port_count(op_set_t mask);
    int n = 0;
    for (int p = 0; p < ISSUE_WIDTH; p++) n += int'((port_cap(p) & mask) != '0);
    return n;
  endfunction

  function automatic int port_rank(op_set_t mask, int p);
    int n = 0;
    for (int q = 0; q < p; q++) n += int'((port_cap(q) & mask) != '0);
    return n;
  endfunction

  function automatic bit port_has(op_set_t mask, int p);
    return (port_cap(p) & mask) != '0;
  endfunction

  // ---- uop as stored in an issue queue and as sent to the PRF (IqStoredUop minus dbg, minus src busy) ----
  typedef struct packed {
    logic [PRF_IDX_WIDTH-1:0]    dest_preg;
    logic [PRF_IDX_WIDTH-1:0]    src1_preg;
    logic [PRF_IDX_WIDTH-1:0]    src2_preg;
    logic [FTQ_IDX_WIDTH-1:0]    ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic                        is_atomic;
    logic                        dest_en;
    logic                        src1_en;
    logic                        src2_en;
    logic                        src1_is_pc;
    logic                        src2_is_imm;
    logic [2:0]                  func3;
    logic [6:0]                  func7;
    logic [31:0]                 imm;
    logic [BR_TAG_WIDTH-1:0]     br_id;
    logic [BR_MASK_WIDTH-1:0]    br_mask;
    logic [CSR_IDX_WIDTH-1:0]    csr_idx;
    logic [ROB_IDX_WIDTH-1:0]    rob_idx;
    logic [STQ_IDX_WIDTH-1:0]    stq_idx;
    logic                        stq_flag;
    logic [LDQ_IDX_WIDTH-1:0]    ldq_idx;
    logic                        rob_flag;
    op_t                         op;
  } isu_uop_t;

  // dispatch request: the uop plus the two source "still busy" flags (consumed at enqueue)
  typedef struct packed {
    isu_uop_t uop;
    logic     src1_busy;
    logic     src2_busy;
  } isu_enq_t;

  function automatic op_set_t op_onehot(op_t op);
    op_set_t r = '0;
    for (int i = 0; i < OP_NUM; i++) r[i] = (op == op_t'(i));
    return r;
  endfunction

  // ---- delayed wake-up (Isu::get_latency): MUL fixed pipe, DIV / FP countdown slots --------------
  localparam int MUL_DELAYED = (MUL_MAX_LATENCY > 1) ? 1 : 0;
  localparam int MUL_DEPTH = (MUL_MAX_LATENCY > 1) ? (MUL_MAX_LATENCY - 1) : 1;
  localparam int FP_MAX_LATENCY = 10;                       // fdiv / fsqrt
  localparam int COUNT_MAX = (DIV_MAX_LATENCY > FP_MAX_LATENCY) ? DIV_MAX_LATENCY : FP_MAX_LATENCY;
  localparam int COUNT_W = $clog2(COUNT_MAX);               // countdown starts at latency-1 <= COUNT_MAX-1

  // FP latency by func7 (fadd/fsub 5, fmul 3, fdiv 10, fsqrt 10, fcvt.w.s / fcvt.s.w 3, others 5)
  function automatic logic [COUNT_W-1:0] fp_countdown(logic [6:0] func7);
    logic [COUNT_W-1:0] lat;
    if (func7[6:2] == 5'b00000 || func7[6:2] == 5'b00001) lat = COUNT_W'(5);
    else if (func7[6:2] == 5'b00010) lat = COUNT_W'(3);
    else if (func7[6:2] == 5'b00011) lat = COUNT_W'(10);
    else if (func7 == 7'h2C) lat = COUNT_W'(10);
    else if (func7 == 7'h60 || func7 == 7'h68) lat = COUNT_W'(3);
    else lat = COUNT_W'(5);
    return lat - COUNT_W'(1);
  endfunction

  // wake-up channel layout of iss_awake (Isu::comb_awake)
  localparam int LD_WAKE_BASE = 0;
  localparam int MUL_UNITS = port_count(MASK_MUL);
  localparam int DIV_UNITS = port_count(MASK_DIV);
  localparam int FP_UNITS = port_count(MASK_FP);
  // issue ports that can have a wake-up consequence (ALU/MUL/DIV/FP capable); they are ports 0..WAKE_PORTS-1
  localparam int WAKE_PORTS = port_count(MASK_ALU | MASK_MUL | MASK_DIV | MASK_FP);
  localparam int FAST_UNITS = port_count(MASK_ALU);
  localparam int MUL_WAKE_BASE = LD_WAKE_BASE + LSU_LOAD_WB_WIDTH;
  localparam int DIV_WAKE_BASE = MUL_WAKE_BASE + MUL_UNITS;
  localparam int FP_WAKE_BASE = DIV_WAKE_BASE + DIV_UNITS;
  localparam int FAST_WAKE_BASE = FP_WAKE_BASE + FP_UNITS;

endpackage
`default_nettype wire
