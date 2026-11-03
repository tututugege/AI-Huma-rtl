// Ref: front-end/BPU/dir_predictor/TAGE_top.h  TAGE_TOP::{tage_pred_index_comb,tage_pred_select_comb}
`default_nettype none

// TAGE prediction of one bank.  Index/tag of the 4 tagged tables come from the (speculative) folded histories and the
// bank pc; the caller reads the tables at those indices and this module selects provider / alternate.
module bpu_tage_pred import bpu_pkg::*; (
  input  logic [T_BASE_W-1:0] pc_idx,                  // (bank pc >> 2) & 1023
  input  logic [FH_W-1:0]     fh        [FH_K][TN],
  input  logic [1:0]          base_cnt,                // base[pc_idx]
  input  logic [T_TAG_W-1:0]  rd_tag    [TN],          // tag table entry at idx[i]
  input  logic [2:0]          rd_cnt    [TN],
  input  logic [1:0]          rd_useful [TN],
  input  logic [3:0]          use_alt_ctr,
  output logic [T_IDX_W-1:0]  idx       [TN],
  output logic [T_TAG_W-1:0]  tag       [TN],
  output logic                pred,
  output logic                alt_pred,
  output logic [PCPN_W-1:0]   pcpn,
  output logic [PCPN_W-1:0]   altpcpn
);

  logic [TN-1:0] match;
  logic          base_pred;
  logic          provider_pred;
  logic          provider_weak;
  logic          useful_low;
  logic          prefer_alt;
  logic [PCPN_W-1:0] pcpn_sel;
  logic [PCPN_W-1:0] altpcpn_sel;

  // Ref: tage_pred_index_comb
  always_comb begin
    for (int i = 0; i < TN; i++) begin
      idx[i] = fh[0][i][T_IDX_W-1:0] ^ pc_idx;
      tag[i] = fh[1][i][T_TAG_W-1:0] ^ fh[2][i][T_TAG_W-1:0] ^ pc_idx[T_TAG_W-1:0];
    end
  end

  // Ref: tage_pred_select_comb: provider = highest matching table, alternate = next lower matching table
  always_comb begin
    for (int i = 0; i < TN; i++) match[i] = (rd_tag[i] == tag[i]);
    pcpn_sel    = PCPN_W'(TN);
    altpcpn_sel = PCPN_W'(TN);
    for (int i = 0; i < TN; i++) if (match[i]) pcpn_sel = PCPN_W'(i);
    for (int i = 0; i < TN; i++) if (match[i] && PCPN_W'(i) < pcpn_sel) altpcpn_sel = PCPN_W'(i);
    base_pred = (base_cnt >= 2'd2);
  end

  always_comb begin
    pcpn          = pcpn_sel;
    altpcpn       = altpcpn_sel;
    alt_pred      = (altpcpn_sel >= PCPN_W'(TN)) ? base_pred : (rd_cnt[altpcpn_sel[1:0]] >= 3'd4);
    provider_pred = rd_cnt[pcpn_sel[1:0]] >= 3'd4;
    provider_weak = (rd_cnt[pcpn_sel[1:0]] == 3'd3);              // TAGE_PROVIDER_WEAK_LOW == HIGH == 3
    useful_low    = (rd_useful[pcpn_sel[1:0]] == 2'd0);           // TAGE_USE_ALT_USEFUL_THRESHOLD == 0
    prefer_alt    = (use_alt_ctr <= 4'd8);                        // TAGE_USE_ALT_CTR_USE_ALT_THRESHOLD
    if (pcpn_sel >= PCPN_W'(TN)) pred = base_pred;
    else if (provider_weak && useful_low && prefer_alt) pred = alt_pred;
    else pred = provider_pred;
  end

endmodule

`default_nettype wire
