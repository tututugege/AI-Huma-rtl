// Ref: back-end/Exu/Csr.cpp  Csr::comb_exception (MTrap / STrap / cause)
`default_nettype none

// Classifies this cycle's trap: which mode takes it (M wins over S) and the cause word of each mode.
module csr_trap_class
  import csr_pkg::*;
(
  input  logic [1:0]      privilege,
  input  logic [31:0]     medeleg,
  input  logic [NIRQ-1:0] m_pending,
  input  logic [NIRQ-1:0] s_pending,
  input  logic            interrupt_resp,
  input  logic            ecall,
  input  logic            page_fault_inst,
  input  logic            page_fault_load,
  input  logic            page_fault_store,
  input  logic            illegal_inst,
  input  logic            breakpoint,    // ebreak of the semihosting marker sequence: breakpoint exception, cause 3
  output logic            m_trap,
  output logic            s_trap,        // S trap condition; only effective when m_trap is 0
  output logic            m_is_irq,      // mcause[31]: any M-class interrupt pending (not gated by interrupt_resp)
  output logic            s_is_irq,
  output logic [3:0]      m_code,
  output logic [3:0]      s_code
);

  // exceptions as (taken-in-M, taken-in-S) pairs: delegated -> S, otherwise M
  logic ecall_u, ecall_s, ecall_m;
  logic d_u, d_s, d_pfi, d_pfl, d_pfs, d_ill, d_bp;
  assign ecall_u = ecall & (privilege == PRV_U);
  assign ecall_s = ecall & (privilege == PRV_S);
  assign ecall_m = ecall & (privilege == PRV_M);
  assign d_u   = medeleg[MEDELEG_U_ECALL];
  assign d_s   = medeleg[MEDELEG_S_ECALL];
  assign d_pfi = medeleg[MEDELEG_PF_INST];
  assign d_pfl = medeleg[MEDELEG_PF_LOAD];
  assign d_pfs = medeleg[MEDELEG_PF_STORE];
  assign d_ill = medeleg[MEDELEG_ILLEGAL];
  assign d_bp  = medeleg[MEDELEG_BREAKPOINT] & (privilege != PRV_M);   // a trap taken in M mode is never delegated

  logic m_irq_any, s_irq_any;
  assign m_irq_any = |m_pending;
  assign s_irq_any = |s_pending;
  assign m_is_irq  = m_irq_any;
  assign s_is_irq  = s_irq_any;

  assign m_trap = (m_irq_any & interrupt_resp) | (ecall_u & ~d_u) | (ecall_s & ~d_s) | ecall_m
                | (page_fault_inst & ~d_pfi) | (page_fault_load & ~d_pfl) | (page_fault_store & ~d_pfs)
                | (illegal_inst & ~d_ill) | (breakpoint & ~d_bp);
  assign s_trap = (s_irq_any & interrupt_resp) | (ecall_u & d_u) | (ecall_s & d_s)
                | (page_fault_inst & d_pfi) | (page_fault_load & d_pfl) | (page_fault_store & d_pfs)
                | (illegal_inst & d_ill) | (breakpoint & d_bp);

  // ---- cause code priority (index 0 first). Reference quirks kept: M-ecall -> 11 only when medeleg[8]==0,
  //      the illegal-instruction entry ignores delegation, S-mode lists ecall-S together with S-external first. ----
  localparam int NM = 10;
  localparam int NS = 9;
  logic [NM-1:0] m_cond;
  logic [NS-1:0] s_cond;
  logic [3:0]    m_codes [NM];
  logic [3:0]    s_codes [NS];

  assign m_cond = {breakpoint & ~d_bp, illegal_inst,
                   page_fault_store & ~d_pfs, page_fault_load & ~d_pfl, page_fault_inst & ~d_pfi,
                   ecall_s & ~d_s, ecall_u & ~d_u,
                   m_pending[2] | (ecall_m & ~d_u), m_pending[1], m_pending[0]};
  assign m_codes = '{4'd3, 4'd7, 4'd11, 4'd8, 4'd9, 4'd12, 4'd13, 4'd15, 4'd2, 4'd3};

  assign s_cond = {breakpoint & d_bp, illegal_inst & d_ill,
                   page_fault_store & d_pfs, page_fault_load & d_pfl, page_fault_inst & d_pfi,
                   s_pending[0], ecall_u & d_u, s_pending[1], s_pending[2] | (ecall_s & d_s)};
  assign s_codes = '{4'd9, 4'd5, 4'd8, 4'd1, 4'd12, 4'd13, 4'd15, 4'd2, 4'd3};

  csr_cause_sel #(.N(NM)) u_m_cause (.cond(m_cond), .code(m_codes), .cause_code(m_code));
  csr_cause_sel #(.N(NS)) u_s_cause (.cond(s_cond), .code(s_codes), .cause_code(s_code));

endmodule

`default_nettype wire
