// Ref: back-end/Exu/Exu.cpp  class Exu (non-stalling per-port pipeline registers port_slot_valid / port_slot)
`default_nettype none

module exu_ctrl_slot
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     flush,
  input  logic                     mispred,
  input  logic [ROB_IDX_WIDTH-1:0] kill_rob_idx,
  input  logic                     kill_rob_flag,
  input  logic [ISSUE_WIDTH-1:0]   iss_valid,
  input  xc_inst_t                 iss_inst [ISSUE_WIDTH],
  input  logic [CSR_IDX_WIDTH-1:0] iss_csr_idx,
  output logic [N_FU-1:0]          fu_en,
  output logic [N_FU-1:0]          fu_occ,
  output xc_inst_t                 fu_inst [N_FU],
  output logic [CSR_IDX_WIDTH-1:0] csr_idx
);

  logic [ISSUE_WIDTH-1:0]   valid_q, valid_d, port_load, port_live;
  xc_inst_t                 slot_q [ISSUE_WIDTH];
  xc_inst_t                 slot_d [ISSUE_WIDTH];
  logic [CSR_IDX_WIDTH-1:0] csr_idx_q, csr_idx_d;

  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_port
    logic slot_killed;
    always_comb begin
      slot_killed  = xc_killed(mispred, slot_q[p].rob_idx, slot_q[p].rob_flag, kill_rob_idx, kill_rob_flag);
      port_live[p] = valid_q[p] && !flush && !slot_killed;
      port_load[p] = !flush && iss_valid[p] &&
                     !xc_killed(mispred, iss_inst[p].rob_idx, iss_inst[p].rob_flag, kill_rob_idx, kill_rob_flag);
      valid_d[p]   = port_load[p];
      slot_d[p]    = port_load[p] ? iss_inst[p] : slot_q[p];
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        valid_q[p] <= 1'b0;
        slot_q[p]  <= '0;
      end else begin
        valid_q[p] <= valid_d[p];
        slot_q[p]  <= slot_d[p];
      end
    end
  end

  for (genvar f = 0; f < N_FU; f++) begin : g_fu
    localparam int PORT = xc_fu_port(f);
    localparam logic [31:0] KIND_OPS = 32'(xc_kind_mask(xc_fu_kind(f)));
    logic match;
    always_comb begin
      match      = KIND_OPS[slot_q[PORT].op];
      fu_en[f]   = port_live[PORT] && match;
      fu_occ[f]  = valid_q[PORT] && match;
      fu_inst[f] = slot_q[PORT];
    end
  end

  localparam logic [31:0] CSR_OPS = 32'(xc_kind_mask(XC_K_CSR));
  always_comb begin
    csr_idx_d = (port_load[CSR_PORT] && CSR_OPS[iss_inst[CSR_PORT].op]) ? iss_csr_idx : csr_idx_q;
    csr_idx   = csr_idx_q;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) csr_idx_q <= '0;
    else        csr_idx_q <= csr_idx_d;
  end

endmodule

`default_nettype wire
