// Ref: front-end/BPU/BPU_pipe.h  (S0 Block A/B 1-ahead/2-ahead & uFTB eval, S1/S2 eval & PTAB merge)
`default_nettype none

module bpu_eval import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                    refetch,
  // S0 inputs
  input  logic [XLEN_BITS-1:0]    s0_base,
  input  logic [XLEN_BITS-1:0]    s0_bnd,
  input  fh_t                     s0_fh,
  input  logic                    s0_ras_nonempty,
  input  logic [XLEN_BITS-1:0]    s0_ras_top,
  input  fh_t                     spec_a_fh,
  input  logic                    spec_a_ras_nonempty,
  input  logic [XLEN_BITS-1:0]    spec_a_ras_top,
  input  ftb_ah_pipe_t            ah_pipe0,
  input  ftb_ah_raw_t             ah2_pipe0,
  input  logic                    ftb0_hit,
  input  ftb_ent_t                ftb0_ent,
  input  logic                    ftb0_b_hit,
  input  ftb_ent_t                ftb0_b_ent,
  input  logic                    ah_prefer_alt,
  input  logic                    ah2_prefer_alt,
  // S1 / S2 inputs
  input  blk_t                    r0_q,
  input  blk_t                    r1_q,
  input  ftb_ix_t                 r1_ix_q,
  input  ftb_ix_t                 r1_ix_b_q,
  input  ftb_s1_raw_t             s1_raw,
  input  ftb_s1_raw_t             r1_raw_q,
  input  ftb_s1_raw_t             r1_raw_b_q,
  input  logic                    s2_prefer_alt,
  input  logic                    d_pair,
  input  logic [FTB_BLK_ID_W-1:0] blk_seq_q,
  input  logic [FTB_BLK_ID_W-1:0] seq1,
  // S0 outputs
  output logic                    ah_src_v,
  output logic                    ah_hit,
  output pred_t                   g0,
  output logic [XLEN_BITS-1:0]    s0_b_base,
  output logic [XLEN_BITS-1:0]    s0_b_bnd,
  output logic [3:0]              s0_a_len,
  output logic [3:0]              s0_b_len,
  output pred_t                   g0_b,
  output logic                    s0_paired,
  output ftb_ix_t                 s0_b_ix,
  output logic [XLEN_BITS-1:0]    ah_rd_base,
  output fh_t                     ah_rd_fh,
  output ftb_ix_t                 ah_rd_ix,
  // S1 / S2 outputs
  output pred_t                   g1,
  output pred_t                   fin,
  output pred_t                   fin_b,
  output logic [NLANE-1:0]        out_pred_dir,
  output logic [NLANE-1:0]        out_alt_pred,
  output logic [PCPN_W-1:0]       out_pcpn      [NLANE],
  output logic [T_TAG_W-1:0]      out_tage_tags [NLANE][TN],
  output logic [T_IDX_W-1:0]      out_tage_idxs [NLANE][TN]
);

  // ---- S0 Block A: 1-ahead select + uFTB fallback ----
  logic [FTB_AH_TAG_W-1:0] ah_sel_tag;
  ftb_ent_t                ah_ent;
  ftb_ix_t                 ah_sel_ix;
  logic [FTB_SLOTS-1:0]    ah_dirs;
  ftb_tage_pred_t          ah_tp [FTB_SLOTS];
  ftb_itt_sel_t            ah_itt;
  ftb_eval_res_t           ah_eval, u0_eval;

  always_comb begin
    ah_src_v   = !refetch && ah_pipe0.valid;
    ah_sel_tag = ftb_ah_tag(ah_pipe0.key_base, s0_base, $clog2(FTB_AH_SETS));
    ah_hit     = 1'b0;
    ah_ent     = '0;
    if (ah_src_v) begin
      for (int w = 0; w < FTB_AH_WAYS; w++) begin
        if (!ah_hit && ah_pipe0.raw.ftb_ways[w].valid &&
            (ah_pipe0.raw.ftb_ways[w].tag == FTB_MAX_TAG_W'(ah_sel_tag))) begin
          ah_hit = 1'b1;
          ah_ent = ah_pipe0.raw.ftb_ways[w];
        end
      end
    end
    ah_sel_ix = ftb_make_ah_index(ah_pipe0.key_base, s0_base, ah_pipe0.key_fh);
    for (int k = 0; k < FTB_SLOTS; k++) begin
      ah_tp[k]   = ftb_tage_select(ah_sel_ix, ah_pipe0.raw.tage_raw[k],
                                   ah_ent.s[k].valid, ah_ent.s[k].ctr, ah_prefer_alt);
      ah_dirs[k] = ah_tp[k].pred;
    end
    ah_itt  = ftb_itt_select(ah_sel_ix, ah_pipe0.raw.itt_raw);
    ah_eval = ftb_eval_ent(s0_base, s0_bnd, ah_ent, ah_hit, 1'b1, ah_dirs, ah_itt.hit, ah_itt.target,
                           s0_ras_nonempty, s0_ras_top);
    u0_eval = ftb_eval_ent(s0_base, s0_bnd, ftb0_ent, ftb0_hit, 1'b0, '0, 1'b0, '0,
                           s0_ras_nonempty, s0_ras_top);
    g0      = ah_hit ? ah_eval.pred : u0_eval.pred;
  end

  // ---- S0 Block B: 2-ahead B select + uFTB fallback + strict NT=1 + 4-bank ic_pair_ok ----
  logic                    a_upper_ok, disc_ok, b_cand_ok, b_truncated, ah2_hit;
  logic [4:0]              s0_a_len5, s0_b_len5;
  logic [XLEN_BITS-1:0]    a_br_pc, max_b_end, full_bnd_b;
  logic [FTB_AH_TAG_W-1:0] ah2_sel_tag;
  ftb_ent_t                ah2_ent;
  ftb_ix_t                 ah2_sel_ix;
  logic [FTB_SLOTS-1:0]    ah2_dirs;
  ftb_tage_pred_t          ah2_tp [FTB_SLOTS];
  ftb_itt_sel_t            ah2_itt;
  ftb_eval_res_t           ah2_eval, u0_b_eval;

  always_comb begin
    s0_b_base   = g0.next;
    s0_a_len5   = {1'b0, g0.slot} + 5'd1;
    a_upper_ok  = g0.rvc || ((g0.slot == '0) && g0.carried) ||
                  ((s0_base + (XLEN_BITS'(s0_a_len5) << SLOT_SHIFT)) < s0_bnd);
    a_br_pc     = ((g0.slot == '0) && g0.carried) ?
                  (s0_base - XLEN_BITS'(SLOT_BYTES)) :
                  (s0_base + (XLEN_BITS'(g0.slot) << SLOT_SHIFT));
    disc_ok     = (s0_b_base != (s0_base + (XLEN_BITS'(s0_a_len5) << SLOT_SHIFT))) &&
                  (s0_b_base != (a_br_pc + (g0.rvc ? XLEN_BITS'(2) : XLEN_BITS'(4))));
    max_b_end   = s0_b_base + (XLEN_BITS'(5'(FETCH_WIDTH) - s0_a_len5) << SLOT_SHIFT);
    full_bnd_b  = block_bnd(s0_b_base);
    s0_b_bnd    = (full_bnd_b < max_b_end) ? full_bnd_b : max_b_end;
    b_truncated = (full_bnd_b > max_b_end);
    s0_b_len5   = 5'((s0_b_bnd - s0_b_base) >> SLOT_SHIFT);
    b_cand_ok   = g0.taken && (s0_a_len5 >= 5'd1) && (s0_a_len5 < 5'(FETCH_WIDTH)) &&
                  a_upper_ok && disc_ok && ic_pair_ok(s0_base, s0_b_base) && (s0_b_len5 >= 5'd2);
    s0_a_len    = s0_a_len5[3:0];
    s0_b_len    = s0_b_len5[3:0];
  end

  always_comb begin
    ah2_sel_tag = ftb_ah_tag(ah_pipe0.key_base, s0_b_base, $clog2(FTB_AH2_SETS));
    ah2_hit     = 1'b0;
    ah2_ent     = '0;
    if (ah_src_v) begin
      for (int w = 0; w < FTB_AH2_WAYS; w++) begin
        if (!ah2_hit && ah2_pipe0.ftb_ways[w].valid &&
            (ah2_pipe0.ftb_ways[w].tag == FTB_MAX_TAG_W'(ah2_sel_tag))) begin
          ah2_hit = 1'b1;
          ah2_ent = ah2_pipe0.ftb_ways[w];
        end
      end
    end
    ah2_sel_ix = ftb_make_ah_index(ah_pipe0.key_base, s0_b_base, ah_pipe0.key_fh);
    for (int k = 0; k < FTB_SLOTS; k++) begin
      ah2_tp[k]   = ftb_tage_select(ah2_sel_ix, ah2_pipe0.tage_raw[k],
                                    ah2_ent.s[k].valid, ah2_ent.s[k].ctr, ah2_prefer_alt);
      ah2_dirs[k] = ah2_tp[k].pred;
    end
    ah2_itt   = ftb_itt_select(ah2_sel_ix, ah2_pipe0.itt_raw);
    ah2_eval  = ftb_eval_ent(s0_b_base, s0_b_bnd, ah2_ent, ah2_hit, 1'b1, ah2_dirs, ah2_itt.hit, ah2_itt.target,
                             spec_a_ras_nonempty, spec_a_ras_top);
    u0_b_eval = ftb_eval_ent(s0_b_base, s0_b_bnd, ftb0_b_ent, ftb0_b_hit, 1'b0, '0, 1'b0, '0,
                             spec_a_ras_nonempty, spec_a_ras_top);
    g0_b      = ah2_hit ? ah2_eval.pred : u0_b_eval.pred;
    s0_paired = b_cand_ok && (!b_truncated || g0_b.taken);
    s0_b_ix   = ftb_make_index(s0_b_base, spec_a_fh);
    ah_rd_base = s0_paired ? s0_b_base : s0_base;
    ah_rd_fh   = s0_paired ? spec_a_fh : s0_fh;
    ah_rd_ix   = ftb_make_ah_index(ah_rd_base, '0, ah_rd_fh);
  end

  // ---- S1 fallback guess & S2 final select (Block A + Block B) ----
  logic [XLEN_BITS-1:0] s2_bnd;
  logic [FTB_SLOTS-1:0] s2_dirs, s2_b_dirs;
  ftb_tage_pred_t       s2_tp [FTB_SLOTS], s2_b_tp [FTB_SLOTS];
  ftb_itt_sel_t         s2_itt, s2_b_itt;
  ftb_eval_res_t        s1_eval, s2_eval, s2_b_eval;
  logic [NLANE-1:0]     a_pred_dir, a_alt_pred, b_pred_dir, b_alt_pred;
  logic [PCPN_W-1:0]    a_pcpn [NLANE], b_pcpn [NLANE];

  always_comb begin
    s1_eval = ftb_eval_ent(r0_q.base, block_bnd(r0_q.base), s1_raw.ent, s1_raw.ftb_hit, 1'b0, '0, 1'b0, '0,
                           r0_q.ck.r.cnt != '0, r0_q.ck.r.top);
    g1      = s1_eval.pred;

    s2_bnd = block_bnd(r1_q.base);
    for (int k = 0; k < FTB_SLOTS; k++) begin
      s2_tp[k]     = ftb_tage_select(r1_ix_q, r1_raw_q.s2_tage_raw[k], 1'b0, 2'd0, s2_prefer_alt);
      s2_dirs[k]   = s2_tp[k].pred;
      s2_b_tp[k]   = ftb_tage_select(r1_ix_b_q, r1_raw_b_q.s2_tage_raw[k], 1'b0, 2'd0, s2_prefer_alt);
      s2_b_dirs[k] = s2_b_tp[k].pred;
    end
    s2_itt    = ftb_itt_select(r1_ix_q, r1_raw_q.itt_raw);
    s2_eval   = ftb_eval_ent(r1_q.base, s2_bnd, r1_raw_q.ent, r1_raw_q.ftb_hit, 1'b1, s2_dirs,
                             s2_itt.hit, s2_itt.target, r1_q.ck.r.cnt != '0, r1_q.ck.r.top);
    fin       = s2_eval.pred;
    s2_b_itt  = ftb_itt_select(r1_ix_b_q, r1_raw_b_q.itt_raw);
    s2_b_eval = ftb_eval_ent(r1_q.base_b, r1_q.bnd_b, r1_raw_b_q.ent, r1_raw_b_q.ftb_hit, 1'b1, s2_b_dirs,
                             s2_b_itt.hit, s2_b_itt.target, r1_q.ck_b.r.cnt != '0, r1_q.ck_b.r.top);
    fin_b     = s2_b_eval.pred;
  end

  always_comb begin
    a_pred_dir = '0; a_alt_pred = '0;
    b_pred_dir = '0; b_alt_pred = '0;
    for (int i = 0; i < NLANE; i++) begin
      a_pcpn[i] = PCPN_W'(TN);
      b_pcpn[i] = PCPN_W'(TN);
    end
    if (r1_raw_q.ftb_hit) begin
      for (int k = 0; k < FTB_SLOTS; k++) begin
        if (r1_raw_q.ent.s[k].valid &&
            ((r1_q.base + (XLEN_BITS'(r1_raw_q.ent.s[k].offset) << SLOT_SHIFT)) < s2_bnd)) begin
          a_pred_dir[r1_raw_q.ent.s[k].offset] = s2_eval.slot_tk[k];
          a_alt_pred[r1_raw_q.ent.s[k].offset] = s2_tp[k].alt;
          a_pcpn[r1_raw_q.ent.s[k].offset]     = s2_tp[k].pcpn;
        end
      end
    end
    if (r1_raw_b_q.ftb_hit) begin
      for (int k = 0; k < FTB_SLOTS; k++) begin
        if (r1_raw_b_q.ent.s[k].valid &&
            ((r1_q.base_b + (XLEN_BITS'(r1_raw_b_q.ent.s[k].offset) << SLOT_SHIFT)) < r1_q.bnd_b)) begin
          b_pred_dir[r1_raw_b_q.ent.s[k].offset] = s2_b_eval.slot_tk[k];
          b_alt_pred[r1_raw_b_q.ent.s[k].offset] = s2_b_tp[k].alt;
          b_pcpn[r1_raw_b_q.ent.s[k].offset]     = s2_b_tp[k].pcpn;
        end
      end
    end
    for (int i = 0; i < NLANE; i++) begin
      logic [3:0] j;
      j = 4'(i) - r1_q.a_len;
      if (d_pair && (4'(i) >= r1_q.a_len)) begin
        out_pred_dir[i]     = b_pred_dir[j];
        out_alt_pred[i]     = b_alt_pred[j];
        out_pcpn[i]         = b_pcpn[j];
        out_tage_idxs[i][0] = seq1;
        for (int t = 1; t < TN; t++) out_tage_idxs[i][t] = r1_ix_b_q.idx[t][T_IDX_W-1:0];
        for (int t = 0; t < TN; t++) out_tage_tags[i][t] = r1_ix_b_q.tag[t][T_TAG_W-1:0];
      end else begin
        out_pred_dir[i]     = a_pred_dir[i];
        out_alt_pred[i]     = a_alt_pred[i];
        out_pcpn[i]         = a_pcpn[i];
        out_tage_idxs[i][0] = blk_seq_q;
        for (int t = 1; t < TN; t++) out_tage_idxs[i][t] = r1_ix_q.idx[t][T_IDX_W-1:0];
        for (int t = 0; t < TN; t++) out_tage_tags[i][t] = r1_ix_q.tag[t][T_TAG_W-1:0];
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_eval;
  assign unused_eval = ^{r0_q, r1_q, s1_raw, ah_eval.slot_tk, u0_eval.slot_tk, ah2_eval.slot_tk, u0_b_eval.slot_tk,
                         s1_eval.slot_tk, ah_tp[0].alt, ah_tp[0].pcpn, ah_tp[0].used_alt,
                         ah2_tp[0].alt, ah2_tp[0].pcpn, ah2_tp[0].used_alt,
                         s2_tp[0].used_alt, s2_b_tp[0].used_alt};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
