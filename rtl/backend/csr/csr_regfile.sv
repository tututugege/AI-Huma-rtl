// Ref: back-end/Exu/Csr.cpp  Csr::comb_exception / comb_csr_write / comb_interrupt_inject / seq
`default_nettype none

// The CSR registers. Per-register write merge, lowest to highest priority:
// hold < trap/xRET < committed CSR write < interrupt inject (mip only).
module csr_regfile
  import csr_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  // trap / xRET write requests
  input  logic        trap_wr_en  [NREG],
  input  logic [31:0] trap_wr_val [NREG],
  // committed CSR write
  input  logic        commit_fire,
  input  logic [11:0] commit_idx,
  input  logic [31:0] commit_wdata,
  // interrupt inject (peripheral model)
  input  logic        inj_external_valid,
  input  logic        inj_external,
  input  logic        inj_supervisor_external_valid,
  input  logic        inj_supervisor_external,
  input  logic        inj_timer_valid,
  input  logic        inj_timer,
  output logic [31:0] regs [NREG]
);

  logic [NENT-1:0] hit;
  for (genvar e = 0; e < NENT; e++) begin : g_hit
    assign hit[e] = commit_fire & (commit_idx == ENT_ADDR[e]);
  end

  logic [31:0] regs_q [NREG];
  logic [31:0] regs_d [NREG];
  assign regs = regs_q;

  for (genvar r = 0; r < NREG; r++) begin : g_reg
    // committed write: the matching table entries that target this register supply the write mask
    logic        commit_hit;
    logic [31:0] commit_mask;
    always_comb begin
      commit_hit  = 1'b0;
      commit_mask = 32'd0;
      for (int e = 0; e < NENT; e++) begin
        if (ENT_REG[e] == r) begin
          commit_hit  = commit_hit | hit[e];
          commit_mask = commit_mask | (ENT_WMASK[e] & {32{hit[e]}});
        end
      end
    end

    logic [31:0] merged;
    always_comb begin
      merged = regs_q[r];
      if (trap_wr_en[r]) merged = trap_wr_val[r];
      if (commit_hit)    merged = (regs_q[r] & ~commit_mask) | (commit_wdata & commit_mask);
    end

    if (r == R_MIP) begin : g_mip
      always_comb begin
        regs_d[r] = merged;
        if (inj_external_valid)            regs_d[r][MIP_MEIP] = inj_external;
        if (inj_supervisor_external_valid) regs_d[r][MIP_SEIP] = inj_supervisor_external;
        if (inj_timer_valid)               regs_d[r][MIP_MTIP] = inj_timer;
      end
    end else begin : g_other
      assign regs_d[r] = merged;
    end

    always_ff @(posedge clk) begin
      if (!rst_n) regs_q[r] <= (r == R_MISA) ? MISA_RESET : 32'd0;
      else        regs_q[r] <= regs_d[r];
    end
  end

endmodule

`default_nettype wire
