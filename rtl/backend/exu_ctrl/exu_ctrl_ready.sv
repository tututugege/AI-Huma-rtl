// Ref: back-end/Exu/Exu.cpp  Exu::comb_ready;  AbstractFU.h  class SingleCycleFU (comb_consume)
`default_nettype none

// FU ready (after this cycle's consume) and the per-port mask of micro-op classes the port can take next cycle.
module exu_ctrl_ready
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  logic                   flush,
  input  logic [N_FU-1:0]        fu_en,
  // consume of the multi-cycle FUs goes straight to the FU; only the single-cycle FUs' bits are read here
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [N_FU-1:0]        consume,
  /* verilator lint_on UNUSEDSIGNAL */
  input  xc_fu_res_t             fu_res [N_FU],
  output logic [N_FU-1:0]        fu_ready,
  output logic [XC_OP_NUM-1:0]   fu_ready_mask [ISSUE_WIDTH]
);

  logic [XC_OP_NUM-1:0] accept_ops [N_FU];   // op classes of the FU if its slot can take an instruction

  // Ref: SingleCycleFU::comb_consume (ready = !en || consume); multi-cycle FUs report their own ready
  for (genvar f = 0; f < N_FU; f++) begin : g_fu
    localparam bit MULTI_CYCLE = xc_is_mc_kind(xc_fu_kind(f));
    localparam xc_opset_t KIND_OPS = xc_kind_mask(xc_fu_kind(f));
    if (MULTI_CYCLE) begin : g_mc
      assign fu_ready[f] = fu_res[f].mc_ready;
    end else begin : g_sc
      assign fu_ready[f] = !fu_en[f] || consume[f];
    end
    // slot free after the release, or its FU becomes ready: (!slot_valid_1 || ready)
    assign accept_ops[f] = (!fu_en[f] || fu_ready[f]) ? KIND_OPS : '0;
  end

  // Ref: Exu::comb_ready (flush: nothing is accepted)
  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_port
    localparam int NFU  = xc_port_fu_count(p);
    localparam int BASE = xc_port_fu_base(p);
    logic [XC_OP_NUM-1:0] port_ops;
    always_comb begin
      port_ops = '0;
      for (int j = 0; j < NFU; j++) port_ops = port_ops | accept_ops[BASE+j];
    end
    assign fu_ready_mask[p] = flush ? '0 : port_ops;
  end

endmodule

`default_nettype wire
