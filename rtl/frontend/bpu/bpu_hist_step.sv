// Ref: front-end/BPU/dir_predictor/TAGE_top.h  tage_ghr_update_comb / tage_fh_update_comb (one history step)
`default_nettype none

// One history update: GHR <<= 1 | new_hist and the 12 folded histories
//   FH[k][i] = ((FH << 1) & mask(len)) | (new_hist ^ FH[len-1]),  then  ^= GHR_old[ghr_len[i]-1] << (ghr_len[i] % len).
// Only GHR[0..118] is ever read, so the GHR is kept 119 bits wide.  The folded histories travel as one flat vector,
// element (k, i) at bits [(k*TN+i)*FH_W +: FH_W] (always zero above the fold length).
module bpu_hist_step import bpu_pkg::*; (
  input  logic [GHR_W-1:0]   ghr_in,
  input  logic [FH_FLAT-1:0] fh_in,
  input  logic               new_hist,
  output logic [GHR_W-1:0]   ghr_out,
  output logic [FH_FLAT-1:0] fh_out
);

  assign ghr_out = {ghr_in[GHR_W-2:0], new_hist};

  for (genvar k = 0; k < FH_K; k++) begin : g_k
    for (genvar i = 0; i < TN; i++) begin : g_i
      localparam int L  = fh_len(k, i);
      localparam int G  = ghr_len(i);
      localparam int SH = G % L;
      localparam int O  = (k * TN + i) * FH_W;
      logic [L-1:0] val;
      logic [L-1:0] nxt;
      assign val = fh_in[O +: L];
      assign nxt = {val[L-2:0], 1'b0} ^ L'(new_hist ^ val[L-1]) ^ (L'(ghr_in[G-1]) << SH);
      assign fh_out[O +: FH_W] = FH_W'(nxt);
      if (L < FH_W) begin : g_high
        /* verilator lint_off UNUSEDSIGNAL */
        logic [FH_W-L-1:0] fh_in_high_unused;   // bits above the fold length are always 0 in the state
        /* verilator lint_on UNUSEDSIGNAL */
        assign fh_in_high_unused = fh_in[O + L +: FH_W - L];
      end
    end
  end

endmodule

`default_nettype wire
