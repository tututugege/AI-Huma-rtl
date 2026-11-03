// Ref: back-end/Exu/Csr.cpp  eval_interrupts / Csr::comb_interrupt
`default_nettype none

// Pending interrupts after mie masking, mideleg delegation and privilege/global-enable gating.
//   M-mode kinds: pending & enabled & not delegated & (priv < M || mstatus.MIE)
//   S-mode kinds: (pending & enabled & delegated) | (supervisor pending & enabled),
//                 taken in U, or in S with sstatus.SIE
module csr_irq
  import csr_pkg::*;
(
  input  logic [31:0]      mstatus,
  input  logic [31:0]      mie,
  input  logic [31:0]      mip,
  input  logic [31:0]      mideleg,
  input  logic [1:0]       privilege,
  output logic [NIRQ-1:0]  m_pending,       // software, timer, external
  output logic [NIRQ-1:0]  s_pending,
  output logic             interrupt_req
);

  logic m_enable, s_enable;
  assign m_enable = (privilege != PRV_M) || mstatus[MSTATUS_MIE];
  assign s_enable = (privilege == PRV_U) || ((privilege == PRV_S) && mstatus[MSTATUS_SIE]);

  for (genvar k = 0; k < NIRQ; k++) begin : g_kind
    logic m_bit, s_bit_from_m, s_bit_own;
    assign m_bit        = mip[IRQ_M_BIT[k]] & mie[IRQ_M_BIT[k]];
    assign s_bit_from_m = m_bit & mideleg[IRQ_M_BIT[k]];
    assign s_bit_own    = mip[IRQ_S_BIT[k]] & mie[IRQ_S_BIT[k]];
    assign m_pending[k] = m_bit & ~mideleg[IRQ_M_BIT[k]] & m_enable;
    assign s_pending[k] = (s_bit_from_m | s_bit_own) & s_enable;
  end

  assign interrupt_req = (|m_pending) | (|s_pending);

endmodule

`default_nettype wire
