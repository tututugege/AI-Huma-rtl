// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (port scan: winner = first complete FU of the port)
`default_nettype none

// Write-back arbitration inside every issue port. Pre-scheduled at issue time so at most one FU on any port
// completes per cycle (checked by $onehot0 assertion in exu_ctrl).
module exu_ctrl_port_arb
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  xc_done_t               fu_done [N_FU],
  output logic [ISSUE_WIDTH-1:0] win_valid,      // some FU of the port completes
  output xc_done_t               win [ISSUE_WIDTH],
  output logic [ALU_NUM-1:0]     win_is_csr      // INT ports 0..ALU_NUM-1: the winner is the CSR FU
);

  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_port
    localparam int NFU  = xc_port_fu_count(p);
    localparam int BASE = xc_port_fu_base(p);
    localparam int DW   = $bits(xc_done_t);
    logic [NFU-1:0] complete_vec;
    logic [DW-1:0]  cand [NFU];
    logic [DW-1:0]  win_bits;

    for (genvar j = 0; j < NFU; j++) begin : g_fu
      assign complete_vec[j] = fu_done[BASE+j].complete;
      assign cand[j]         = fu_done[BASE+j];
    end

    assign win_valid[p] = |complete_vec;
    if (NFU == 1) begin : g_one
      assign win_bits = cand[0];
    end else begin : g_mux
      ttg_onehot_mux #(.N(NFU), .W(DW)) u_mux (.sel(complete_vec), .data(cand), .out(win_bits));
    end
    assign win[p] = xc_done_t'(win_bits);
    if (p < ALU_NUM) begin : g_csr
      logic [NFU-1:0] csr_hit;
      for (genvar j = 0; j < NFU; j++) begin : g_hit
        assign csr_hit[j] = complete_vec[j] && (xc_fu_kind(BASE+j) == XC_K_CSR);
      end
      assign win_is_csr[p] = |csr_hit;
    end
  end

endmodule

`default_nettype wire
