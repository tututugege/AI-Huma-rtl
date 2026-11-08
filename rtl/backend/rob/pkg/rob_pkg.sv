// Ref: back-end/Rob.cpp  class Rob  (types, constants and pure functions shared by the rob_* modules)
`default_nettype none

// waiver (reviewed): a package is linted standalone, where its constants and the whole-struct arguments of its
// classification functions look unused; every one of them is used by the rob_* modules.
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
package rob_pkg;
  import ttg_cfg_pkg::*;

  // ---- widths that the reference model derives in C++ but ttg_cfg_pkg does not export ----
  // ebreak: legacy (reference) behaviour is a flush without cause (the simulator ends on it); with TTG_EBREAK_TRAP it
  // raises a breakpoint exception (cause 3, mtval = pc), which OpenSBI's semihosting probe needs (Linux boot).
`ifdef TTG_EBREAK_TRAP
  localparam bit EBREAK_TRAP = 1'b1;
`else
  localparam bit EBREAK_TRAP = 1'b0;
`endif
  localparam int ROB_LINE_IDX_W = $clog2(ROB_LINE_NUM);
  localparam int ROB_BANK_IDX_W = $clog2(ROB_BANK_NUM);
  localparam int INST_TYPE_COUNT = 20;  // enum InstType (types.h): NOP .. FP
  localparam int INST_TYPE_W = $clog2(INST_TYPE_COUNT);
  localparam int UOP_TYPE_COUNT = 18;  // enum UopType (base_types.h): UOP_JUMP .. UOP_FP
  localparam int UOP_TYPE_W = $clog2(UOP_TYPE_COUNT);
  localparam int CPLT_W = 3;  // ROB_CPLT_MASK_WIDTH: one completion bit per uop group G0/G1/G2
  localparam int XLEN = 32;
  localparam int FUNC7_W = 7;

  // ---- InstType encodings (types.h) ----
  localparam logic [INST_TYPE_W-1:0] ITYPE_CSR = INST_TYPE_W'(7);
  localparam logic [INST_TYPE_W-1:0] ITYPE_FENCE = INST_TYPE_W'(8);
  localparam logic [INST_TYPE_W-1:0] ITYPE_ECALL = INST_TYPE_W'(9);
  localparam logic [INST_TYPE_W-1:0] ITYPE_EBREAK = INST_TYPE_W'(10);
  localparam logic [INST_TYPE_W-1:0] ITYPE_WFI = INST_TYPE_W'(11);
  localparam logic [INST_TYPE_W-1:0] ITYPE_SFENCE_VMA = INST_TYPE_W'(12);
  localparam logic [INST_TYPE_W-1:0] ITYPE_FENCE_I = INST_TYPE_W'(13);
  localparam logic [INST_TYPE_W-1:0] ITYPE_MRET = INST_TYPE_W'(14);
  localparam logic [INST_TYPE_W-1:0] ITYPE_SRET = INST_TYPE_W'(15);

  // ---- UopType encodings used for branch detection (base_types.h) ----
  localparam logic [UOP_TYPE_W-1:0] UOP_JUMP = UOP_TYPE_W'(0);
  localparam logic [UOP_TYPE_W-1:0] UOP_BR = UOP_TYPE_W'(2);

  // ---- completion groups (ROB_CPLT_G0/1/2) ----
  localparam logic [CPLT_W-1:0] CPLT_G0 = CPLT_W'(1);
  localparam logic [CPLT_W-1:0] CPLT_G1 = CPLT_W'(2);
  localparam logic [CPLT_W-1:0] CPLT_G2 = CPLT_W'(4);

  // One ROB slot payload == RobStoredInst without dbg (valid is kept next to it, see rob_entry).
  typedef struct packed {
    logic [XLEN-1:0]           diag_val;
    logic [AREG_IDX_WIDTH-1:0] dest_areg;
    logic [AREG_IDX_WIDTH-1:0] src1_areg;
    logic [PRF_IDX_WIDTH-1:0]  dest_preg;
    logic [PRF_IDX_WIDTH-1:0]  old_dest_preg;
    logic                      me_elim;     // move elimination: allocated no register at rename
    logic                      dest_en;
    logic [FTQ_IDX_WIDTH-1:0]  ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic                      ftq_is_last;
    logic                      mispred;
    logic                      br_taken;
    logic [FUNC7_W-1:0]        func7;
    logic [XLEN-1:0]           imm;
    logic [ROB_IDX_WIDTH-1:0]  rob_idx;
    logic                      rob_flag;
    logic [STQ_IDX_WIDTH-1:0]  stq_idx;
    logic                      stq_flag;
    logic [CPLT_W-1:0]         pend_mask;  // completion groups still outstanding (expect_mask & ~cplt_mask)
    logic                      pf_inst;
    logic                      pf_load;
    logic                      pf_store;
    logic                      illegal_inst;
    logic                      flush_pipe;  // LSU_MEMSPEC: memory-order violator, flushes the younger ones at commit
    logic [INST_TYPE_W-1:0]    itype;
  } rob_entry_t;

  localparam int ROB_ENTRY_W = $bits(rob_entry_t);

  // One EXU write-back port (ExuRobIO::ExuRobEntry).
  typedef struct packed {
    logic                     valid;
    logic [XLEN-1:0]          diag_val;
    logic [XLEN-1:0]          result;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    logic                     mispred;
    logic                     br_taken;
    logic                     pf_inst;
    logic                     pf_load;
    logic                     pf_store;
    logic                     defer;       // LSU_MEMSPEC: speculative load write-back, completes later
    logic                     flush_pipe;
    logic [UOP_TYPE_W-1:0]    op;
  } rob_wb_t;

  // What one write-back port does to the slot it addresses (precomputed per port, see rob_make_event).
  typedef struct packed {
    logic                     valid;
    logic [ROB_IDX_WIDTH-1:0] rob_idx;
    logic [CPLT_W-1:0]        cplt_bit;
    logic                     diag_we;
    logic [XLEN-1:0]          diag_val;
    logic                     pf_inst;
    logic                     pf_load;
    logic                     pf_store;
    logic                     sta_clr_load;  // STA port with fault: drop pf_load if the slot has pf_store (AMO)
    logic                     br_we;
    logic                     br_mispred;
    logic                     br_taken;
    logic                     flush_pipe;
  } rob_event_t;

  // ---- classification of a stored instruction (Rob.cpp anonymous namespace) ----
  function automatic logic rob_is_page_fault(input rob_entry_t e);
    return e.pf_inst | e.pf_load | e.pf_store;
  endfunction

  function automatic logic rob_is_exception(input rob_entry_t e);
    return rob_is_page_fault(e) | e.illegal_inst | (e.itype == ITYPE_ECALL);
  endfunction

  function automatic logic rob_is_flush_inst(input rob_entry_t e);
    return (e.itype == ITYPE_CSR) | (e.itype == ITYPE_ECALL) | (e.itype == ITYPE_MRET) | (e.itype == ITYPE_SRET) |
           (e.itype == ITYPE_SFENCE_VMA) | (e.itype == ITYPE_FENCE_I) | (e.itype == ITYPE_EBREAK) |
           rob_is_exception(e) | e.flush_pipe;
  endfunction

  function automatic logic rob_is_fence_inst(input rob_entry_t e);
    return (e.itype == ITYPE_FENCE) | (e.itype == ITYPE_FENCE_I) | (e.itype == ITYPE_SFENCE_VMA);
  endfunction

  function automatic logic rob_is_wfi(input rob_entry_t e);
    return e.itype == ITYPE_WFI;
  endfunction

  function automatic logic rob_is_complete(input rob_entry_t e);
    return e.pend_mask == '0;
  endfunction

  // ---- write-back port -> completion group (rob_cplt_mask_from_issue_port, util.h) ----
  function automatic logic [CPLT_W-1:0] rob_port_cplt_bit(input int port);
    logic [CPLT_W-1:0] bit_g;
    bit_g = '0;
    if (port >= IQ_ALU_PORT_BASE && port < IQ_ALU_PORT_BASE + ALU_NUM) bit_g = CPLT_G0;
    if (port >= IQ_LD_PORT_BASE && port < IQ_LD_PORT_BASE + LSU_LOAD_WB_WIDTH) bit_g = CPLT_G0;
    if (port >= IQ_BR_PORT_BASE && port < IQ_BR_PORT_BASE + BRU_NUM) bit_g = CPLT_G1;
    if (port >= IQ_STA_PORT_BASE && port < IQ_STA_PORT_BASE + LSU_STA_COUNT) bit_g = CPLT_G1;
    if (port >= IQ_STD_PORT_BASE && port < IQ_STD_PORT_BASE + LSU_SDU_COUNT) bit_g = CPLT_G2;
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
    ev.diag_we = mem_port | is_br;
    ev.diag_val = (is_br | ~has_pf) ? wb.diag_val : wb.result;  // branch uop overrides; fault: result carries the tval
    ev.pf_inst = mem_port & wb.pf_inst;
    ev.pf_load = mem_port & wb.pf_load;
    ev.pf_store = mem_port & wb.pf_store;
    ev.sta_clr_load = is_sta & has_pf;
    ev.br_we = is_br;
    ev.br_mispred = wb.mispred;
    ev.br_taken = wb.br_taken;
    ev.flush_pipe = wb.flush_pipe;
    return ev;
  endfunction

  function automatic rob_entry_t rob_apply_event(input rob_entry_t cur, input rob_event_t ev);
    rob_entry_t nxt;
    nxt = cur;
    nxt.pend_mask = cur.pend_mask & ~ev.cplt_bit;
    if (ev.diag_we) nxt.diag_val = ev.diag_val;
    nxt.pf_inst = cur.pf_inst | ev.pf_inst;
    nxt.pf_load = cur.pf_load | ev.pf_load;
    nxt.pf_store = cur.pf_store | ev.pf_store;
    nxt.flush_pipe = cur.flush_pipe | ev.flush_pipe;
    if (ev.sta_clr_load && nxt.pf_store) nxt.pf_load = 1'b0;
    if (ev.br_we) begin
      nxt.mispred = ev.br_mispred;
      nxt.br_taken = ev.br_taken;
    end
    return nxt;
  endfunction

  // ---- ring arithmetic on line pointers ----
  function automatic logic [ROB_LINE_IDX_W-1:0] rob_line_inc(input logic [ROB_LINE_IDX_W-1:0] line);
    return (line == ROB_LINE_IDX_W'(ROB_LINE_NUM - 1)) ? '0 : line + ROB_LINE_IDX_W'(1);
  endfunction

  // number of steps going forward from `from` to reach `to` (0 .. ROB_LINE_NUM-1)
  function automatic logic [ROB_LINE_IDX_W-1:0] rob_line_dist(input logic [ROB_LINE_IDX_W-1:0] from,
                                                              input logic [ROB_LINE_IDX_W-1:0] to);
    return (to >= from) ? to - from : to + ROB_LINE_IDX_W'(ROB_LINE_NUM) - from;
  endfunction
endpackage

`default_nettype wire
