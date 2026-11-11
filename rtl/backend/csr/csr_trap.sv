// Ref: back-end/Exu/Csr.cpp  Csr::comb_exception  (privilege state, trap / mret / sret)
`default_nettype none

// Privilege register and the trap / xRET state machine.
// Priority (else-if chain in the reference): M trap > S trap > mret > sret.
// Produces register-file write requests (mepc/mcause/mtval/mstatus or sepc/scause/stval/mstatus), the new privilege,
// and the redirect addresses read by the front end.
module csr_trap
  import csr_pkg::*;
  import ttg_cfg_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic [XLEN_BITS-1:0] regs [NREG],
  input  logic [NIRQ-1:0] m_pending,
  input  logic [NIRQ-1:0] s_pending,
  input  logic        interrupt_resp,
  input  logic        mret,
  input  logic        sret,
  input  logic        ecall,
  input  logic        page_fault_inst,
  input  logic        page_fault_load,
  input  logic        page_fault_store,
  input  logic        illegal_inst,
  input  logic        breakpoint,
  input  logic [XLEN_BITS-1:0] trap_val,
  input  logic [XLEN_BITS-1:0] pc,
  output logic [1:0]  privilege,
  output logic        trap_taken,        // M or S trap
  output logic [XLEN_BITS-1:0] trap_pc,
  output logic        xret_taken,        // mret or sret actually performed (no trap this cycle)
  output logic [XLEN_BITS-1:0] epc,
  output logic        wr_en  [NREG],
  output logic [XLEN_BITS-1:0] wr_val [NREG]
);

  logic [1:0] privilege_q, privilege_d;
  assign privilege = privilege_q;

  // ---- classification ----
  logic       m_trap, s_trap_raw, m_is_irq, s_is_irq;
  logic [3:0] m_code, s_code;
  csr_trap_class u_class (
    .privilege(privilege_q), .medeleg(regs[R_MEDELEG]), .m_pending(m_pending), .s_pending(s_pending),
    .interrupt_resp(interrupt_resp), .ecall(ecall), .page_fault_inst(page_fault_inst),
    .page_fault_load(page_fault_load), .page_fault_store(page_fault_store), .illegal_inst(illegal_inst),
    .breakpoint(breakpoint),
    .m_trap(m_trap), .s_trap(s_trap_raw), .m_is_irq(m_is_irq), .s_is_irq(s_is_irq),
    .m_code(m_code), .s_code(s_code));

  logic s_trap_only, mret_act, sret_act;
  assign s_trap_only = s_trap_raw & ~m_trap;
  assign trap_taken  = m_trap | s_trap_raw;
  assign mret_act    = mret & ~trap_taken;
  assign sret_act    = sret & ~trap_taken & ~mret;
  assign xret_taken  = mret_act | sret_act;

  // ---- redirect addresses ----
  logic [XLEN_BITS-1:0] m_target, s_target;
  csr_trap_target u_m_target (.tvec(regs[R_MTVEC]), .is_interrupt(m_is_irq), .cause_code(m_code), .target_pc(m_target));
  csr_trap_target u_s_target (.tvec(regs[R_STVEC]), .is_interrupt(s_is_irq), .cause_code(s_code), .target_pc(s_target));
  assign trap_pc = m_trap ? m_target : s_target;
  assign epc     = mret_act ? regs[R_MEPC] : regs[R_SEPC];

  // ---- trap value: fault-type causes and the breakpoint (its pc) record a value, interrupts and ecall write 0 ----
  logic [XLEN_BITS-1:0] tval;
  assign tval = (page_fault_inst | page_fault_load | page_fault_store | illegal_inst | breakpoint) ? trap_val : '0;

  // ---- mstatus update per event ----
  logic [XLEN_BITS-1:0] mstatus_m_trap, mstatus_s_trap, mstatus_mret, mstatus_sret;
  logic [XLEN_BITS-1:0] mstatus;
  assign mstatus = regs[R_MSTATUS];
  always_comb begin
    mstatus_m_trap = mstatus;
    mstatus_m_trap[MSTATUS_MPP +: 2] = privilege_q;
    mstatus_m_trap[MSTATUS_MPIE]     = mstatus[MSTATUS_MIE];
    mstatus_m_trap[MSTATUS_MIE]      = 1'b0;

    mstatus_s_trap = mstatus;
    mstatus_s_trap[MSTATUS_SPP]  = (privilege_q == PRV_S);
    mstatus_s_trap[MSTATUS_SPIE] = mstatus[MSTATUS_SIE];
    mstatus_s_trap[MSTATUS_SIE]  = 1'b0;

    mstatus_mret = mstatus;
    mstatus_mret[MSTATUS_MIE]      = mstatus[MSTATUS_MPIE];
    mstatus_mret[MSTATUS_MPIE]     = 1'b1;
    mstatus_mret[MSTATUS_MPP +: 2] = 2'b00;

    mstatus_sret = mstatus;
    mstatus_sret[MSTATUS_SIE]  = mstatus[MSTATUS_SPIE];
    mstatus_sret[MSTATUS_SPIE] = 1'b1;
    mstatus_sret[MSTATUS_SPP]  = 1'b0;
  end

  // ---- register-file write requests ----
  always_comb begin
    for (int r = 0; r < NREG; r++) begin
      wr_en[r]  = 1'b0;
      wr_val[r] = '0;
    end
    wr_en[R_MEPC]    = m_trap;
    wr_val[R_MEPC]   = pc;
    wr_en[R_MCAUSE]  = m_trap;
    wr_val[R_MCAUSE] = {m_is_irq, {(XLEN_BITS - 5){1'b0}}, m_code};
    wr_en[R_MTVAL]   = m_trap;
    wr_val[R_MTVAL]  = tval;
    wr_en[R_SEPC]    = s_trap_only;
    wr_val[R_SEPC]   = pc;
    wr_en[R_SCAUSE]  = s_trap_only;
    wr_val[R_SCAUSE] = {s_is_irq, {(XLEN_BITS - 5){1'b0}}, s_code};
    wr_en[R_STVAL]   = s_trap_only;
    wr_val[R_STVAL]  = tval;
    wr_en[R_MSTATUS] = m_trap | s_trap_only | mret_act | sret_act;
    wr_val[R_MSTATUS] = ({XLEN_BITS{m_trap}} & mstatus_m_trap) | ({XLEN_BITS{s_trap_only}} & mstatus_s_trap)
                      | ({XLEN_BITS{mret_act}} & mstatus_mret) | ({XLEN_BITS{sret_act}} & mstatus_sret);
  end

  // ---- privilege: reset M. mret -> MPP (raw), sret -> SPP ----
  always_comb begin
    privilege_d = privilege_q;
    if (m_trap)           privilege_d = PRV_M;
    else if (s_trap_only) privilege_d = PRV_S;
    else if (mret_act)    privilege_d = mstatus[MSTATUS_MPP +: 2];
    else if (sret_act)    privilege_d = {1'b0, mstatus[MSTATUS_SPP]};
  end

  always_ff @(posedge clk) begin
    if (!rst_n) privilege_q <= PRV_M;
    else        privilege_q <= privilege_d;
  end

endmodule

`default_nettype wire
