// Ref: front-end/BPU/dir_predictor/TAGE_top.h  class TAGE_TOP (8 instances, one per BPU bank)
`default_nettype none

// The 8 TAGE banks of the BPU, port convention = spec/bpu_tage.io. `fh` is the speculative folded history of all banks.
// Prediction outputs are zero when the bank has no lookup (like the C++ output struct).
module bpu_tage import bpu_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  input  logic [FH_W-1:0]     fh           [FH_K][TN],
  input  logic                pred_req     [NBANK],
  input  logic [T_BASE_W-1:0] pred_pc_idx  [NBANK],
  input  logic                update_en    [NBANK],
  input  logic [T_BASE_W-1:0] upd_pc_idx   [NBANK],
  input  logic                real_dir     [NBANK],
  input  logic                pred_in      [NBANK],
  input  logic                alt_pred_in  [NBANK],
  input  logic [PCPN_W-1:0]   pcpn_in      [NBANK],
  input  logic [T_TAG_W-1:0]  tag_in       [NBANK][TN],
  input  logic [T_IDX_W-1:0]  idx_in       [NBANK][TN],
  output logic                pred_out     [NBANK],
  output logic                alt_pred_out [NBANK],
  output logic [PCPN_W-1:0]   pcpn_out     [NBANK],
  output logic [PCPN_W-1:0]   altpcpn_out  [NBANK],
  output logic [T_TAG_W-1:0]  tag_out      [NBANK][TN],
  output logic [T_IDX_W-1:0]  idx_out      [NBANK][TN]
);

  for (genvar b = 0; b < NBANK; b++) begin : g_bank
    logic               raw_pred;
    logic               raw_alt_pred;
    logic [PCPN_W-1:0]  raw_pcpn;
    logic [PCPN_W-1:0]  raw_altpcpn;
    logic [T_TAG_W-1:0] raw_tag [TN];
    logic [T_IDX_W-1:0] raw_idx [TN];

    bpu_tage_bank u_bank (
      .clk(clk), .rst_n(rst_n), .fh(fh), .pred_pc_idx(pred_pc_idx[b]), .update_en(update_en[b]),
      .upd_pc_idx(upd_pc_idx[b]), .real_dir(real_dir[b]), .pred_in(pred_in[b]), .alt_pred_in(alt_pred_in[b]),
      .pcpn_in(pcpn_in[b]), .tag_in(tag_in[b]), .idx_in(idx_in[b]), .pred_out(raw_pred),
      .alt_pred_out(raw_alt_pred), .pcpn_out(raw_pcpn), .altpcpn_out(raw_altpcpn), .tag_out(raw_tag), .idx_out(raw_idx)
    );

    assign pred_out[b]     = pred_req[b] && raw_pred;
    assign alt_pred_out[b] = pred_req[b] && raw_alt_pred;
    assign pcpn_out[b]     = pred_req[b] ? raw_pcpn : '0;
    assign altpcpn_out[b]  = pred_req[b] ? raw_altpcpn : '0;
    for (genvar t = 0; t < TN; t++) begin : g_t
      assign tag_out[b][t] = pred_req[b] ? raw_tag[t] : '0;
      assign idx_out[b][t] = pred_req[b] ? raw_idx[t] : '0;
    end
  end

endmodule

`default_nettype wire
