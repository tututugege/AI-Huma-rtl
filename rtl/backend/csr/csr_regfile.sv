// Ref: back-end/Exu/Csr.cpp  Csr::comb_exception / comb_csr_write / comb_interrupt_inject / seq
`default_nettype none

// The CSR registers. Per-register write merge, lowest to highest priority:
// hold < trap/xRET < committed CSR write < interrupt inject (mip only).
module csr_regfile
  import csr_pkg::*;
  import ttg_cfg_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  // trap / xRET write requests
  input  logic        trap_wr_en  [NREG],
  input  logic [XLEN_BITS-1:0] trap_wr_val [NREG],
  // committed CSR write
  input  logic        commit_fire,
  input  logic [11:0] commit_idx,
  input  logic [XLEN_BITS-1:0] commit_wdata,
  // F/D: exception flags accrued by the committing instructions, and "an instruction made FS Dirty"
  input  logic [4:0]  fflags_acc,
  input  logic        fs_dirty,
  // interrupt inject (peripheral model)
  input  logic        inj_external_valid,
  input  logic        inj_external,
  input  logic        inj_supervisor_external_valid,
  input  logic        inj_supervisor_external,
  input  logic        inj_timer_valid,
  input  logic        inj_timer,
  output logic [XLEN_BITS-1:0] regs [NREG]
);

  // satp: rv64 implements Bare (0) and Sv39 (8) only; a write of any other mode has no effect
  logic satp_wr_ok;
  assign satp_wr_ok = (XLEN_BITS == 32) | (commit_wdata[XLEN_BITS-1 -: 4] == 4'd0)
                    | (commit_wdata[XLEN_BITS-1 -: 4] == 4'd8);

  logic [NENT-1:0] hit;
  for (genvar e = 0; e < NENT; e++) begin : g_hit
    assign hit[e] = commit_fire & (commit_idx == ENT_ADDR[e]);
  end

  // a committed write of fflags / frm / fcsr
  logic fcsr_wr;
  always_comb begin
    fcsr_wr = 1'b0;
    for (int e = 21; e < NENT_MAX; e++) fcsr_wr = fcsr_wr | (FP_EN & hit[e]);
  end
  logic [XLEN_BITS-1:0] regs_q [NREG];
  logic [XLEN_BITS-1:0] regs_d [NREG];
  assign regs = regs_q;

  for (genvar r = 0; r < NREG; r++) begin : g_reg
    // committed write: the matching table entries that target this register supply the write mask
    logic        commit_hit;
    logic [XLEN_BITS-1:0] commit_mask;
    logic [XLEN_BITS-1:0] commit_bits;   // the written value positioned inside the register (frm: shifted)
    always_comb begin
      commit_hit  = 1'b0;
      commit_mask = '0;
      commit_bits = '0;
      for (int e = 0; e < NENT; e++) begin
        if (ENT_REG[e] == r) begin
          commit_hit  = commit_hit | (hit[e] & ((r != R_SATP) | satp_wr_ok));
          // sie / sip: only the delegated bits are writable
          commit_mask = commit_mask
                      | (((ENT_WMASK[e] & (ENT_DELEG[e] ? regs_q[R_MIDELEG] : ALL_ONES)) << ENT_SHIFT[e])
                         & {XLEN_BITS{hit[e]}});
          commit_bits = commit_bits | ((commit_wdata << ENT_SHIFT[e]) & {XLEN_BITS{hit[e]}});
        end
      end
    end

    logic        regs_we;
    logic [XLEN_BITS-1:0] merged;
    always_comb begin
      merged = regs_q[r];
      if (trap_wr_en[r]) merged = trap_wr_val[r];
      if (commit_hit)    merged = (regs_q[r] & ~commit_mask) | (commit_bits & commit_mask);
      // F/D: flags accrue into fcsr (never in the cycle of a CSR write: a CSR instruction commits alone);
      // an FP instruction, or a write of fflags / frm / fcsr, leaves FS Dirty
      if (FP_EN && r == R_FCSR)    merged[4:0] = merged[4:0] | fflags_acc;
      if (FP_EN && r == R_MSTATUS && (fs_dirty || fcsr_wr)) merged[MSTATUS_FS +: 2] = 2'b11;
    end

    if (r == R_MIP) begin : g_mip
      assign regs_we = trap_wr_en[r] | commit_hit | inj_external_valid | inj_supervisor_external_valid
                     | inj_timer_valid;
      always_comb begin
        regs_d[r] = merged;
        if (inj_external_valid)            regs_d[r][MIP_MEIP] = inj_external;
        if (inj_supervisor_external_valid) regs_d[r][MIP_SEIP] = inj_supervisor_external;
        if (inj_timer_valid)               regs_d[r][MIP_MTIP] = inj_timer;
      end
    end else begin : g_other
      assign regs_we   = trap_wr_en[r] | commit_hit | (FP_EN && r == R_FCSR && (|fflags_acc))
                       | (FP_EN && r == R_MSTATUS && (fs_dirty || fcsr_wr));
      assign regs_d[r] = merged;
    end

    always_ff @(posedge clk) begin
      if (!rst_n) regs_q[r] <= (r == R_MISA) ? MISA_RESET : (r == R_MSTATUS) ? MSTATUS_RESET : '0;
      else if (regs_we) regs_q[r] <= regs_d[r];
    end
  end

endmodule

`default_nettype wire
