// Ref: back-end/Rob.cpp  class Rob  (types, constants and pure functions shared by the rob_* modules)
`default_nettype none

// waiver (reviewed): a package is linted standalone, where its constants and the whole-struct arguments of its
// classification functions look unused; every one of them is used by the rob_* modules.
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
package rob_pkg;
  import ttg_cfg_pkg::*;
  import dis_pkg::INST_CSR, dis_pkg::INST_EBREAK, dis_pkg::INST_ECALL, dis_pkg::INST_FENCE, dis_pkg::INST_FENCE_I,
         dis_pkg::INST_MRET, dis_pkg::INST_SFENCE_VMA, dis_pkg::INST_SRET, dis_pkg::INST_TYPE_W, dis_pkg::INST_WFI,
         dis_pkg::UOP_BR, dis_pkg::UOP_JUMP, dis_pkg::UOP_TYPE_W;

  // ---- widths that the reference model derives in C++ but ttg_cfg_pkg does not export ----
  localparam int ROB_LINE_IDX_W = $clog2(ROB_LINE_NUM);
  localparam int ROB_BANK_IDX_W = $clog2(ROB_BANK_NUM);
  localparam int CPLT_W = 3;  // ROB_CPLT_MASK_WIDTH: one completion bit per uop group G0/G1/G2
  localparam int ROB_XLEN = XLEN_BITS;

  // (InstType / UopType encodings and widths: dis_pkg inst_type_e / uop_op_e, INST_TYPE_W / UOP_TYPE_W)

  // ---- completion groups (ROB_CPLT_G0/1/2) ----
  localparam logic [CPLT_W-1:0] CPLT_G0 = CPLT_W'(1);
  localparam logic [CPLT_W-1:0] CPLT_G1 = CPLT_W'(2);
  localparam logic [CPLT_W-1:0] CPLT_G2 = CPLT_W'(4);

  // One ROB slot payload (slimmer than RobStoredInst: diag_val moved to FTQ + single oldest_trap reg,
  // imm/src1_areg compressed to 1b is_ret, func7 compressed to 1b is_amo_lr, rob_idx implicit from ENTRY_IDX).
  typedef struct packed {
    logic [AREG_IDX_WIDTH-1:0] dest_areg;
    logic                      dest_fp;     // F/D: FP destination (commit sets mstatus.FS dirty)
    logic                      dest_en;
    logic [FTQ_IDX_WIDTH-1:0]  ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic                      ftq_is_last;
    logic                      br_taken;
    logic                      is_ret;      // jalr x0, 0(ra): pre-decoded for BPU commit training
    logic                      is_amo_lr;   // func7[6:2] == AMO_LR: pre-decoded for LSU STQ commit
    logic                      rob_flag;
    logic [STQ_IDX_WIDTH-1:0]  stq_idx;
    logic                      stq_flag;
    logic [CPLT_W-1:0]         pend_mask;  // completion groups still outstanding (expect_mask & ~cplt_mask)
    logic                      pf_inst;
    logic                      pf_inst_hi;
    logic                      pf_load;
    logic                      pf_store;
    logic                      illegal_inst;
    logic                      fs_need;     // F/D: needs mstatus.FS != Off (FP instruction, FP load / store, FP CSR)
    logic [4:0]                fflags;      // F/D: exception flags, accrued into fcsr at commit
    logic                      flush_pipe;  // memory-order violator, flushes the younger ones at commit
    logic [INST_TYPE_W-1:0]    itype;
  } rob_entry_t;

  localparam int ROB_ENTRY_W = $bits(rob_entry_t);

  // One EXU write-back port (ExuRobIO::ExuRobEntry).
  typedef struct packed {
    logic                     valid;
    logic [ROB_XLEN-1:0]      result;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    logic                     br_taken;
    logic                     pf_inst;
    logic                     pf_load;
    logic                     pf_store;
    logic                     defer;       // speculative load write-back, completes later
    logic                     flush_pipe;
    logic                     illegal;     // F/D: found illegal at execute (reserved encoding / rounding mode)
    logic [4:0]               fflags;
    logic                     fs_off;      // mstatus.FS == Off now (committed state)
    logic [UOP_TYPE_W-1:0]    op;
  } rob_wb_t;

  // What one write-back port does to the slot it addresses (precomputed per port, no 64-bit payload).
  typedef struct packed {
    logic                     valid;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    logic [CPLT_W-1:0]        cplt_bit;
    logic                     pf_inst;
    logic                     pf_load;
    logic                     pf_store;
    logic                     sta_clr_load;  // STA port with fault: drop pf_load if the slot has pf_store (AMO)
    logic                     br_we;
    logic                     br_taken;
    logic                     flush_pipe;
    logic                     illegal;
    logic [4:0]               fflags;
    logic                     fs_off;
  } rob_event_t;

  // ---- classification of a stored instruction (Rob.cpp anonymous namespace) ----
  function automatic logic rob_is_page_fault(input rob_entry_t e);
    return e.pf_inst | e.pf_load | e.pf_store;
  endfunction

  function automatic logic rob_is_exception(input rob_entry_t e);
    return rob_is_page_fault(e) | e.illegal_inst | (e.itype == INST_ECALL);
  endfunction

  function automatic logic rob_is_flush_inst(input rob_entry_t e);
    return (e.itype == INST_CSR) | (e.itype == INST_ECALL) | (e.itype == INST_MRET) | (e.itype == INST_SRET) |
           (e.itype == INST_SFENCE_VMA) | (e.itype == INST_FENCE_I) | (e.itype == INST_EBREAK) |
           rob_is_exception(e) | e.flush_pipe;
  endfunction

  function automatic logic rob_is_fence_inst(input rob_entry_t e);
    return (e.itype == INST_FENCE) | (e.itype == INST_FENCE_I) | (e.itype == INST_SFENCE_VMA);
  endfunction

  function automatic logic rob_is_wfi(input rob_entry_t e);
    return e.itype == INST_WFI;
  endfunction

  function automatic logic rob_is_complete(input rob_entry_t e);
    return e.pend_mask == '0;
  endfunction

  // ---- write-back channel -> completion group (rob_cplt_mask_from_issue_port, util.h) ----
  function automatic logic [CPLT_W-1:0] rob_port_cplt_bit(input int port);
    logic [CPLT_W-1:0] bit_g;
    bit_g = '0;
    if (port >= ROB_WB_ALU_BASE && port < ROB_WB_ALU_BASE + ALU_NUM)           bit_g = CPLT_G0;
    if (port >= ROB_WB_LD_BASE  && port < ROB_WB_LD_BASE  + LSU_LOAD_WB_WIDTH) bit_g = CPLT_G0;
    if (port >= ROB_WB_STA_BASE && port < ROB_WB_STA_BASE + LSU_STA_COUNT)     bit_g = CPLT_G1;
    if (port >= ROB_WB_STD_BASE && port < ROB_WB_STD_BASE + LSU_SDU_COUNT)     bit_g = CPLT_G2;
    if (port >= ROB_WB_BR_BASE  && port < ROB_WB_BR_BASE  + BRU_NUM)           bit_g = CPLT_G1;
    if (port >= ROB_WB_FP_BASE)                                                 bit_g = CPLT_G0;   // F/D: like INT / LD
    return bit_g;
  endfunction

  // ---- Rob::comb_complete body for one port, split into "what the port does" (this) and "apply it" (below) ----
  function automatic rob_event_t rob_make_event(input rob_wb_t wb, input logic is_ld, input logic is_sta,
                                                input logic [CPLT_W-1:0] cplt_bit);
    rob_event_t ev;
    logic has_pf;
    logic is_br;
    logic mem_port;
    has_pf = wb.pf_inst | wb.pf_load | wb.pf_store;
    is_br = (wb.op == UOP_JUMP) | (wb.op == UOP_BR);
    mem_port = is_ld | is_sta;
    ev.valid = wb.valid & ~wb.defer;   // a deferred write-back changes nothing in the slot
    ev.rob_idx = wb.rob_idx;
    ev.cplt_bit = cplt_bit;
    ev.pf_inst = mem_port & wb.pf_inst;
    ev.pf_load = mem_port & wb.pf_load;
    ev.pf_store = mem_port & wb.pf_store;
    ev.sta_clr_load = is_sta & has_pf;
    ev.br_we = is_br;
    ev.br_taken = wb.br_taken;
    ev.flush_pipe = wb.flush_pipe;
    ev.illegal = wb.illegal;
    ev.fflags = wb.fflags;
    ev.fs_off = wb.fs_off;
    return ev;
  endfunction

  function automatic rob_entry_t rob_apply_event(input rob_entry_t cur, input rob_event_t ev);
    rob_entry_t nxt;
    nxt = cur;
    nxt.pend_mask = cur.pend_mask & ~ev.cplt_bit;
    nxt.pf_inst = cur.pf_inst | ev.pf_inst;
    nxt.pf_load = cur.pf_load | ev.pf_load;
    nxt.pf_store = cur.pf_store | ev.pf_store;
    nxt.flush_pipe = cur.flush_pipe | ev.flush_pipe;
    // F/D: the FS = Off check is made when the instruction completes, against the committed mstatus (CSR writes and
    // traps flush the younger instructions, so a stale FS can only be seen by instructions that are discarded)
    nxt.illegal_inst = cur.illegal_inst | ev.illegal | (cur.fs_need & ev.fs_off);
    nxt.fflags = cur.fflags | ev.fflags;
    if (ev.sta_clr_load && nxt.pf_store) nxt.pf_load = 1'b0;
    if (ev.br_we) begin
      nxt.br_taken = ev.br_taken;
    end
    return nxt;
  endfunction

endpackage

`default_nettype wire
