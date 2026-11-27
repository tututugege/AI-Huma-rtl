// Ref: front-end/BPU/BPU_pipe.h  (Clean BPU v11: S0 1-Ahead A / uFTB + AhMeta, S2 Main FTB / 6-tbl ExTAGE / ITT + S2Meta)
`default_nettype none

module bpu_eval import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                    refetch,
  // S0 inputs
  input  logic [XLEN_BITS-1:0]    s0_base,
  input  logic [XLEN_BITS-1:0]    s0_bnd,
  input  logic                    s0_ras_nonempty,
  input  logic [XLEN_BITS-1:0]    s0_ras_top,
  input  ftb_ah_pipe_t            ah_pipe0,
  input  logic                    ftb0_hit,
  input  ftb_ent_t                ftb0_ent,
  input  logic                    ah_prefer_alt,
  // S2 inputs (1RW SRAM read outputs for r1_q)
  /* verilator lint_off UNUSEDSIGNAL */
  input  blk_t                    r1_q,
  /* verilator lint_on UNUSEDSIGNAL */
  input  ftb_ix_t                 r1_ix_q,
  input  ex_tage_ix_t             r1_ex_ix_q,
  input  logic                    s2_ftb_hit,
  input  logic [1:0]              s2_ftb_way,
  input  ftb_ent_t                s2_ftb_ent,
  input  ex_tage_raw_t            s2_tage_raw,
  input  ftb_itt_raw_t            s2_itt_raw,
  input  logic [15:0][3:0]        s2_use_alt,
  input  logic [FTB_BLK_ID_W-1:0] blk_seq_q,
  // S0 outputs
  output logic                    ah_src_v,
  output logic                    ah_hit,
  output pred_t                   g0,
  output ah_pred_meta_t           s0_ah_meta,
  // S2 outputs
  output pred_t                   fin,
  output logic                    fin_diff,
  output s2_pred_meta_t           s2_meta,
  output logic [NLANE-1:0]        out_pred_dir,
  output logic [NLANE-1:0]        out_alt_pred,
  output logic [PCPN_W-1:0]       out_pcpn      [NLANE],
  output logic [FTB_BLK_ID_W-1:0] out_blk_id
);

  // ---- S0: 1-Ahead A select + AhMeta capture + uFTB cold-start fallback ----
  logic [FTB_AH_TAG_W-1:0] ah_sel_tag;
  logic [FTB_AH_WAYS-1:0]  ah_w_match, ah_w_oh;
  logic [2:0]              ah_hit_way;
  ftb_ent_t                ah_ent;
  ftb_ix_t                 ah_sel_ix;
  logic [FTB_SLOTS-1:0]    ah_dirs;
  ftb_tage_pred_t          ah_tp [FTB_SLOTS];
  ftb_itt_sel_t            ah_itt;
  ftb_eval_res_t           ah_eval, u0_eval;

  always_comb begin
    ah_src_v   = !refetch && ah_pipe0.valid;
    ah_sel_tag = ftb_ah_tag(ah_pipe0.key_base, s0_base, $clog2(FTB_AH_SETS));
    for (int w = 0; w < FTB_AH_WAYS; w++) begin
      ah_w_match[w] = ah_src_v && ah_pipe0.raw.ftb_ways[w].valid &&
                      (ah_pipe0.raw.ftb_ways[w].tag == FTB_MAX_TAG_W'(ah_sel_tag));
    end
  end
  ttg_first_set #(.N(FTB_AH_WAYS)) u_ah_fs (.req(ah_w_match), .onehot(ah_w_oh), .any(ah_hit));

  always_comb begin
    ah_ent     = '0;
    ah_hit_way = 3'd0;
    for (int w = 0; w < FTB_AH_WAYS; w++) begin
      if (ah_w_oh[w]) begin
        ah_ent     = ah_ent | ah_pipe0.raw.ftb_ways[w];
        ah_hit_way = 3'(w);
      end
    end
    ah_sel_ix  = ftb_make_ah_index(ah_pipe0.key_base, s0_base, ah_pipe0.key_ex_fh);
    s0_ah_meta = '0;
    if (ah_src_v) begin
      s0_ah_meta.ftb.hit = ah_hit;
      s0_ah_meta.ftb.way = ah_hit_way;
      s0_ah_meta.ftb.ent = ah_hit ? ah_ent : '0;
    end
    for (int k = 0; k < FTB_SLOTS; k++) begin
      ah_tp[k]   = ftb_tage_select(ah_sel_ix, ah_pipe0.raw.tage_raw[k],
                                   ah_hit && ah_ent.s[k].valid, ah_ent.s[k].ctr, ah_prefer_alt);
      ah_dirs[k] = ah_tp[k].pred;
      if (ah_src_v) begin
        s0_ah_meta.tage[k].pcpn     = ah_tp[k].pcpn;
        s0_ah_meta.tage[k].pred     = ah_tp[k].pred;
        s0_ah_meta.tage[k].alt      = ah_tp[k].alt;
        s0_ah_meta.tage[k].prov_cnt = (ah_tp[k].pcpn < PCPN_W'(TN)) ? ah_pipe0.raw.tage_raw[k].cnt[ah_tp[k].pcpn[1:0]] : 3'd0;
        s0_ah_meta.tage[k].prov_u   = (ah_tp[k].pcpn < PCPN_W'(TN)) ? ah_pipe0.raw.tage_raw[k].useful[ah_tp[k].pcpn[1:0]] : 2'd0;
        s0_ah_meta.tage[k].useful   = ah_pipe0.raw.tage_raw[k].useful;
      end
    end
    ah_itt = ftb_itt_select(ah_sel_ix, ah_pipe0.raw.itt_raw);
    if (ah_src_v) s0_ah_meta.itt = ftb_itt_meta(ah_sel_ix, ah_pipe0.raw.itt_raw);
    ah_eval = ftb_eval_ent(s0_base, s0_bnd, ah_ent, ah_hit, 1'b1, ah_dirs, ah_itt.hit, ah_itt.target,
                           s0_ras_nonempty, s0_ras_top);
    u0_eval = ftb_eval_ent(s0_base, s0_bnd, ftb0_ent, ftb0_hit, 1'b0, '0, 1'b0, '0,
                           s0_ras_nonempty, s0_ras_top);
    g0      = ah_hit ? ah_eval.pred : u0_eval.pred;
  end

  // ---- S2: Exact-PC Main FTB + 6-table ExBlockTage + 3-table ITT final eval + S2Meta ----
  // Cut A2: pre-evaluate all 4 FTB slot predictions (bpc, tgt, ras_val, hbits) and 1-bit pred_differs(slot, r1_q.g)
  // IN PARALLEL with 6-table ex_tage_select, so s2_dirs only drives 4-slot winner select + 5:1 1-bit fin_diff mux!
  logic [XLEN_BITS-1:0] s2_bnd;
  logic [5:0]           s2_diff6;
  logic [4:0]           s2_nslots;
  logic [FTB_SLOTS-1:0] s2_dirs, s2_in_rng, s2_slot_tk, s2_win, s2_diff_slot;
  logic                 s2_diff_ft, s2_found, s2_ras_ne;
  ex_tage_pred_t        s2_tp [FTB_SLOTS];
  ftb_itt_sel_t         s2_itt;
  pred_t                s2_ft_pred;
  pred_t                s2_slot_pred [FTB_SLOTS];

  always_comb begin
    s2_bnd      = block_bnd(r1_q.base);
    s2_diff6    = s2_bnd[5:0] - r1_q.base[5:0];
    s2_nslots   = (s2_bnd != '0) ? 5'((s2_diff6 + 6'd1) >> 1) : 5'd0;
    s2_ras_ne   = (r1_q.ck.r.cnt != '0);
    s2_meta     = '0;
    s2_meta.ftb = '{hit: s2_ftb_hit, way: s2_ftb_way, ent: s2_ftb_hit ? s2_ftb_ent : '0};
    s2_itt      = ftb_itt_select(r1_ix_q, s2_itt_raw);
    s2_meta.itt = ftb_itt_meta(r1_ix_q, s2_itt_raw);

    // Parallel with ex_tage_select: Fallthrough & per-slot pred_t + 1-bit pred_differs against r1_q.g
    s2_ft_pred      = '0;
    s2_ft_pred.hit  = s2_ftb_hit;
    s2_ft_pred.next = s2_bnd;
    s2_ft_pred.ty   = BR_NONCTL;
    s2_diff_ft      = pred_differs(s2_ft_pred, r1_q.g);

    for (int k = 0; k < FTB_SLOTS; k++) begin
      /* verilator lint_off UNUSEDSIGNAL */
      ftb_slot_t            sk;
      /* verilator lint_on UNUSEDSIGNAL */
      logic [XLEN_BITS-1:0] bpc_k, tgt_k;
      sk = s2_ftb_ent.s[k];
      s2_in_rng[k] = sk.valid &&
                     (((sk.offset == 4'd0) && sk.carried) ? ((s2_bnd != '0) && (|r1_q.base[XLEN_BITS-1:1]))
                                                          : ({1'b0, sk.offset} < s2_nslots));
      bpc_k = (sk.offset == 4'd0 && sk.carried)
              ? (r1_q.base - XLEN_BITS'(SLOT_BYTES))
              : (r1_q.base + (XLEN_BITS'(sk.offset) << SLOT_SHIFT));
      tgt_k = sv39_unpack(sk.target);
      if (sk.br_type == BR_RET && s2_ras_ne)         tgt_k = r1_q.ck.r.top;
      else if (ftb_br_ind(sk.br_type) && s2_itt.hit) tgt_k = s2_itt.target;
      s2_slot_pred[k]         = '0;
      s2_slot_pred[k].hit     = 1'b1;
      s2_slot_pred[k].taken   = 1'b1;
      s2_slot_pred[k].slot    = UB_SLOT_W'(sk.offset);
      s2_slot_pred[k].ty      = sk.br_type;
      s2_slot_pred[k].rvc     = sk.is_rvc;
      s2_slot_pred[k].carried = sk.carried;
      s2_slot_pred[k].next    = tgt_k;
      s2_slot_pred[k].hbits   = hsym_of(bpc_k, tgt_k);
      if (ftb_br_call(sk.br_type)) begin
        s2_slot_pred[k].ras_op  = 2'd1;
        s2_slot_pred[k].ras_val = bpc_k + (sk.is_rvc ? XLEN_BITS'(2) : XLEN_BITS'(4));
      end else if (sk.br_type == BR_RET) begin
        s2_slot_pred[k].ras_op  = 2'd2;
      end
      s2_diff_slot[k] = pred_differs(s2_slot_pred[k], r1_q.g);
    end

    // 6-table ExBlockTage select (parallel with above 4-slot pre-eval!)
    for (int k = 0; k < FTB_SLOTS; k++) begin
      ex_tage_pred_t tp;
      tp         = ex_tage_select(r1_ex_ix_q, s2_tage_raw[k], s2_use_alt);
      s2_tp[k]   = tp;
      s2_dirs[k] = tp.pred;
      s2_meta.tage[k] = '{
        pcpn:     tp.pcpn,
        pred:     tp.pred,
        alt:      tp.alt,
        base_cnt: tp.base_cnt,
        prov_cnt: tp.prov_cnt,
        prov_u:   (tp.pcpn < 4'(EX_TN)) ? s2_tage_raw[k].useful[tp.pcpn[2:0]] : 2'd0,
        useful:   s2_tage_raw[k].useful
      };
    end

    // Late-arriving s2_dirs only drives 4-slot winner select + 5:1 mux for fin & 1-bit fin_diff
    for (int k = 0; k < FTB_SLOTS; k++) begin
      s2_slot_tk[k] = s2_ftb_hit && s2_in_rng[k] &&
                      ((s2_ftb_ent.s[k].br_type == BR_DIRECT) ? s2_dirs[k] : 1'b1);
    end
    for (int k = 0; k < FTB_SLOTS; k++) begin
      s2_win[k] = s2_slot_tk[k];
      for (int j = 0; j < FTB_SLOTS; j++) begin
        if (j < k)      s2_win[k] = s2_win[k] && (!s2_slot_tk[j] || (s2_ftb_ent.s[k].offset <  s2_ftb_ent.s[j].offset));
        else if (j > k) s2_win[k] = s2_win[k] && (!s2_slot_tk[j] || (s2_ftb_ent.s[k].offset <= s2_ftb_ent.s[j].offset));
      end
    end
    s2_found = |s2_win;
    fin_diff = (|(s2_win & s2_diff_slot)) || (!s2_found && s2_diff_ft);
    fin      = s2_ft_pred;
    for (int k = 0; k < FTB_SLOTS; k++) begin
      if (s2_win[k]) fin = s2_slot_pred[k];
    end
  end

  // ---- PTAB / FTQ lane metadata ----
  always_comb begin
    out_pred_dir = '0;
    out_alt_pred = '0;
    out_blk_id   = blk_seq_q;
    for (int i = 0; i < NLANE; i++) out_pcpn[i] = PCPN_W'(TN);
    if (s2_ftb_hit) begin
      for (int k = 0; k < FTB_SLOTS; k++) begin
        if (s2_ftb_ent.s[k].valid && ({1'b0, s2_ftb_ent.s[k].offset} < s2_nslots)) begin
          out_pred_dir[s2_ftb_ent.s[k].offset] = s2_slot_tk[k];
          out_alt_pred[s2_ftb_ent.s[k].offset] = s2_tp[k].alt;
          out_pcpn[s2_ftb_ent.s[k].offset]     = (s2_tp[k].pcpn < 4'(EX_TN))
              ? ((s2_tp[k].pcpn >= 4'(TN)) ? PCPN_W'(TN - 1) : PCPN_W'(s2_tp[k].pcpn))
              : PCPN_W'(TN);
        end
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = ^{ah_eval.slot_tk, u0_eval.slot_tk};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
