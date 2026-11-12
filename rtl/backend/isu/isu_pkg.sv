// Ref: back-end/Isu.cpp  class Isu; back-end/include/IssueQueue.h  class IssueQueue (types and static configuration)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */  // constants package: not every constant is used by every top
package isu_pkg;
  import ttg_cfg_pkg::*;

  // ---- operation classes (base_types.h UopType) ------------------------------------------------
  localparam int OP_W = 5;                                  // UOP_TYPE_WIDTH
  localparam bit FP_EN = (FPRF_NUM != 0);                   // F/D: FP queue, FP units, I2F on two integer ports
  localparam int OP_NUM = FP_EN ? 21 : 17;                  // MAX_UOP_TYPE
  localparam int UOP_MUL = 14;
  localparam int UOP_DIV = 15;
  localparam int UOP_FMA = 17;
  localparam int UOP_FMISC = 18;
  localparam int UOP_FDIV = 19;
  localparam int UOP_I2F = 20;
  // The FP write-port limit of the reference model (EXP-032, FP_WB_PORTS default): FP-unit writes per cycle
  localparam int FP_WB_PORTS = 2;
  localparam int FP_COUNT_MAX = FP_FSQRT_D_LAT;              // longest FP latency (the countdown starts at latency - 1)
  localparam int FP_COUNT_W = $clog2(FP_COUNT_MAX);
  typedef logic [OP_NUM-1:0] op_set_t;                      // one bit per UopType (capability / ready masks)
  typedef logic [OP_W-1:0]   op_t;

  localparam op_set_t MASK_ALU = op_set_t'(OP_MASK_ALU);
  localparam op_set_t MASK_MUL = op_set_t'(OP_MASK_MUL);
  localparam op_set_t MASK_DIV = op_set_t'(OP_MASK_DIV);
  localparam op_set_t MASK_FMA = op_set_t'(OP_MASK_FMA);
  localparam op_set_t MASK_FMISC = op_set_t'(OP_MASK_FMISC);
  localparam op_set_t MASK_FDIV = op_set_t'(OP_MASK_FDIV);
  localparam op_set_t MASK_I2F = op_set_t'(OP_MASK_I2F);
  // op classes with a multi-cycle FP latency (delayed wake-up, FP register write reservation)
  localparam op_set_t MASK_FPD = MASK_FMA | MASK_FMISC | MASK_FDIV | MASK_I2F;
  // ---- issue queues and issue ports (config.h GLOBAL_IQ_CONFIG / GLOBAL_ISSUE_PORT_CONFIG) ----------
  localparam int IQ_NUM = FP_EN ? 6 : 5;                    // IQ_INT, IQ_LD, IQ_STA, IQ_STD, IQ_BR (, IQ_FP)
  localparam int IQ_FP = 5;
  localparam int IQ_DISPATCH_WIDTH = DECODE_WIDTH;          // enqueue lanes per IQ
  localparam int WAKE_NUM = MAX_WAKEUP_PORTS;               // iss_awake channels
  localparam int READY_NUM_W = IQ_READY_NUM_WIDTH;          // iss2dis.ready_num width

  function automatic int iq_size(int q);
    case (q)
      0: return IQ_INT_SIZE;
      1: return IQ_LD_SIZE;
      2: return IQ_STA_SIZE;
      3: return IQ_STD_SIZE;
      5: return FP_IQ_SIZE;
      default: return IQ_BR_SIZE;
    endcase
  endfunction

  // enqueue lanes of queue q (config.h IQ_*_ENQ_WIDTH); dispatch fills lanes 0.. in order, higher lanes are unused
  function automatic int iq_enq_width(int q);
    case (q)
      0: return IQ_INT_ENQ_WIDTH;
      1: return IQ_LD_ENQ_WIDTH;
      2: return IQ_STA_ENQ_WIDTH;
      3: return IQ_STD_ENQ_WIDTH;
      5: return FP_IQ_ENQ_WIDTH;
      default: return IQ_BR_ENQ_WIDTH;
    endcase
  endfunction

  function automatic int iq_port_base(int q);
    case (q)
      0: return IQ_ALU_PORT_BASE;
      1: return IQ_LD_PORT_BASE;
      2: return IQ_STA_PORT_BASE;
      3: return IQ_STD_PORT_BASE;
      5: return IQ_FP_PORT_BASE;
      default: return IQ_BR_PORT_BASE;
    endcase
  endfunction

  function automatic int iq_port_num(int q);
    case (q)
      0: return ALU_NUM;
      1: return LSU_LDU_COUNT;
      2: return LSU_STA_COUNT;
      3: return LSU_SDU_COUNT;
      5: return ISSUE_WIDTH - IQ_FP_PORT_BASE;          // the FP ports come last
      default: return BRU_NUM;
    endcase
  endfunction

  // capability mask of physical issue port p (config.h GLOBAL_ISSUE_PORT_CONFIG, ports 0..5 are the INT cluster)
  function automatic op_set_t port_cap(int p);
    case (p)
      0: return op_set_t'(OP_MASK_ALU | OP_MASK_MUL | OP_MASK_CSR);
      1: return op_set_t'(OP_MASK_ALU | OP_MASK_DIV);
      2: return op_set_t'(OP_MASK_ALU | OP_MASK_MUL) | (FP_EN ? MASK_I2F : op_set_t'(0));
      3: return op_set_t'(OP_MASK_ALU | OP_MASK_DIV) | (FP_EN ? MASK_I2F : op_set_t'(0));
      4, 5: return op_set_t'(OP_MASK_ALU);
      default: begin
        // F/D ports (last): two FMA + MISC pipes, then a divide / square-root unit that also takes MISC
        if (FP_EN && p >= IQ_FP_PORT_BASE)
          return (p == ISSUE_WIDTH - 1) ? (MASK_FDIV | MASK_FMISC) : (MASK_FMA | MASK_FMISC);
        else if (p >= IQ_BR_PORT_BASE) return op_set_t'(OP_MASK_BR);
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

  // F/D model latency (Isu::get_latency, in cycles; the countdown of a delayed wake-up starts at latency - 1)
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: funct7[1] (fmt high bit) is not part of the class
  function automatic logic [FP_COUNT_W:0] fp_latency(input op_t op, input logic [6:0] func7);
    logic d, sq;
    d  = func7[0];                         // funct7[1:0] = fmt (1 = D)
    sq = (func7[6:2] == 5'h0b);            // fsqrt
    if (op == op_t'(UOP_FMA))        return (FP_COUNT_W+1)'(FP_FMA_LAT);
    else if (op == op_t'(UOP_FMISC)) return (FP_COUNT_W+1)'(FP_MISC_LAT);
    else if (op == op_t'(UOP_I2F))   return (FP_COUNT_W+1)'(FP_I2F_LAT);
    else if (sq)                     return d ? (FP_COUNT_W+1)'(FP_FSQRT_D_LAT) : (FP_COUNT_W+1)'(FP_FSQRT_S_LAT);
    else                             return d ? (FP_COUNT_W+1)'(FP_FDIV_D_LAT) : (FP_COUNT_W+1)'(FP_FDIV_S_LAT);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- uop as stored in an issue queue and as sent to the PRF (IqStoredUop minus dbg, minus src busy) ----
  typedef struct packed {
    logic [PRF_IDX_WIDTH-1:0]    dest_preg;
    logic [PRF_IDX_WIDTH-1:0]    src1_preg;
    logic [PRF_IDX_WIDTH-1:0]    src2_preg;
    logic [PRF_IDX_WIDTH-1:0]    src3_preg;
    logic [FTQ_IDX_WIDTH-1:0]    ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic                        is_atomic;
    logic                        dest_en;
    logic                        src1_en;
    logic                        src2_en;
    logic                        src3_en;
    logic                        dest_fp;      // F/D domain bits (read by the PRF / LSU / FP gate)
    logic                        src1_fp;
    logic                        src2_fp;
    logic                        src1_is_pc;
    logic                        src2_is_imm;
    logic                        is_word;
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
    logic     src3_busy;
  } isu_enq_t;

  function automatic op_set_t op_onehot(op_t op);
    op_set_t r = '0;
    for (int i = 0; i < OP_NUM; i++) r[i] = (op == op_t'(i));
    return r;
  endfunction

  // ---- delayed wake-up (Isu::get_latency): MUL fixed pipe, DIV countdown slots --------------
  localparam int MUL_DELAYED = (MUL_MAX_LATENCY > 1) ? 1 : 0;
  localparam int MUL_DEPTH = (MUL_MAX_LATENCY > 1) ? (MUL_MAX_LATENCY - 1) : 1;
  localparam int COUNT_MAX = DIV_MAX_LATENCY;
  localparam int COUNT_W = $clog2(COUNT_MAX);               // countdown starts at latency-1 <= COUNT_MAX-1

  // wake-up channel layout of iss_awake (Isu::comb_awake)
  localparam int LD_WAKE_BASE = 0;
  localparam int MUL_UNITS = port_count(MASK_MUL);
  localparam int DIV_UNITS = port_count(MASK_DIV);
  // issue ports that can have a wake-up consequence (ALU/MUL/DIV capable); they are ports 0..WAKE_PORTS-1
  localparam int WAKE_PORTS = port_count(MASK_ALU | MASK_MUL | MASK_DIV);
  localparam int FAST_UNITS = port_count(MASK_ALU);
  localparam int MUL_WAKE_BASE = LD_WAKE_BASE + LSU_LOAD_WB_WIDTH;
  localparam int DIV_WAKE_BASE = MUL_WAKE_BASE + MUL_UNITS;
  localparam int FAST_WAKE_BASE = DIV_WAKE_BASE + DIV_UNITS;
  // F/D: delayed FP wake-ups on FPW_CH channels after the fast ones; the issue ports that can start a multi-cycle FP op
  localparam int FP_WAKE_BASE = FAST_WAKE_BASE + FAST_UNITS;
  localparam int FP_REQ_UNITS = FP_EN ? port_count(MASK_FPD) : 1;
  localparam int FP_SLOTS = 24;                              // ISU_FP_WAKE_SLOT_NUM

endpackage
`default_nettype wire
