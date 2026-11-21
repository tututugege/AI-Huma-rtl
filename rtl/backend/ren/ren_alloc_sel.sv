// Ref: back-end/Ren.cpp  class Ren  Ren::comb_alloc
`default_nettype none

// Hands out the first free physical registers, in order, to the slots that request one:
// request #k (k-th requester) gets free-list window entry k, valid only if k < free_count.
module ren_alloc_sel
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N = DECODE_WIDTH
) (
  input  logic  [N-1:0]            req,          // slot is valid and needs a destination preg
  input  preg_t                    window [N],   // free_list[head + k]
  input  preg_t                    free_count,
  output logic  [N-1:0]            alloc_valid,  // slot got a preg
  output preg_t                    alloc_reg [N] // 0 when not allocated
);

  logic [N-1:0] grant  [N];       // grant[k]: one-hot slot that receives window[k]
  logic [N-1:0] grant_any;        // grant k exists
  logic [N-1:0] window_ok;        // grant k exists and window entry k exists (k < free_count)
  logic [N-1:0] pick   [N];       // pick[i][k]: slot i takes window entry k

  ttg_pick_k #(.N(N), .K(N)) u_pick (.req(req), .pick_oh(grant), .valid(grant_any));

  for (genvar k = 0; k < N; k++) begin : g_grant
    assign window_ok[k] = grant_any[k] & (free_count > preg_t'(k));
  end

  for (genvar i = 0; i < N; i++) begin : g_slot
    for (genvar k = 0; k < N; k++) begin : g_pick
      assign pick[i][k] = grant[k][i] & window_ok[k];
    end
    assign alloc_valid[i] = |pick[i];
    ttg_onehot_mux #(.N(N), .W(PRF_IDX_WIDTH)) u_reg (.sel(pick[i]), .data(window), .out(alloc_reg[i]));
  end

endmodule

`default_nettype wire
