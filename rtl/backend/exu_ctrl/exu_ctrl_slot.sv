// Ref: back-end/Exu/Exu.cpp  class Exu (fu_inst_r / fu_inst_r_1; comb_exu2fu_dispatch, comb_pipeline, seq)
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
  input  logic [N_FU-1:0]          fu_ready,
  output logic [N_FU-1:0]          fu_en,
  output logic [N_FU-1:0]          fu_occ,
  output xc_inst_t                 fu_inst [N_FU],
  output logic [CSR_IDX_WIDTH-1:0] csr_idx
);

  logic [CSR_IDX_WIDTH-1:0] csr_idx_q, csr_idx_d;
  logic [N_FU-1:0] load;

  for (genvar f = 0; f < N_FU; f++) begin : g_slot
    localparam int PORT = xc_fu_port(f);
    localparam logic [31:0] KIND_OPS = 32'(xc_kind_mask(xc_fu_kind(f)));
    logic     valid_q, valid_d;
    xc_inst_t slot_q, slot_d;
    logic     slot_killed;

    always_comb begin
      slot_killed = xc_killed(mispred, slot_q.rob_idx, slot_q.rob_flag, kill_rob_idx, kill_rob_flag);
      fu_en[f]    = valid_q && !flush && !slot_killed;
      fu_occ[f]   = valid_q;
      fu_inst[f]  = slot_q;
      load[f] = !flush && iss_valid[PORT] &&
                !xc_killed(mispred, iss_inst[PORT].rob_idx, iss_inst[PORT].rob_flag, kill_rob_idx, kill_rob_flag) &&
                KIND_OPS[iss_inst[PORT].op];
      valid_d = (fu_en[f] && !fu_ready[f]) || load[f];
      slot_d  = load[f] ? iss_inst[PORT] : slot_q;
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        valid_q <= 1'b0;
        slot_q  <= '0;
      end else begin
        valid_q <= valid_d;
        slot_q  <= slot_d;
      end
    end
  end

  always_comb begin
    csr_idx_d = load[CSR_FU] ? iss_csr_idx : csr_idx_q;
    csr_idx   = csr_idx_q;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) csr_idx_q <= '0;
    else        csr_idx_q <= csr_idx_d;
  end

endmodule

`default_nettype wire
