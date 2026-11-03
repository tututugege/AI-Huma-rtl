// Ref: back-end/Exu/Exu.cpp  class Exu (fu_inst_r / fu_inst_r_1; comb_exu2fu_dispatch, comb_pipeline, seq)
`default_nettype none

// The FU input slots: one per FU, a one-entry stage in front of every functional unit. A slot is loaded from the Prf
// read of its issue port (the FU whose op set contains the op), released when its FU reports ready (after consume),
// killed by a flush or by a mispredicted branch whose tag it carries, and has resolved tags cleared from br_mask.
module exu_ctrl_slot
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     flush,          // rob_bcast.flush
  input  logic                     mispred,        // dec_bcast.mispred
  input  logic [BR_MASK_WIDTH-1:0] kill_mask,      // dec_bcast.br_mask (one-hot of the mispredicted branch)
  input  logic [BR_MASK_WIDTH-1:0] clear_mask,     // dec_bcast.clear_mask
  input  logic [ISSUE_WIDTH-1:0]   iss_valid,
  input  xc_inst_t                 iss_inst [ISSUE_WIDTH],
  input  logic [CSR_IDX_WIDTH-1:0] iss_csr_idx,    // csr_idx of the instruction issued on the CSR port
  input  logic [N_FU-1:0]          fu_ready,       // FU can take a new instruction (after this cycle's consume)
  output logic [N_FU-1:0]          fu_en,          // slot holds a live instruction: dispatched to the FU this cycle
  output xc_inst_t                 fu_inst [N_FU], // the dispatched instruction (br_mask with clear applied)
  output logic [CSR_IDX_WIDTH-1:0] csr_idx         // csr_idx of the instruction in the CSR slot
);

  logic [CSR_IDX_WIDTH-1:0] csr_idx_q, csr_idx_d;
  logic [N_FU-1:0] load;

  for (genvar f = 0; f < N_FU; f++) begin : g_slot
    localparam int PORT = xc_fu_port(f);
    localparam logic [31:0] KIND_OPS = 32'(xc_kind_mask(xc_fu_kind(f)));
    logic     valid_q, valid_d;
    xc_inst_t slot_q, slot_d;
    logic     slot_killed;

    // Ref: Exu::comb_exu2fu_dispatch, Exu::comb_pipeline
    always_comb begin
      slot_killed = xc_killed(mispred, slot_q.br_mask, kill_mask);
      fu_en[f]    = valid_q && !flush && !slot_killed;
      fu_inst[f]  = slot_q;
      fu_inst[f].br_mask = slot_q.br_mask & ~clear_mask;
      load[f] = !flush && iss_valid[PORT] && !xc_killed(mispred, iss_inst[PORT].br_mask, kill_mask)
                && KIND_OPS[iss_inst[PORT].op];
      valid_d = (fu_en[f] && !fu_ready[f]) || load[f];
      slot_d  = load[f] ? iss_inst[PORT] : slot_q;
      slot_d.br_mask = slot_d.br_mask & ~clear_mask;
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

  // csr_idx is only needed by the CSR slot (Exu::comb_to_csr)
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
