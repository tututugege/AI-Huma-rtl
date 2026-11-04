// Ref: back-end/Exu/Exu.cpp  Exu::init (port_mappings); back-end/Exu/include/ExuTypes.h  struct ExuInst
// (port capabilities: config.h GLOBAL_ISSUE_PORT_CONFIG)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */  // constants package: not every constant is used by every module
package exu_ctrl_pkg;
  import ttg_cfg_pkg::*;

  // ---- micro-op classes (base_types.h UopType) -------------------------------------------------------------------
  localparam int XC_OP_W = 5;        // UOP_TYPE_WIDTH
  localparam int XC_OP_NUM = 18;     // MAX_UOP_TYPE
  localparam int XC_UOP_LOAD = 3;
  localparam int XC_UOP_STA = 4;
  localparam int XC_UOP_MUL = 14;
  localparam int XC_UOP_DIV = 15;
  localparam int XC_UOP_FP = 17;
  typedef logic [XC_OP_NUM-1:0] xc_opset_t;   // one bit per UopType
  typedef logic [XC_OP_W-1:0]   xc_op_t;

  // ---- FU kinds, in the order Exu::init creates them inside one issue port (= write-back priority) ----------
  localparam int XC_K_MUL = 0;
  localparam int XC_K_DIV = 1;
  localparam int XC_K_LD  = 2;
  localparam int XC_K_STA = 3;
  localparam int XC_K_STD = 4;
  localparam int XC_K_BR  = 5;
  localparam int XC_K_ALU = 6;
  localparam int XC_K_CSR = 7;
  localparam int XC_K_FP  = 8;
  localparam int XC_KINDS = 9;

  function automatic xc_opset_t xc_kind_mask(int k);
    case (k)
      XC_K_MUL: return xc_opset_t'(OP_MASK_MUL);
      XC_K_DIV: return xc_opset_t'(OP_MASK_DIV);
      XC_K_LD:  return xc_opset_t'(OP_MASK_LD);
      XC_K_STA: return xc_opset_t'(OP_MASK_STA);
      XC_K_STD: return xc_opset_t'(OP_MASK_STD);
      XC_K_BR:  return xc_opset_t'(OP_MASK_BR);
      XC_K_ALU: return xc_opset_t'(OP_MASK_ALU);
      XC_K_CSR: return xc_opset_t'(OP_MASK_CSR);
      default:  return xc_opset_t'(OP_MASK_FP);
    endcase
  endfunction

  // capability mask of issue port p (config.h GLOBAL_ISSUE_PORT_CONFIG; CSR is hard-bound to port 0)
  function automatic xc_opset_t xc_port_cap(int p);
    case (p)
      0: return xc_opset_t'(OP_MASK_ALU | OP_MASK_MUL | OP_MASK_CSR);
      1: return xc_opset_t'(OP_MASK_ALU | OP_MASK_DIV | OP_MASK_FP);
      2: return xc_opset_t'(OP_MASK_ALU | OP_MASK_MUL);
      3: return xc_opset_t'(OP_MASK_ALU | OP_MASK_DIV);
      4, 5: return xc_opset_t'(OP_MASK_ALU);
      default: begin
        if (p >= IQ_BR_PORT_BASE) return xc_opset_t'(OP_MASK_BR);
        else if (p >= IQ_STD_PORT_BASE) return xc_opset_t'(OP_MASK_STD);
        else if (p >= IQ_STA_PORT_BASE) return xc_opset_t'(OP_MASK_STA);
        else return xc_opset_t'(OP_MASK_LD);
      end
    endcase
  endfunction

  function automatic bit xc_port_has(int p, int k);
    return (xc_port_cap(p) & xc_kind_mask(k)) != '0;
  endfunction

  // ---- FU numbering: fu_idx counts FUs port by port, kind by kind (Exu::units order) ---------------------
  // The FU numbering of Exu::init for this configuration, written out (cheap to evaluate); the checks in exu_ctrl.sv
  // compare it with the structural derivation (xc_check_*) from the port capabilities.
  function automatic int xc_fu_kind(int f);
    case (f)
      0, 6:        return XC_K_MUL;
      3, 8:        return XC_K_DIV;
      5:           return XC_K_FP;
      2:           return XC_K_CSR;
      1, 4, 7, 9, 10, 11: return XC_K_ALU;
      12, 13, 14, 15: return XC_K_LD;
      16, 17, 18, 19: return XC_K_STA;
      20, 21, 22, 23: return XC_K_STD;
      default:     return XC_K_BR;
    endcase
  endfunction

  function automatic int xc_port_fu_base(int p);        // first fu_idx of port p (p == ISSUE_WIDTH: total)
    case (p)
      0: return 0;
      1: return 3;
      2: return 6;
      3: return 8;
      4: return 10;
      5: return 11;
      default: return 12 + (p - 6);
    endcase
  endfunction

  function automatic int xc_port_fu_count(int p);
    return xc_port_fu_base(p + 1) - xc_port_fu_base(p);
  endfunction

  function automatic int xc_fu_total();
    return xc_port_fu_base(ISSUE_WIDTH);
  endfunction

  function automatic int xc_fu_port(int f);
    return (f < 12) ? ((f < 3) ? 0 : ((f < 6) ? 1 : ((f < 8) ? 2 : ((f < 10) ? 3 : (f - 6))))) : (f - 6);
  endfunction

  // structural derivation of the same tables from the port capability masks (used only by the configuration check)
  function automatic int xc_check_port_count(int p);
    int n = 0;
    for (int k = 0; k < XC_KINDS; k++) n += int'(xc_port_has(p, k));
    return n;
  endfunction

  function automatic bit xc_tables_match();
    bit ok = 1'b1;
    int base = 0;
    for (int p = 0; p < ISSUE_WIDTH; p++) begin
      int seen = 0;
      ok &= (xc_port_fu_base(p) == base) && (xc_port_fu_count(p) == xc_check_port_count(p));
      for (int k = 0; k < XC_KINDS; k++) begin
        if (xc_port_has(p, k)) begin
          ok &= (xc_fu_kind(base + seen) == k) && (xc_fu_port(base + seen) == p);
          seen++;
        end
      end
      base += seen;
    end
    return ok && (xc_fu_total() == base);
  endfunction

  // number of FUs of kind k / index of the FU f among the FUs of its own kind / fu_idx of the r-th FU of kind k
  function automatic int xc_kind_count(int k);
    int n = 0;
    for (int f = 0; f < xc_fu_total(); f++) n += int'(xc_fu_kind(f) == k);
    return n;
  endfunction

  function automatic int xc_kind_rank(int f);
    int n = 0;
    for (int g = 0; g < f; g++) n += int'(xc_fu_kind(g) == xc_fu_kind(f));
    return n;
  endfunction

  function automatic int xc_kind_fu(int k, int r);
    int fu = 0;
    for (int f = 0; f < xc_fu_total(); f++) if (xc_fu_kind(f) == k && xc_kind_rank(f) == r) fu = f;
    return fu;
  endfunction

  // multi-cycle FUs (MUL, DIV, FP: they hold instructions themselves): indexed in fu_idx order
  function automatic bit xc_is_mc_kind(int k);
    return (k == XC_K_MUL) || (k == XC_K_DIV) || (k == XC_K_FP);
  endfunction

  function automatic int xc_mc_count();
    int n = 0;
    for (int f = 0; f < xc_fu_total(); f++) n += int'(xc_is_mc_kind(xc_fu_kind(f)));
    return n;
  endfunction

  function automatic int xc_mc_rank(int f);
    int n = 0;
    for (int g = 0; g < f; g++) n += int'(xc_is_mc_kind(xc_fu_kind(g)));
    return n;
  endfunction

  function automatic int xc_mc_fu(int r);
    int fu = 0;
    for (int f = 0; f < xc_fu_total(); f++) if (xc_is_mc_kind(xc_fu_kind(f)) && xc_mc_rank(f) == r) fu = f;
    return fu;
  endfunction

  // fixed micro-op of a multi-cycle FU kind (their op set has a single member)
  function automatic int xc_mc_op(int k);
    return (k == XC_K_MUL) ? XC_UOP_MUL : ((k == XC_K_DIV) ? XC_UOP_DIV : XC_UOP_FP);
  endfunction

  localparam int N_FU  = TOTAL_FU_COUNT;
  localparam int N_MC  = 5;                   // MUL x2, DIV x2, FP
  localparam int N_AGU = LSU_AGU_COUNT;       // load AGUs 0..3, store-address AGUs 4..7 (= LSU agu ports)
  localparam int N_SDU = LSU_SDU_COUNT;

  // fu_idx of the i-th AGU: load AGUs first, then store-address AGUs (the LSU agu port numbering)
  function automatic int xc_agu_fu(int i);
    return (i < LSU_LDU_COUNT) ? xc_kind_fu(XC_K_LD, i) : xc_kind_fu(XC_K_STA, i - LSU_LDU_COUNT);
  endfunction
  localparam int CSR_FU = 2;                  // the only CSR FU (fu_idx 2, port 0); checked in exu_ctrl.sv
  localparam int CSR_PORT = 0;

  // the instruction's br_mask intersects the mispredicted branch (Exu.cpp is_br_killed)
  function automatic logic xc_killed(logic mispred, logic [BR_MASK_WIDTH-1:0] br_mask,
                                     logic [BR_MASK_WIDTH-1:0] kill_mask);
    return mispred && ((br_mask & kill_mask) != '0);
  endfunction

  // instruction o is older than instruction y: the 8-bit {rob_flag, rob_idx} age gap y - o lies in (0, ROB_NUM)
  // (Exu.cpp cmp_inst_age(y, o): flags equal -> the smaller idx is older, flags differ -> the larger idx is older)
  function automatic logic xc_older(logic o_flag, logic [ROB_IDX_WIDTH-1:0] o_idx,
                                    logic y_flag, logic [ROB_IDX_WIDTH-1:0] y_idx);
    logic [ROB_IDX_WIDTH:0] gap = {y_flag, y_idx} - {o_flag, o_idx};
    return !gap[ROB_IDX_WIDTH] && (gap[ROB_IDX_WIDTH-1:0] != '0);
  endfunction

  // ---- an instruction held in a FU input slot (ExuInst fields that have a reader) -----------------------
  typedef struct packed {
    logic [31:0]              pc;
    logic                     ftq_pred_taken;
    logic [31:0]              ftq_next_pc;
    logic [PRF_IDX_WIDTH-1:0] dest_preg;
    logic [31:0]              src1_rdata;
    logic [31:0]              src2_rdata;
    logic [FTQ_IDX_WIDTH-1:0] ftq_idx;
    logic                     is_atomic;
    logic                     dest_en;
    logic                     src1_en;
    logic                     src1_is_pc;
    logic                     src2_is_imm;
    logic [2:0]               func3;
    logic [6:0]               func7;
    logic [31:0]              imm;
    logic [BR_TAG_WIDTH-1:0]  br_id;
    logic [BR_MASK_WIDTH-1:0] br_mask;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    logic [STQ_IDX_WIDTH-1:0] stq_idx;
    logic                     stq_flag;
    logic [LDQ_IDX_WIDTH-1:0] ldq_idx;
    logic                     rob_flag;
    xc_op_t                   op;
  } xc_inst_t;

  // what the FU instances hand back for one FU (zero in the fields a FU kind does not produce)
  typedef struct packed {
    logic                     mc_ready;
    logic                     mc_complete;
    logic [31:0]              result;
    logic [PRF_IDX_WIDTH-1:0] dest_preg;
    logic                     dest_en;
    logic [BR_MASK_WIDTH-1:0] br_mask;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    logic [31:0]              diag_val;
    logic                     mispred;
    logic                     br_taken;
  } xc_fu_res_t;

  // a finished FU result as seen by arbitration / write-back / bypass (one per FU, uniform)
  typedef struct packed {
    logic                     complete;
    logic [31:0]              result;
    logic [PRF_IDX_WIDTH-1:0] dest_preg;
    logic                     dest_en;
    logic [BR_MASK_WIDTH-1:0] br_mask;
    xc_op_t                   op;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    logic                     rob_flag;
    logic [31:0]              diag_val;
    logic                     mispred;
    logic                     br_taken;
    logic [BR_TAG_WIDTH-1:0]  br_id;
    logic [FTQ_IDX_WIDTH-1:0] ftq_idx;
    logic [2:0]               func3;
    logic [4:0]               amo_op;      // func7[6:2]
    logic                     is_atomic;
    logic [STQ_IDX_WIDTH-1:0] stq_idx;
    logic                     stq_flag;
    logic [LDQ_IDX_WIDTH-1:0] ldq_idx;
  } xc_done_t;

  // a Lsu write-back request (loads, SC, store-address)
  typedef struct packed {
    logic                     valid;
    logic [31:0]              diag_val;
    logic [31:0]              result;
    logic [PRF_IDX_WIDTH-1:0] dest_preg;
    logic [BR_MASK_WIDTH-1:0] br_mask;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    logic                     dest_en;
    logic                     page_fault_load;
    logic                     page_fault_store;
  } xc_lsu_wb_t;

endpackage
`default_nettype wire
