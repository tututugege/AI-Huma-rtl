// Ref: back-end/Exu/Csr.cpp  class Csr
`default_nettype none

// CSR file, privilege, interrupt pending and trap handling. Top level only adapts ports.
module csr
  import csr_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        exe2csr_we,
  input  logic        exe2csr_re,
  input  logic [11:0] exe2csr_idx,
  input  logic [31:0] exe2csr_wdata,
  input  logic [1:0]  exe2csr_wcmd,
  input  logic        rob_bcast_mret,
  input  logic        rob_bcast_sret,
  input  logic        rob_bcast_ecall,
  input  logic        rob_bcast_page_fault_inst,
  input  logic        rob_bcast_page_fault_load,
  input  logic        rob_bcast_page_fault_store,
  input  logic        rob_bcast_illegal_inst,
  input  logic [31:0] rob_bcast_trap_val,
  input  logic [31:0] rob_bcast_pc,
  input  logic        rob2csr_interrupt_resp,
  input  logic        rob2csr_commit,
  input  logic        interrupt_inject_external_irq_pending_valid,
  input  logic        interrupt_inject_external_irq_pending,
  input  logic        interrupt_inject_supervisor_external_irq_pending_valid,
  input  logic        interrupt_inject_supervisor_external_irq_pending,
  input  logic        interrupt_inject_timer_irq_pending_valid,
  input  logic        interrupt_inject_timer_irq_pending,
  output logic        csr2exe_rdata_vld,
  output logic [31:0] csr2exe_rdata,
  output logic        csr2rob_interrupt_req,
  output logic        csr2front_epc_vld,
  output logic [31:0] csr2front_epc,
  output logic        csr2front_trap_pc_vld,
  output logic [31:0] csr2front_trap_pc,
  output logic [31:0] csr_status_sstatus,
  output logic [31:0] csr_status_mstatus,
  output logic [31:0] csr_status_satp,
  output logic [1:0]  csr_status_privilege
);

  logic [31:0] regs [NREG];
  logic [1:0]  privilege;

  // ---- interrupts ----
  logic [NIRQ-1:0] m_pending, s_pending;
  csr_irq u_irq (
    .mstatus(regs[R_MSTATUS]), .mie(regs[R_MIE]), .mip(regs[R_MIP]), .mideleg(regs[R_MIDELEG]),
    .privilege(privilege), .m_pending(m_pending), .s_pending(s_pending), .interrupt_req(csr2rob_interrupt_req));

  // ---- trap / xRET ----
  logic        trap_wr_en  [NREG];
  logic [31:0] trap_wr_val [NREG];
  csr_trap u_trap (
    .clk(clk), .rst_n(rst_n), .regs(regs), .m_pending(m_pending), .s_pending(s_pending),
    .interrupt_resp(rob2csr_interrupt_resp), .mret(rob_bcast_mret), .sret(rob_bcast_sret),
    .ecall(rob_bcast_ecall), .page_fault_inst(rob_bcast_page_fault_inst),
    .page_fault_load(rob_bcast_page_fault_load), .page_fault_store(rob_bcast_page_fault_store),
    .illegal_inst(rob_bcast_illegal_inst), .trap_val(rob_bcast_trap_val), .pc(rob_bcast_pc),
    .privilege(privilege), .trap_taken(csr2front_trap_pc_vld), .trap_pc(csr2front_trap_pc),
    .xret_taken(csr2front_epc_vld), .epc(csr2front_epc), .wr_en(trap_wr_en), .wr_val(trap_wr_val));

  // ---- CSR instruction: read at execute, staged write, commit ----
  logic [11:0] pending_idx;
  logic [31:0] pending_old, commit_wdata;
  logic        commit_fire;
  csr_read u_read_exe (.idx(exe2csr_idx), .regs(regs), .rdata(csr2exe_rdata));
  csr_read u_read_pending (.idx(pending_idx), .regs(regs), .rdata(pending_old));
  csr_wbuf u_wbuf (
    .clk(clk), .rst_n(rst_n), .exe_we(exe2csr_we), .exe_idx(exe2csr_idx), .exe_wdata(exe2csr_wdata),
    .exe_wcmd(exe2csr_wcmd), .commit(rob2csr_commit), .old_value(pending_old), .pending_idx(pending_idx),
    .commit_fire(commit_fire), .commit_wdata(commit_wdata));

  csr_regfile u_regfile (
    .clk(clk), .rst_n(rst_n), .trap_wr_en(trap_wr_en), .trap_wr_val(trap_wr_val),
    .commit_fire(commit_fire), .commit_idx(pending_idx), .commit_wdata(commit_wdata),
    .inj_external_valid(interrupt_inject_external_irq_pending_valid),
    .inj_external(interrupt_inject_external_irq_pending),
    .inj_supervisor_external_valid(interrupt_inject_supervisor_external_irq_pending_valid),
    .inj_supervisor_external(interrupt_inject_supervisor_external_irq_pending),
    .inj_timer_valid(interrupt_inject_timer_irq_pending_valid), .inj_timer(interrupt_inject_timer_irq_pending),
    .regs(regs));

  // ---- status for MMU / LSU / front end ----
  assign csr2exe_rdata_vld    = exe2csr_re;
  assign csr_status_mstatus   = regs[R_MSTATUS];
  assign csr_status_sstatus   = regs[R_MSTATUS] & SSTATUS_MASK;
  assign csr_status_satp      = regs[R_SATP];
  assign csr_status_privilege = privilege;

endmodule

`default_nettype wire
