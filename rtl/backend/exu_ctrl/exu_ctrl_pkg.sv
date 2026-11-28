// Ref: back-end/Exu/Exu.cpp  Exu::init (port_mappings); back-end/Exu/include/ExuTypes.h  struct ExuInst
// (port capabilities: config.h GLOBAL_ISSUE_PORT_CONFIG, table in dis_pkg::issue_port_cap)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */  // constants package: not every constant is used by every module
package exu_ctrl_pkg;
  import ttg_cfg_pkg::*;

  import fp_pkg::*;

  // ---- micro-op classes: UopType encoding, width and set type are dis_pkg's (uop_op_e, UOP_TYPE_W, uop_set_t)
  typedef dis_pkg::uop_set_t xc_opset_t;      // one bit per UopType
  typedef logic [dis_pkg::UOP_TYPE_W-1:0] xc_op_t;

  // ---- FU kinds, in the order Exu::init creates them inside one issue port (= write-back priority) ----------
  localparam int XC_K_MUL   = 0;
  localparam int XC_K_DIV   = 1;
  localparam int XC_K_AGU   = 2;
  localparam int XC_K_STD   = 3;
  localparam int XC_K_BR    = 4;
  localparam int XC_K_I2F   = 5;       // integer -> FP: ahead of the ALU, which would otherwise starve it at the port
  localparam int XC_K_ALU   = 6;
  localparam int XC_K_CSR   = 7;
  localparam int XC_K_FMA   = 8;       // F/D units: pipelined FMA / MISC / I2F, iterative FDIV
  localparam int XC_K_FDIV  = 9;
  localparam int XC_K_FMISC = 10;
  localparam int XC_KINDS   = 11;

  function automatic xc_opset_t xc_kind_mask(int k);
    case (k)
      XC_K_MUL:   return xc_opset_t'(OP_MASK_MUL);
      XC_K_DIV:   return xc_opset_t'(OP_MASK_DIV);
      XC_K_AGU:   return xc_opset_t'(OP_MASK_LD | OP_MASK_STA);
      XC_K_STD:   return xc_opset_t'(OP_MASK_STD);
      XC_K_BR:    return xc_opset_t'(OP_MASK_BR);
      XC_K_ALU:   return xc_opset_t'(OP_MASK_ALU);
      XC_K_FMA:   return xc_opset_t'(OP_MASK_FMA);
      XC_K_FDIV:  return xc_opset_t'(OP_MASK_FDIV);
      XC_K_FMISC: return xc_opset_t'(OP_MASK_FMISC);
      XC_K_I2F:   return xc_opset_t'(OP_MASK_I2F);
      default:    return xc_opset_t'(OP_MASK_CSR);
    endcase
  endfunction

  // capability of issue port p (the table is dis_pkg::issue_port_cap) for FU kind k
  function automatic bit xc_port_has(int p, int k);
    return (dis_pkg::issue_port_cap(p) & xc_kind_mask(k)) != '0;
  endfunction

  // ---- FU numbering: fu_idx counts FUs port by port, kind by kind (Exu::units order), from the port masks ----
  function automatic int xc_port_fu_count_calc(int p);
    int n = 0;
    for (int k = 0; k < XC_KINDS; k++) n += int'(xc_port_has(p, k));
    return n;
  endfunction

  // the tables are computed once (packed byte vectors) and read by index: the derivation loops are not re-run per use
  typedef logic [ISSUE_WIDTH:0][7:0]       xc_base_tab_t;   // first fu_idx of port p; entry ISSUE_WIDTH = total
  typedef logic [TOTAL_FU_COUNT-1:0][7:0]  xc_fu_tab_t;

  function automatic xc_base_tab_t xc_build_base();
    xc_base_tab_t t;
    int n = 0;
    for (int p = 0; p <= ISSUE_WIDTH; p++) begin
      t[p] = 8'(n);
      if (p < ISSUE_WIDTH) n += xc_port_fu_count_calc(p);
    end
    return t;
  endfunction

  function automatic xc_fu_tab_t xc_build_port();
    xc_fu_tab_t t;
    int f = 0;
    t = '0;
    for (int p = 0; p < ISSUE_WIDTH; p++)
      for (int k = 0; k < XC_KINDS; k++)
        if (xc_port_has(p, k)) begin
          t[f] = 8'(p);
          f++;
        end
    return t;
  endfunction

  function automatic xc_fu_tab_t xc_build_kind();
    xc_fu_tab_t t;
    int f = 0;
    t = '0;
    for (int p = 0; p < ISSUE_WIDTH; p++)
      for (int k = 0; k < XC_KINDS; k++)
        if (xc_port_has(p, k)) begin
          t[f] = 8'(k);
          f++;
        end
    return t;
  endfunction

  localparam xc_base_tab_t XC_T_BASE = xc_build_base();
  localparam xc_fu_tab_t   XC_T_PORT = xc_build_port();
  localparam xc_fu_tab_t   XC_T_KIND = xc_build_kind();

  function automatic int xc_port_fu_count(int p);
    return int'(XC_T_BASE[p + 1]) - int'(XC_T_BASE[p]);
  endfunction

  function automatic int xc_port_fu_base(int p);        // first fu_idx of port p (p == ISSUE_WIDTH: total)
    return int'(XC_T_BASE[p]);
  endfunction

  function automatic int xc_fu_total();
    return int'(XC_T_BASE[ISSUE_WIDTH]);
  endfunction

  function automatic int xc_fu_port(int f);
    return int'(XC_T_PORT[f]);
  endfunction

  function automatic int xc_fu_kind(int f);
    return int'(XC_T_KIND[f]);
  endfunction

  function automatic bit xc_tables_match();
    return xc_fu_total() == TOTAL_FU_COUNT;
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

  // multi-cycle FUs (MUL, DIV: they hold instructions themselves): indexed in fu_idx order
  function automatic bit xc_is_mc_kind(int k);
    return (k == XC_K_MUL) || (k == XC_K_DIV);
  endfunction

  function automatic int xc_mc_count();
    int n = 0;
    for (int f = 0; f < xc_fu_total(); f++) n += int'(xc_is_mc_kind(xc_fu_kind(f)));
    return n;
  endfunction

  function automatic int xc_mc_rank(int f);
    int n = 0;
    for (int g = 0; g < f; g++) if (xc_is_mc_kind(xc_fu_kind(g))) n = n + 1;
    return n;
  endfunction

  function automatic int xc_mc_fu(int r);
    int fu = 0;
    for (int f = 0; f < xc_fu_total(); f++) if (xc_is_mc_kind(xc_fu_kind(f)) && xc_mc_rank(f) == r) fu = f;
    return fu;
  endfunction

  // fixed micro-op of a multi-cycle FU kind (their op set has a single member)
  function automatic int xc_mc_op(int k);
    return (k == XC_K_MUL) ? int'(dis_pkg::UOP_MUL) : int'(dis_pkg::UOP_DIV);
  endfunction

  // F/D units: indexed in fu_idx order like the multi-cycle ones (they have their own flat port group)
  function automatic int xc_is_fp_kind(int k);
    return (k == XC_K_FMA || k == XC_K_FDIV || k == XC_K_FMISC || k == XC_K_I2F) ? 1 : 0;
  endfunction

  function automatic int xc_fp_count();
    int n = 0;
    for (int f = 0; f < xc_fu_total(); f++) if (xc_is_fp_kind(xc_fu_kind(f)) != 0) n = n + 1;
    return n;
  endfunction

  function automatic int xc_fp_rank(int f);
    int n = 0;
    for (int g = 0; g < f; g++) if (xc_is_fp_kind(xc_fu_kind(g)) != 0) n = n + 1;
    return n;
  endfunction

  function automatic int xc_fp_fu(int r);
    int fu = 0;
    for (int f = 0; f < xc_fu_total(); f++) if ((xc_is_fp_kind(xc_fu_kind(f)) != 0) && xc_fp_rank(f) == r) fu = f;
    return fu;
  endfunction

  // fixed micro-op of an F/D unit kind
  function automatic int xc_fp_op(int k);
    case (k)
      XC_K_FMA: return int'(dis_pkg::UOP_FMA);
      XC_K_FDIV: return int'(dis_pkg::UOP_FDIV);
      XC_K_FMISC: return int'(dis_pkg::UOP_FMISC);
      default: return int'(dis_pkg::UOP_I2F);
    endcase
  endfunction

  localparam int N_FU  = TOTAL_FU_COUNT;
  localparam int N_MC  = 3;                   // MUL x2, DIV x1
  localparam int N_FPU = 8;                   // F/D units: FMA x2, FMISC x3, FDIV, I2F x2
  localparam int N_AGU = LSU_AGU_COUNT;       // 5 physical AGUs (ports 6..10: 2 LD, 2 LD|STA, 1 STA)
  localparam int N_SDU = LSU_SDU_COUNT;

  // fu_idx of the i-th physical AGU
  function automatic int xc_agu_fu(int i);
    return xc_kind_fu(XC_K_AGU, i);
  endfunction
  localparam int CSR_FU = 2;                  // the only CSR FU (fu_idx 2, port 0); checked in exu_ctrl.sv
  localparam int CSR_PORT = 0;

  // instruction is strictly younger than the mispredicted branch (Exu.cpp is_br_killed)
  function automatic logic xc_killed(logic mispred, logic [ROB_IDX_WIDTH-1:0] rob_idx, logic rob_flag,
                                     logic [ROB_IDX_WIDTH-1:0] kill_rob_idx, logic kill_rob_flag);
    return mispred && ((rob_flag == kill_rob_flag) ? (rob_idx > kill_rob_idx) : (rob_idx < kill_rob_idx));
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
    logic [XLEN_BITS-1:0]              pc;
    logic                     ftq_pred_taken;
    logic                     ftq_is_rvc;
    logic [XLEN_BITS-1:0]              ftq_next_pc;
    logic [PRF_IDX_WIDTH-1:0] dest_preg;
    logic [XLEN_BITS-1:0]              src1_rdata;
    logic [XLEN_BITS-1:0]              src2_rdata;
    logic [FW-1:0]            fsrc1;       // F/D operands read from the FP register file
    logic [FW-1:0]            fsrc2;
    logic [FW-1:0]            fsrc3;
    logic [FTQ_IDX_WIDTH-1:0] ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic                     is_atomic;
    logic                     dest_en;
    logic                     src1_en;
    logic                     src1_is_pc;
    logic                     src2_is_imm;
    logic                     is_word;
    logic [2:0]               func3;
    logic [6:0]               func7;
    logic [31:0]              imm;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    logic [STQ_IDX_WIDTH-1:0] stq_idx;
    logic                     stq_flag;
    logic [LDQ_IDX_WIDTH-1:0] ldq_idx;
    logic                     rob_flag;
    xc_op_t                   op;
  } xc_inst_t;

  // what the FU instances hand back for one FU (zero in the fields a FU kind does not produce)
  typedef struct packed {
    logic                     mc_complete;
    logic [XLEN_BITS-1:0]              result;
    logic [FW-1:0]            fresult;     // F/D: 64-bit result (the FP register write data)
    logic [FFLAGS_W-1:0]      fflags;
    logic                     illegal;
    logic [PRF_IDX_WIDTH-1:0] dest_preg;
    logic                     dest_en;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    logic                     rob_flag;
    logic [XLEN_BITS-1:0]              diag_val;
    logic                     mispred;
    logic                     br_taken;
  } xc_fu_res_t;

  // a finished FU result as seen by arbitration / write-back / bypass (one per FU, uniform)
  typedef struct packed {
    logic                     complete;
    logic [XLEN_BITS-1:0]              result;
    logic [FW-1:0]            fresult;
    logic [FFLAGS_W-1:0]      fflags;
    logic                     illegal;
    logic [PRF_IDX_WIDTH-1:0] dest_preg;
    logic                     dest_en;
    xc_op_t                   op;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    logic                     rob_flag;
    logic [XLEN_BITS-1:0]              diag_val;
    logic                     mispred;
    logic                     br_taken;
    logic [FTQ_IDX_WIDTH-1:0] ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic [XLEN_BITS-1:0]      pc; // pc of the instruction (the mispredicted branch: BPU history repair)
    logic                     is_rvc;      // 16-bit instruction (RVC=1): BPU repair needs the length
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
    logic [XLEN_BITS-1:0]              diag_val;
    logic [XLEN_BITS-1:0]              result;
    logic [PRF_IDX_WIDTH-1:0] dest_preg;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    logic                     rob_flag;
    logic                     dest_en;
    logic                     page_fault_load;
    logic                     page_fault_store;
    logic                     rob_defer;       // the ROB completion of the load is deferred
    logic                     flush_pipe;      // final write-back of a violating load
    logic                     is_w;            // word load (flw data is NaN-boxed)
  } xc_lsu_wb_t;

  // One register write-back lane sent from EXU to PRF (WB_LANES total).
  typedef struct packed {
    logic                     valid;
    logic [PRF_IDX_WIDTH-1:0] dest_preg;
    logic [XLEN_BITS-1:0]     result;
    logic [FW-1:0]            fresult;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    logic                     rob_flag;
    logic                     dest_en;
    xc_op_t                   op;
  } xc_prf_wb_t;

  // One completion report sent from EXU to ROB (ROB_WB_WIDTH total).
  typedef struct packed {
    logic                     valid;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    xc_op_t                   op;
    logic [XLEN_BITS-1:0]     result;
    logic                     br_taken;
    logic                     page_fault_load;
    logic                     page_fault_store;
    logic                     rob_defer;
    logic                     flush_pipe;
    logic [FFLAGS_W-1:0]      fflags;
    logic                     illegal;
  } xc_rob_wb_t;

  // One AGU request sent from EXU to LSU (LSU_AGU_COUNT total).
  typedef struct packed {
    logic                     valid;
    logic                     raw;
    xc_op_t                   op;
    logic [XLEN_BITS-1:0]     result;
    logic [PRF_IDX_WIDTH-1:0] dest_preg;
    logic [2:0]               func3;
    logic                     is_atomic;
    logic [4:0]               amo_op;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    logic                     rob_flag;
    logic [STQ_IDX_WIDTH-1:0] stq_idx;
    logic                     stq_flag;
    logic [LDQ_IDX_WIDTH-1:0] ldq_idx;
  } xc_agu_req_t;

endpackage
`default_nettype wire
