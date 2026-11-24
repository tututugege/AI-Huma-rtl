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

  // Direct prefix popcount per lane (0..7 bits -> 3-bit rank), faster and smaller than ttg_pick_k(8, 8).
  localparam int RW = $clog2(N);
  logic [N-1:0] free_ok;
  for (genvar k = 0; k < N; k++) begin : g_fok
    assign free_ok[k] = (free_count > preg_t'(k));
  end

  for (genvar i = 0; i < N; i++) begin : g_slot
    logic [RW-1:0] rank_i;
    logic [N-1:0]  pick_i;
    if (i == 0) begin : g_r0
      assign rank_i = '0;
    end else begin : g_rn
      logic [$clog2(i + 1)-1:0] cnt_i;
      ttg_popcount #(.N(i)) u_pc (.bits(req[i-1:0]), .count(cnt_i));
      assign rank_i = RW'(cnt_i);
    end
    for (genvar k = 0; k < N; k++) begin : g_pk
      assign pick_i[k] = req[i] & (rank_i == RW'(k)) & free_ok[k];
    end
    assign alloc_valid[i] = req[i] & free_ok[rank_i];
    ttg_onehot_mux #(.N(N), .W(PRF_IDX_WIDTH)) u_reg (.sel(pick_i), .data(window), .out(alloc_reg[i]));
  end

endmodule

`default_nettype wire
