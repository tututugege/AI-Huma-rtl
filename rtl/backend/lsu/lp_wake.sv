// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (f7st L1 spec wakeup + L3 + L2b STLF / L2a fallback + V2 WBP)
`default_nettype none

// Load-consumer wakeup (NWK = 3*NLD + NWBP = 14) and speculative-wakeup cancel:
//   [0..NLD-1]         : L1 speculative wakeup from registered AGU/RP slot l1[p] gated by no_l1_spec,
//                        !ld_retry_busy[p], and 256x2-bit PC predictor l1_hit_pred_q[pc8] >= 2 (reset 2'd2)
//   [NLD..2*NLD-1]     : L3 register direct write-back wakeup when not already spec-woken (l3_sw_q[p] == 0)
//   [2*NLD..3*NLD-1]   : L2b confirmed STLF wakeup (wbd_l2b_ep[p]) or L2a fallback wakeup (!spec_w && !l2b_w)
//   [3*NLD..NWK-1]     : V2 decoupled WBP wakeup via 64->NWBP one-hot mux (wp_acc / wp_oh)
module lp_wake
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
  import ttg_util_pkg::ttg_rob_younger;
(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                flush,
  input  logic                mispred,
  input  logic [ROBW-1:0]     dec_rob_idx,
  input  logic                dec_rob_flag,
  input  lp_l1in_t            l1 [NLD],
  input  logic [NLD-1:0]      ld_retry_busy,
  input  lp_pl12_t            pl12 [NLD],
  input  logic [LQW-1:0]      pl2b_idx [NLD],
  input  logic [LQ-1:0]       l2_ok,
  input  logic [LQ-1:0]       pipe_r,
  input  lp_ldq_t             ldq_q [LQ],
  input  logic [NLD-1:0]      wbd_v,                 // direct completions decided at L2 (L2a PF or L2b STLF or DC HIT)
  input  logic [LQW-1:0]      wbd_idx [NLD],
  input  logic [NLD-1:0]      wbd_l2b_ep,            // confirmed L2b STLF completion with matching epoch
  input  logic [NLD-1:0]      wbw_v,                 // write-back requests of this cycle (L3)
  input  logic [LQW-1:0]      wbw_idx [NLD],
  input  logic [NWBP-1:0]     wp_acc,                // V2 WBP accepted picks (from lp_wb)
  input  logic [LQ-1:0]       wp_oh [NWBP],
  output logic [NLD-1:0]      l1_spec_w,
  output logic [NWK-1:0]      wk_valid,
  output logic [PRFW-1:0]     wk_preg [NWK],
  output logic [NLD-1:0]      cn_valid,
  output logic [PRFW-1:0]     cn_preg [NLD]
);

  // 256 x 2-bit saturating PC-indexed L1D hit confidence predictor (reset 2'd2, wake iff >= 2)
  logic [1:0] l1_hit_pred_q [256];
  logic [1:0] l1_hit_pred_d [256];

  logic [NLD-1:0] l1_sw_w, l2b_w, l2_sw_w, l1_eff_w, spec_trk, hit_direct, train_en;
  logic [PRFW-1:0] spec_preg_trk [NLD];
  logic [NLD-1:0] l3_sw_q, cn_q;
  logic [PRFW-1:0] cn_preg_q [NLD];
  logic [255:0]   pc8_oh [NLD];

  for (genvar p = 0; p < NLD; p++) begin : g_pc8_dec
    always_comb begin
      pc8_oh[p]             = '0;
      pc8_oh[p][pl12[p].pc8] = 1'b1;
    end
  end

  // V2 WBP direct one-hot metadata mux (zero 64-entry scan)
  typedef struct packed {
    logic            elig;
    logic [PRFW-1:0] dest_preg;
  } lp_wbp_wk_t;
  lp_wbp_wk_t wbp_meta_v [LQ], wbp_meta_sel [NWBP];

  always_comb begin
    for (int e = 0; e < LQ; e++) begin
      wbp_meta_v[e].elig = !ldq_q[e].second && !ldq_q[e].pf &&
                           (ldq_q[e].dest_preg != '0) && !flush &&
                           !(mispred && ttg_rob_younger(ldq_q[e].rob_idx, ldq_q[e].rob_flag,
                                                       dec_rob_idx, dec_rob_flag));
      wbp_meta_v[e].dest_preg = ldq_q[e].dest_preg;
    end
  end

  for (genvar m = 0; m < NWBP; m++) begin : g_wbp_wk
    ttg_onehot_mux #(.N(LQ), .W($bits(lp_wbp_wk_t))) u_wbp_mux (
      .sel(wp_oh[m]), .data(wbp_meta_v), .out(wbp_meta_sel[m])
    );
  end

  always_comb begin
    wk_valid = '0;
    for (int k = 0; k < NWK; k++) wk_preg[k] = '0;
    l1_sw_w      = '0;
    l2b_w        = '0;
    l2_sw_w      = '0;
    l1_eff_w     = '0;
    spec_trk     = '0;
    hit_direct   = '0;
    train_en     = '0;
    for (int p = 0; p < NLD; p++) spec_preg_trk[p] = '0;

    for (int p = 0; p < NLD; p++) begin
      logic            l2a_alive_p, l1_pred_ok;
      logic [LQW-1:0]  l2a_ldq, l2b_ldq, l3_ldq;

      // [0..NLD-1]: f7st L1 speculative wakeup from registered AGU/RP slot
      l1_pred_ok = l1[p].replay || l1_hit_pred_q[l1[p].pc8][1];
      l1_sw_w[p] = l1[p].v && !l1[p].no_l1_spec && !ld_retry_busy[p] && l1_pred_ok &&
                   !l1[p].second && (l1[p].dest != '0) && !flush &&
                   !(mispred && ttg_rob_younger(l1[p].rob_idx, l1[p].rob_flag, dec_rob_idx, dec_rob_flag));
      wk_valid[p] = l1_sw_w[p];
      wk_preg[p]  = l1[p].dest;

      // [NLD..2*NLD-1]: L3 register direct write-back wakeup (unless already woken speculatively at L1/L2)
      l3_ldq = wbw_idx[p];
      wk_valid[NLD + p] = wbw_v[p] && !l3_sw_q[p] &&
                          !ldq_q[l3_ldq].second && !ldq_q[l3_ldq].pf &&
                          (ldq_q[l3_ldq].dest_preg != '0) && !flush &&
                          !(mispred && ttg_rob_younger(ldq_q[l3_ldq].rob_idx, ldq_q[l3_ldq].rob_flag,
                                                      dec_rob_idx, dec_rob_flag));
      wk_preg[NLD + p]  = ldq_q[l3_ldq].dest_preg;

      // [2*NLD..3*NLD-1]: L2b confirmed STLF wakeup or L2a fallback speculative wakeup
      l2a_ldq     = pl12[p].ldq;
      l2b_ldq     = pl2b_idx[p];
      l2a_alive_p = pl12[p].v && l2_ok[l2a_ldq] && (pl12[p].epoch == ldq_q[l2a_ldq].epoch);

      l1_eff_w[p] = pl12[p].v && pl12[p].spec_w && !flush &&
                    !(mispred && ttg_rob_younger(ldq_q[l2a_ldq].rob_idx, ldq_q[l2a_ldq].rob_flag,
                                                dec_rob_idx, dec_rob_flag));

      l2b_w[p]    = wbd_l2b_ep[p] && !ldq_q[l2b_ldq].second &&
                    (ldq_q[l2b_ldq].dest_preg != '0) && !flush &&
                    !(mispred && ttg_rob_younger(ldq_q[l2b_ldq].rob_idx, ldq_q[l2b_ldq].rob_flag,
                                                dec_rob_idx, dec_rob_flag));

      l2_sw_w[p]  = !pl12[p].spec_w && !l2b_w[p] && l2a_alive_p &&
                    (pl12[p].tlb == PL12_TLB_HIT) && !pl12[p].mmio && !pl12[p].dcblk && !pl12[p].bloom &&
                    !ldq_q[l2a_ldq].second && (ldq_q[l2a_ldq].dest_preg != '0) && !flush &&
                    !(mispred && ttg_rob_younger(ldq_q[l2a_ldq].rob_idx, ldq_q[l2a_ldq].rob_flag,
                                                dec_rob_idx, dec_rob_flag));

      wk_valid[2*NLD + p] = l2b_w[p] || l2_sw_w[p];
      wk_preg[2*NLD + p]  = l2b_w[p] ? ldq_q[l2b_ldq].dest_preg : ldq_q[l2a_ldq].dest_preg;

      // Cancel / L3 sw tracking for L1 or L2a speculative wakeups (require PL12_TLB_HIT for direct hit!)
      spec_trk[p]      = l1_eff_w[p] || l2_sw_w[p];
      spec_preg_trk[p] = l1_eff_w[p] ? pl12[p].spec_preg : ldq_q[l2a_ldq].dest_preg;
      hit_direct[p]    = wbd_v[p] && (wbd_idx[p] == l2a_ldq) && (pl12[p].tlb == PL12_TLB_HIT);

      // Train L1D hit confidence predictor (+1 on direct hit, -1 on non-direct)
      train_en[p] = pl12[p].v && !pl12[p].replay && !pl12[p].dcblk &&
                    pipe_r[l2a_ldq] && (ldq_q[l2a_ldq].epoch == pl12[p].epoch) &&
                    !ldq_q[l2a_ldq].second && (ldq_q[l2a_ldq].dest_preg != '0) && !flush &&
                    !(mispred && ttg_rob_younger(ldq_q[l2a_ldq].rob_idx, ldq_q[l2a_ldq].rob_flag,
                                                dec_rob_idx, dec_rob_flag));
    end

    // [3*NLD..NWK-1]: V2 decoupled WBP wakeup
    for (int m = 0; m < NWBP; m++) begin
      wk_valid[3*NLD + m] = wp_acc[m] && wbp_meta_sel[m].elig;
      wk_preg[3*NLD + m]  = wbp_meta_sel[m].dest_preg;
    end
  end

  // Per-bucket parallel predictor update across ports 0..NLD-1 (preserves model sequential port order without 256:1 muxes)
  for (genvar b = 0; b < 256; b++) begin : g_pred_upd
    always_comb begin
      logic [1:0] cur_c;
      cur_c = l1_hit_pred_q[b];
      for (int p = 0; p < NLD; p++) begin
        if (train_en[p] && pc8_oh[p][b]) begin
          if (hit_direct[p]) cur_c = (cur_c < 2'd3) ? (cur_c + 2'd1) : 2'd3;
          else               cur_c = (cur_c > 2'd0) ? (cur_c - 2'd1) : 2'd0;
        end
      end
      l1_hit_pred_d[b] = cur_c;
    end
  end

  assign l1_spec_w = l1_sw_w;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int b = 0; b < 256; b++) l1_hit_pred_q[b] <= 2'd2;
    end else begin
      for (int b = 0; b < 256; b++) l1_hit_pred_q[b] <= l1_hit_pred_d[b];
    end
    for (int p = 0; p < NLD; p++) begin
      cn_q[p]      <= rst_n && spec_trk[p] && !hit_direct[p];
      cn_preg_q[p] <= spec_preg_trk[p];
      l3_sw_q[p]   <= rst_n && ((spec_trk[p] && hit_direct[p]) || l2b_w[p]);
    end
  end

  assign cn_valid = cn_q;
  always_comb begin
    for (int p = 0; p < NLD; p++) cn_preg[p] = cn_preg_q[p];
  end

endmodule

`default_nettype wire
