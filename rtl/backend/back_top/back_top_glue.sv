// Ref: back-end/BackTop.cpp  BackTop::comb (tail: out.* and commit_entry), comb_lsu_mmu (mstatus fields), Idu.cpp:539 (store flag)
`default_nettype none

// The few behaviours of BackTop that belong to no sub-module (docs/modules/back_top.md, "Glue"):
//  * Back_out.{mispred, stall, redirect_pc}: what SimCpu/the front end see (BackTop.cpp:340-362)
//  * the flush-time override of the committed slots' diag_val with the redirect pc (BackTop.cpp:364-372); it is applied
//    only to the copy that leaves the back end (commit_entry), no back-end consumer reads diag_val of rob_commit
//  * the store flag the Idu computes (tma.mem_commit_is_store) that Ren/Dispatch do not carry: re-derived from type/func7
//  * the four mstatus bits the DTLB needs (LSU copies csr_status into lsu2mmu_io; here taken straight from Csr)
module back_top_glue
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  logic        rob_bcast_flush,
  input  logic        rob_bcast_mret,
  input  logic        rob_bcast_sret,
  input  logic        rob_bcast_exception,
  input  logic [31:0] rob_bcast_pc,
  input  logic [31:0] csr2front_epc,
  input  logic [31:0] csr2front_trap_pc,
  input  logic [31:0] br_latch_redirect_pc,
  input  logic        dec_bcast_mispred,
  input  logic        pre2front_ready,
  input  logic        rob_commit_commit_entry_valid [COMMIT_WIDTH],
  input  logic [31:0] rob_commit_commit_entry_uop_diag_val [COMMIT_WIDTH],
  input  logic [4:0]  dis2rob_uop_type [DECODE_WIDTH],
  input  logic [6:0]  dis2rob_uop_func7 [DECODE_WIDTH],
  input  logic [31:0] csr_status_mstatus,
  output logic        out_mispred,
  output logic        out_stall,
  output logic [31:0] out_redirect_pc,
  output logic [31:0] out_commit_entry_uop_diag_val [COMMIT_WIDTH],
  output logic        dis2rob_uop_tma_mem_commit_is_store [DECODE_WIDTH],
  output logic        csr_status_mstatus_mxr,
  output logic        csr_status_mstatus_sum,
  output logic        csr_status_mstatus_mprv,
  output logic [1:0]  csr_status_mstatus_mpp
);

  // Ref: BackTop::comb, "Normal case" / flush branch. Valid when out_mispred (SimCpu reads it only then).
  logic [31:0] flush_redirect_pc;
  always_comb begin
    if (rob_bcast_mret || rob_bcast_sret) flush_redirect_pc = csr2front_epc;
    else if (rob_bcast_exception)         flush_redirect_pc = csr2front_trap_pc;
    else                                  flush_redirect_pc = rob_bcast_pc + 32'd4;
  end

  assign out_mispred     = rob_bcast_flush | dec_bcast_mispred;
  assign out_stall       = ~pre2front_ready;
  assign out_redirect_pc = rob_bcast_flush ? flush_redirect_pc : br_latch_redirect_pc;

  // Ref: BackTop::comb, loop over COMMIT_WIDTH: valid slots get diag_val = redirect_pc while flushing
  for (genvar i = 0; i < COMMIT_WIDTH; i++) begin : g_commit
    assign out_commit_entry_uop_diag_val[i] = rob_bcast_flush ? out_redirect_pc : rob_commit_commit_entry_uop_diag_val[i];
  end
  // (rob_commit_commit_entry_valid only qualifies the diag_val in the boundary spec; the override itself is per slot)
  logic commit_valid_unused;  // lint: kept as a port so the glue's interface documents the qualification
  assign commit_valid_unused = rob_commit_commit_entry_valid[0];

  // Ref: Idu.cpp:539 mem_commit_is_store = STORE || (AMO && amo_op != LR); amo_op = func7[6:2]
  for (genvar i = 0; i < DECODE_WIDTH; i++) begin : g_store
    assign dis2rob_uop_tma_mem_commit_is_store[i] =
        (dis2rob_uop_type[i] == INST_TYPE_W'(INST_STORE)) ||
        ((dis2rob_uop_type[i] == INST_TYPE_W'(INST_AMO)) && (dis2rob_uop_func7[i][6:2] != AMO_LR));
  end

  // mstatus bits: MXR=19, SUM=18, MPRV=17, MPP=12:11 (TlbMmu.cpp / lsu2mmu_io.csr_status.mstatus)
  assign csr_status_mstatus_mxr  = csr_status_mstatus[19];
  assign csr_status_mstatus_sum  = csr_status_mstatus[18];
  assign csr_status_mstatus_mprv = csr_status_mstatus[17];
  assign csr_status_mstatus_mpp  = csr_status_mstatus[12:11];

  // the other mstatus bits are not read here (they leave the chip through csr_status_mstatus)
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] mstatus_other_bits;
  /* verilator lint_on UNUSEDSIGNAL */
  assign mstatus_other_bits = csr_status_mstatus & ~32'h000E_1800;

endmodule

`default_nettype wire
