// Ref: back-end/Rob.cpp  class Rob  (comb_commit single-commit tail: flush / exception / ecall / mret / ... broadcast)
`default_nettype none

module rob_trap_ctrl
  import ttg_cfg_pkg::*;
  import rob_pkg::*;
(
  input  logic              single_commit,
  input  logic              interrupt_fire,
  input  rob_entry_t        single_uop,         // first valid slot of the head line
  input  logic [XLEN-1:0]   ftq_resp_pc,        // ftq_rob_pc_resp.resp[0].pc, pc of the committing instruction
  output logic              flush,
  output logic              exception,
  output logic              mret,
  output logic              sret,
  output logic              ecall,
  output logic              fence,
  output logic              fence_i,
  output logic              page_fault_inst,
  output logic              page_fault_load,
  output logic              page_fault_store,
  output logic              illegal_inst,
  output logic              rob2csr_commit,
  output logic              trap_val_valid,     // trap_val is meaningful (page fault / illegal instruction)
  output logic [XLEN-1:0]   trap_val,
  output logic [XLEN-1:0]   pc                  // meaningful only while flush
);

  // priority order of the C++ if / else-if chain (index 0 wins)
  localparam int SEL_INT = 0, SEL_ECALL = 1, SEL_MRET = 2, SEL_SRET = 3, SEL_PF_STORE = 4, SEL_PF_LOAD = 5;
  localparam int SEL_PF_INST = 6, SEL_ILLEGAL = 7, SEL_CSR = 8, SEL_SFENCE = 9, SEL_FENCE_I = 10, SEL_NUM = 11;

  logic [SEL_NUM-1:0] cand, sel;
  /* verilator lint_off UNUSEDSIGNAL */
  logic               sel_any;  // ebreak / flush_pipe flush without a cause bit, so `any` carries no information
  /* verilator lint_on UNUSEDSIGNAL */
  logic               u_flush, flush_act;

  // Ref: Rob::comb_commit (single_is_flush gate, then the cause chain; ebreak / wfi / flush_pipe only flush or nothing)
  always_comb begin
    u_flush   = rob_is_flush_inst(single_uop);
    flush_act = single_commit && (u_flush || interrupt_fire);
    cand[SEL_INT]      = interrupt_fire;
    cand[SEL_ECALL]    = single_uop.itype == ITYPE_ECALL;
    cand[SEL_MRET]     = single_uop.itype == ITYPE_MRET;
    cand[SEL_SRET]     = single_uop.itype == ITYPE_SRET;
    cand[SEL_PF_STORE] = single_uop.pf_store;
    cand[SEL_PF_LOAD]  = single_uop.pf_load;
    cand[SEL_PF_INST]  = single_uop.pf_inst;
    cand[SEL_ILLEGAL]  = single_uop.illegal_inst;
    cand[SEL_CSR]      = single_uop.itype == ITYPE_CSR;
    cand[SEL_SFENCE]   = single_uop.itype == ITYPE_SFENCE_VMA;
    cand[SEL_FENCE_I]  = single_uop.itype == ITYPE_FENCE_I;
  end

  ttg_first_set #(.N(SEL_NUM)) u_cause (.req(cand & {SEL_NUM{flush_act}}), .onehot(sel), .any(sel_any));

  always_comb begin
    flush            = flush_act;
    exception        = flush_act && (rob_is_exception(single_uop) || interrupt_fire);
    ecall            = sel[SEL_ECALL];
    mret             = sel[SEL_MRET];
    sret             = sel[SEL_SRET];
    page_fault_store = sel[SEL_PF_STORE];
    page_fault_load  = sel[SEL_PF_LOAD];
    page_fault_inst  = sel[SEL_PF_INST];
    illegal_inst     = sel[SEL_ILLEGAL];
    rob2csr_commit   = sel[SEL_CSR];
    fence            = sel[SEL_SFENCE];
    fence_i          = sel[SEL_FENCE_I];
    trap_val_valid   = sel[SEL_PF_STORE] || sel[SEL_PF_LOAD] || sel[SEL_PF_INST] || sel[SEL_ILLEGAL];
    trap_val         = sel[SEL_PF_INST] ? ftq_resp_pc : single_uop.diag_val;
    pc               = ftq_resp_pc;
  end


endmodule

`default_nettype wire
