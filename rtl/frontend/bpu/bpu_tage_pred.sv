// Ref: front-end/BPU/dir_predictor/TAGE_top.h  TAGE_TOP::tage_pred_select_comb (select half of Tage::select)
`default_nettype none

// TAGE selection of one bank in the compare stage: provider = highest matching table, alternate = next lower matching
// table, base prediction, weak-provider use-alt rule.  Pure compare / select on the registered raw array data.
module bpu_tage_pred import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  tg_raw_t             raw,
  input  logic [T_TAG_W-1:0]  tag         [TN],
  input  logic [3:0]          use_alt_ctr,
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

  // Ref: tage_pred_select_comb: provider / alternate
  always_comb begin
    for (int i = 0; i < TN; i++) match[i] = (raw.tag[i] == tag[i]);
    pcpn_sel    = PCPN_W'(TN);
    altpcpn_sel = PCPN_W'(TN);
    for (int i = 0; i < TN; i++) if (match[i]) pcpn_sel = PCPN_W'(i);
    for (int i = 0; i < TN; i++) if (match[i] && PCPN_W'(i) < pcpn_sel) altpcpn_sel = PCPN_W'(i);
    base_pred = (raw.base >= 2'd2);
  end

  // Ref: tage_pred_select_comb: prediction
  always_comb begin
    pcpn          = pcpn_sel;
    altpcpn       = altpcpn_sel;
    alt_pred      = (altpcpn_sel >= PCPN_W'(TN)) ? base_pred : (raw.cnt[altpcpn_sel[1:0]] >= 3'd4);
    provider_pred = raw.cnt[pcpn_sel[1:0]] >= 3'd4;
    provider_weak = (raw.cnt[pcpn_sel[1:0]] == 3'd3);              // TAGE_PROVIDER_WEAK_LOW == HIGH == 3
    useful_low    = (raw.useful[pcpn_sel[1:0]] == 2'd0);           // TAGE_USE_ALT_USEFUL_THRESHOLD == 0
    prefer_alt    = (use_alt_ctr <= 4'd8);                         // TAGE_USE_ALT_CTR_USE_ALT_THRESHOLD
    if (pcpn_sel >= PCPN_W'(TN)) pred = base_pred;
    else if (provider_weak && useful_low && prefer_alt) pred = alt_pred;
    else pred = provider_pred;
  end

endmodule

`default_nettype wire
