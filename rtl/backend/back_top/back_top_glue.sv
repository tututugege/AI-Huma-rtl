// Ref: back-end/BackTop.cpp  BackTop::comb (tail: out.*, commit_entry), comb_lsu_mmu, Idu.cpp:539 (store flag)
`default_nettype none

// The few behaviours of BackTop that belong to no sub-module (docs/modules/back_top.md, "Glue"):
//  * Back_out.{mispred, stall, redirect_pc}: what SimCpu/the front end see (BackTop.cpp:340-362)
//  * the flush-time override of the committed slots' diag_val with the redirect pc (BackTop.cpp:364-372); it is applied
//    only to the copy that leaves the back end (commit_entry), no back-end consumer reads diag_val of rob_commit
//  * the four mstatus bits the DTLB needs (LSU copies csr_status into lsu2mmu_io; here taken straight from Csr)
module back_top_glue
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        rob_bcast_flush,   // the flush decided in this cycle
  input  logic        flush_q,           // the flush of the previous cycle: delivered to the front end now (FLUSH_REG)
  input  logic        rob_bcast_mret,
  input  logic        rob_bcast_sret,
  input  logic        rob_bcast_exception,
  input  logic [XLEN_BITS-1:0] rob_bcast_pc,
  input  logic        rob_bcast_is_rvc,   // the committing instruction is 16 bits (FTQ ROB-port response, with the pc)
  input  logic [XLEN_BITS-1:0] csr2front_epc,
  input  logic [XLEN_BITS-1:0] csr2front_trap_pc,
  input  logic [XLEN_BITS-1:0] br_latch_redirect_pc,
  input  logic [XLEN_BITS-1:0] br_latch_br_pc,
  input  logic br_latch_is_rvc,
  input  logic        dec_bcast_mispred,
  input  logic        pre2front_ready,
  input  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_valid,
  input  logic [XLEN_BITS-1:0] rob_commit_commit_entry_uop_diag_val [COMMIT_WIDTH],
  input  logic [XLEN_BITS-1:0] csr_status_mstatus,
  input  logic [6:0]  rob_commit_commit_entry_uop_func7 [COMMIT_WIDTH],
  output logic        out_mispred,
  output logic        out_no_mispred,  // qualifies out_stall in the boundary spec (stall is stale on redirect cycles)
  output logic        out_stall,
  output logic [XLEN_BITS-1:0] out_redirect_pc,
  output logic        out_rf_valid,    // the redirect is a branch mispredict (not a ROB flush): BPU history repair
  output logic [XLEN_BITS-1:0] out_rf_pc,       // pc of the mispredicted branch
  output logic out_rf_is_rvc,                   // ... and whether it is a 16-bit instruction
  output logic [XLEN_BITS-1:0] out_commit_entry_uop_diag_val [COMMIT_WIDTH],
  output logic        csr_status_mstatus_mxr,
  output logic        csr_status_mstatus_sum,
  output logic        csr_status_mstatus_mprv,
  output logic [1:0]  csr_status_mstatus_mpp,
  output logic [4:0]  rob_commit_commit_entry_uop_amo_op [COMMIT_WIDTH]
);

  // Ref: BackTop::comb, "Normal case" / flush branch. Valid when out_mispred (SimCpu reads it only then).
  logic [XLEN_BITS-1:0] flush_redirect_pc;
  always_comb begin
    if (rob_bcast_mret || rob_bcast_sret) flush_redirect_pc = csr2front_epc;
    else if (rob_bcast_exception)         flush_redirect_pc = csr2front_trap_pc;
    else flush_redirect_pc = rob_bcast_pc + (rob_bcast_is_rvc ? XLEN_BITS'(2) : XLEN_BITS'(4));
  end

  // FLUSH_REG: the front end is redirected by a flush one cycle after the decision (with the back end's clear), from a registered pc; in the cycle of the
  // decision the redirect is held back (a branch mispredict of that cycle is dropped as well: the flush wins). Ref: Rob::redirect with pend_.
  logic [XLEN_BITS-1:0] redirect_pc_q;
  always_ff @(posedge clk) begin
    if (!rst_n) redirect_pc_q <= '0;
    else        redirect_pc_q <= flush_redirect_pc;
  end
  assign out_mispred     = flush_q | (dec_bcast_mispred & ~rob_bcast_flush);
  assign out_no_mispred  = ~out_mispred;
  assign out_stall       = ~pre2front_ready;
  assign out_redirect_pc = flush_q ? redirect_pc_q : br_latch_redirect_pc;
  assign out_rf_valid    = dec_bcast_mispred & ~rob_bcast_flush & ~flush_q;
  assign out_rf_pc       = br_latch_br_pc;
  assign out_rf_is_rvc   = br_latch_is_rvc;

  // The committed slots leave the back end as they are: the diag_val of a branch is the target the front end trains with, also in
  // the cycle a flush is decided (the model overrides it only in the cycle the flush is delivered, which has no valid commit).
  for (genvar i = 0; i < COMMIT_WIDTH; i++) begin : g_commit
    assign out_commit_entry_uop_diag_val[i] = rob_commit_commit_entry_uop_diag_val[i];
  end
  logic commit_valid_unused;  // lint: kept as a port so the glue's interface documents the qualification
  assign commit_valid_unused = |rob_commit_commit_entry_valid;

  // LSU reads the AMO sub-opcode of committed stores (RealLsu::comb_stq_commit): amo_op = func7[6:2]
  for (genvar i = 0; i < COMMIT_WIDTH; i++) begin : g_amo
    assign rob_commit_commit_entry_uop_amo_op[i] = rob_commit_commit_entry_uop_func7[i][6:2];
  end
  logic [1:0] func7_low_unused [COMMIT_WIDTH];  // lint: func7[1:0] is not read
  for (genvar i = 0; i < COMMIT_WIDTH; i++) begin : g_f7
    assign func7_low_unused[i] = rob_commit_commit_entry_uop_func7[i][1:0];
  end

  // mstatus bits: MXR=19, SUM=18, MPRV=17, MPP=12:11 (TlbMmu.cpp / lsu2mmu_io.csr_status.mstatus)
  assign csr_status_mstatus_mxr  = csr_status_mstatus[19];
  assign csr_status_mstatus_sum  = csr_status_mstatus[18];
  assign csr_status_mstatus_mprv = csr_status_mstatus[17];
  assign csr_status_mstatus_mpp  = csr_status_mstatus[12:11];

  // the other mstatus bits are not read here (they leave the chip through csr_status_mstatus)
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN_BITS-1:0] mstatus_other_bits;
  /* verilator lint_on UNUSEDSIGNAL */
  assign mstatus_other_bits = csr_status_mstatus & ~XLEN_BITS'(32'h000E_1800);

endmodule

`default_nettype wire
