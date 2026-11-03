// Ref: back-end/Exu/Exu.cpp  Exu::comb_fu2exu_collect (port scan: winner = first complete FU of the port)
`default_nettype none

// Write-back arbitration inside every issue port. FUs of a port are numbered in the priority order of Exu::init
// (MUL > DIV > LD > STA > STD > BR > ALU > CSR > FP); the first complete one wins and is consumed.
module exu_ctrl_port_arb
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  xc_done_t               fu_done [N_FU],
  output logic [N_FU-1:0]        consume,        // winner FU: its result is taken this cycle
  output logic [ISSUE_WIDTH-1:0] win_valid,      // some FU of the port completes
  output xc_done_t               win [ISSUE_WIDTH],
  output logic [ALU_NUM-1:0]     win_is_csr      // INT ports 0..ALU_NUM-1: the winner is the CSR FU
);

  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_port
    localparam int NFU  = xc_port_fu_count(p);
    localparam int BASE = xc_port_fu_base(p);
    localparam int DW   = $bits(xc_done_t);
    logic [NFU-1:0] complete_vec;
    logic [NFU-1:0] winner_onehot;
    logic [DW-1:0]  cand [NFU];
    logic [DW-1:0]  win_bits;

    for (genvar j = 0; j < NFU; j++) begin : g_fu
      assign complete_vec[j]  = fu_done[BASE+j].complete;
      assign cand[j]          = fu_done[BASE+j];
      assign consume[BASE+j]  = winner_onehot[j];
    end

    ttg_first_set #(.N(NFU)) u_first (.req(complete_vec), .onehot(winner_onehot), .any(win_valid[p]));
    ttg_onehot_mux #(.N(NFU), .W(DW)) u_mux (.sel(winner_onehot), .data(cand), .out(win_bits));
    assign win[p]        = xc_done_t'(win_bits);
    if (p < ALU_NUM) begin : g_csr
      logic [NFU-1:0] csr_hit;
      for (genvar j = 0; j < NFU; j++) begin : g_hit
        assign csr_hit[j] = winner_onehot[j] && (xc_fu_kind(BASE+j) == XC_K_CSR);
      end
      assign win_is_csr[p] = |csr_hit;
    end
  end

endmodule

`default_nettype wire
