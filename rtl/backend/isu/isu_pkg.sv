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
  localparam int IQ_NUM = 6;                                // IQ_INT, IQ_MEM, IQ_STD, IQ_BR, IQ_FP (F/D), IQ_INT1 (dis_pkg numbering)
  localparam int IQ_MEM = 1;                                // one queue for the loads and the store addresses
  localparam int IQ_FP = 4;
  localparam int IQ_INT1 = 5;                               // the second integer queue (the six ALU ports are split over the two integer queues)
  localparam int IQ_DISPATCH_WIDTH = DECODE_WIDTH;          // enqueue lanes per IQ
  localparam int WAKE_NUM = MAX_WAKEUP_PORTS;               // iss_awake channels
  localparam int READY_NUM_W = IQ_READY_NUM_WIDTH;          // iss2dis.ready_num width

  function automatic int iq_size(int q);
    case (q)
      0: return IQ_INT_SIZE;
      1: return IQ_MEM_SIZE;
      2: return IQ_STD_SIZE;
      4: return FP_EN ? FP_IQ_SIZE : 1;
      5: return IQ_INT_SIZE;
      default: return IQ_BR_SIZE;
    endcase
  endfunction

  // enqueue lanes of queue q (config.h IQ_*_ENQ_WIDTH); dispatch fills lanes 0.. in order, higher lanes are unused
  function automatic int iq_enq_width(int q);
    case (q)
      0: return IQ_INT_ENQ_WIDTH;
      1: return IQ_MEM_ENQ_WIDTH;
      2: return IQ_STD_ENQ_WIDTH;
      4: return FP_EN ? FP_IQ_ENQ_WIDTH : 1;
      5: return IQ_INT_ENQ_WIDTH;
      default: return IQ_BR_ENQ_WIDTH;
    endcase
  endfunction

  function automatic int iq_port_base(int q);
    case (q)
      0: return IQ_ALU_PORT_BASE;
      1: return IQ_LD_PORT_BASE;
      2: return IQ_STD_PORT_BASE;
      4: return IQ_FP_PORT_BASE;
      default: return IQ_BR_PORT_BASE;
    endcase
  endfunction

  function automatic int iq_port_num(int q);
    case (q)
      0: return 3;                                        // queue 0 has the ports 0, 1, 4 ...
      5: return 3;                                        // ... and queue 5 (IQ_INT1) the ports 2, 3, 5
      1: return LSU_LDU_COUNT + LSU_STA_COUNT;            // the memory queue serves the load and the STA ports
      2: return LSU_SDU_COUNT;
      4: return FP_EN ? ISSUE_WIDTH - IQ_FP_PORT_BASE : 0;   // the FP ports come last
      default: return BRU_NUM;
    endcase
  endfunction

  // physical issue port of port p of queue q (the two INT queues split the six ALU ports 0, 1, 4 / 2, 3, 5)
  function automatic int iq_port(int q, int p);
    if (q == IQ_INT1) return (p == 0) ? 2 : (p == 1) ? 3 : 5;
    if (q == 0)       return (p == 0) ? 0 : (p == 1) ? 1 : 4;
    return iq_port_base(q) + p;
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

  // Completion offset of a uop (Isu::comb_issue gate): cycles from the issue cycle to its completion in the unit.
  // The wake-up latency, except for the iterative units (DIV, FDIV), which finish one cycle later.
  localparam int WB_OFF_MAX = (DIV_MAX_LATENCY + 1 > FP_FSQRT_D_LAT + 1) ? DIV_MAX_LATENCY + 1 : FP_FSQRT_D_LAT + 1;
  localparam int WB_OFF_W = $clog2(WB_OFF_MAX + 1);
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: only func7[6:2] / func7[0] and is_word of the class are read
  function automatic logic [WB_OFF_W-1:0] wb_offset(input op_t op, input logic [6:0] func7, input logic is_word);
    if (op == op_t'(UOP_MUL)) return WB_OFF_W'((MUL_MAX_LATENCY <= 0) ? 1 : MUL_MAX_LATENCY);
    else if (op == op_t'(UOP_DIV))
      return WB_OFF_W'(((is_word) ? DIV_MAX_LATENCY / 2 : DIV_MAX_LATENCY) + 1);
    else if (FP_EN && op == op_t'(UOP_FDIV)) return WB_OFF_W'(fp_latency(op, func7)) + WB_OFF_W'(1);
    else if (FP_EN && (op == op_t'(UOP_FMA) || op == op_t'(UOP_FMISC) || op == op_t'(UOP_I2F)))
      return WB_OFF_W'(fp_latency(op, func7));
    else return WB_OFF_W'(1);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- completion classes: the write-back and FP write-port gates look the state up per class (the offset is a constant of the
  // class) before the pick is known, instead of decoding the picked uop first ----
  localparam int WB_NCLS  = FP_EN ? 11 : 4;
  localparam int WB_CLS_W = $clog2(WB_NCLS);
  // 0: one cycle, 1: MUL, 2 / 3: DIV word / double, 4 .. 7: FDIV S / D, FSQRT S / D, 8: FMA, 9: FMISC, 10: I2F
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: only func7[6:2] / func7[0] of the FDIV class are read
  function automatic logic [WB_CLS_W-1:0] wb_class(input op_t op, input logic [6:0] func7, input logic is_word);
    if (op == op_t'(UOP_MUL)) return WB_CLS_W'(1);
    else if (op == op_t'(UOP_DIV)) return is_word ? WB_CLS_W'(2) : WB_CLS_W'(3);
    else if (FP_EN && op == op_t'(UOP_FDIV)) return WB_CLS_W'(4) + WB_CLS_W'({(func7[6:2] == 5'h0b), func7[0]});
    else if (FP_EN && op == op_t'(UOP_FMA)) return WB_CLS_W'(8);
    else if (FP_EN && op == op_t'(UOP_FMISC)) return WB_CLS_W'(9);
    else if (FP_EN && op == op_t'(UOP_I2F)) return WB_CLS_W'(10);
    else return '0;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  // completion offset of a class (equals wb_offset of any uop of the class)
  function automatic int wb_cls_off(input int c);
    case (c)
      1: return (MUL_MAX_LATENCY <= 0) ? 1 : MUL_MAX_LATENCY;
      2: return DIV_MAX_LATENCY / 2 + 1;
      3: return DIV_MAX_LATENCY + 1;
      4: return FP_EN ? FP_FDIV_S_LAT + 1 : 1;
      5: return FP_EN ? FP_FDIV_D_LAT + 1 : 1;
      6: return FP_EN ? FP_FSQRT_S_LAT + 1 : 1;
      7: return FP_EN ? FP_FSQRT_D_LAT + 1 : 1;
      8: return FP_EN ? FP_FMA_LAT : 1;
      9: return FP_EN ? FP_MISC_LAT : 1;
      10: return FP_EN ? FP_I2F_LAT : 1;
      default: return 1;
    endcase
  endfunction
  // FP register-file write latency of a class (the divide classes finish one cycle after their wake-up latency; the FP write
  // happens at the latency); 0 for a class that does not write the FP file
  function automatic int fp_cls_lat(input int c);
    if (!FP_EN || c < 4) return 0;
    else if (c <= 7) return wb_cls_off(c) - 1;
    else return wb_cls_off(c);
  endfunction
  // can issue port p complete a uop of class c (its capability includes the class's unit)
  function automatic bit port_serves_cls(input int p, input int c);
    case (c)
      0: return 1'b1;
      1: return (port_cap(p) & MASK_MUL) != '0;
      2, 3: return (port_cap(p) & MASK_DIV) != '0;
      4, 5, 6, 7: return FP_EN && (port_cap(p) & MASK_FDIV) != '0;
      8: return FP_EN && (port_cap(p) & MASK_FMA) != '0;
      9: return FP_EN && (port_cap(p) & MASK_FMISC) != '0;
      10: return FP_EN && (port_cap(p) & MASK_I2F) != '0;
      default: return 1'b0;
    endcase
  endfunction

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
