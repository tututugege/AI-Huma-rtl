// Ref: front-end/BPU/BPU_pipe.h  (v10: S0 Block A/B 1-ahead/2-ahead & uFTB eval + AhMeta, S2 pre-eval, S3 final eval + S2Meta)
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
  // S2 inputs (1RW SRAM read outputs for r1_q -> compact s3_blk_eval_t registers)
  input  ftb_ix_t                 r1_ix_q,
  input  ftb_ix_t                 r1_ix_b_q,
  input  ex_tage_ix_t             r1_ex_ix_q,
  input  ex_tage_ix_t             r1_ex_ix_b_q,
  input  logic                    s2_ftb_hit,
  input  logic [1:0]              s2_ftb_way,
  input  ftb_ent_t                s2_ftb_ent,
  input  logic                    s2_b_ftb_hit,
  input  logic [1:0]              s2_b_ftb_way,
  input  ftb_ent_t                s2_b_ftb_ent,
  input  ex_tage_raw_t            s2_tage_raw,
  input  sc_raw_t                 s2_sc_raw,
  input  logic [7:0]              s2_sc_loc_idx,
  input  ftb_itt_raw_t            s2_itt_raw,
  input  ex_tage_raw_t            s2_b_tage_raw,
  input  sc_raw_t                 s2_b_sc_raw,
  input  logic [7:0]              s2_b_sc_loc_idx,
  input  ftb_itt_raw_t            s2_b_itt_raw,
  // S3 inputs (registered compact S2 results for r2_q)
  /* verilator lint_off UNUSEDSIGNAL */
  input  blk_t                    r2_q,
  /* verilator lint_on UNUSEDSIGNAL */
  input  s3_blk_eval_t            s3_eval_a_q,
  input  s3_blk_eval_t            s3_eval_b_q,
  input  logic [15:0][3:0]        s2_use_alt,
  input  logic [15:0][5:0]        s2_sc_thres,
  input  logic                    d_pair,
  input  logic [FTB_BLK_ID_W-1:0] blk_seq_q,
  // S0 outputs
  output logic                    ah_src_v,
  output logic                    ah_hit,
  output pred_t                   g0,
  output ah_pred_meta_t           s0_ah_meta,
  output logic [XLEN_BITS-1:0]    s0_b_base,
  output logic [XLEN_BITS-1:0]    s0_b_bnd,
  output logic [3:0]              s0_a_len,
  output logic [3:0]              s0_b_len,
  output pred_t                   g0_b,
  output ah_pred_meta_t           s0_ah_meta_b,
  output logic                    s0_paired,
  output ftb_ix_t                 s0_b_ix,
  output logic [XLEN_BITS-1:0]    ah_rd_base,
  output fh_t                     ah_rd_fh,
  // S2 -> S3 outputs
  output s3_blk_eval_t            s2_eval_a_d,
  output s3_blk_eval_t            s2_eval_b_d,
  // S3 outputs
  output pred_t                   fin,
  output pred_t                   fin_b,
  output s2_pred_meta_t           s3_s2_meta_a,
  output s2_pred_meta_t           s3_s2_meta_b,
  output logic [NLANE-1:0]        out_pred_dir,
  output logic [NLANE-1:0]        out_alt_pred,
  output logic [PCPN_W-1:0]       out_pcpn      [NLANE],
  output logic [FTB_BLK_ID_W-1:0] out_blk_id
);

  // ---- S0 Block A: 1-ahead select + AhMeta capture + uFTB fallback ----
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
    ah_sel_ix = ftb_make_ah_index(ah_pipe0.key_base, s0_base, ah_pipe0.key_fh, 1'b0);
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

  // ---- S0 Block B: Parallel 2-ahead B + 4-Bank 1RW conflict filter + AhMeta B capture ----
  logic                    a_upper_ok, disc_ok, bank_ok, b_cand_ok, b_truncated, ah2_hit_raw, ah2_hit;
  logic [4:0]              s0_a_len5, s0_b_len5, s0_a_nslots;
  logic [5:0]              b_line_bytes, b_cap_bytes, b_eff_bytes;
  logic [6:0]              b_low_sum;
  logic [XLEN_BITS-1:0]    a_br_pc, ah2_b_base;
  logic [FTB_VA_BITS-1:0]  ah2_b_base38;
  logic [FTB_AH_TAG_W-1:0] ah2_sel_tag;
  logic [FTB_AH2_WAYS-1:0] ah2_w_match, ah2_w_oh;
  logic [2:0]              ah2_hit_way;
  ftb_ent_t                ah2_ent;
  ftb_ix_t                 ah2_sel_ix;
  logic [FTB_SLOTS-1:0]    ah2_dirs;
  ftb_tage_pred_t          ah2_tp [FTB_SLOTS];
  ftb_itt_sel_t            ah2_itt;
  ftb_eval_res_t           ah2_eval;

  always_comb begin
    s0_b_base    = g0.next;
    s0_a_len5    = {1'b0, g0.slot} + 5'd1;
    s0_a_nslots  = (s0_bnd != '0) ? 5'(((6'(s0_bnd[5:0]) - 6'(s0_base[5:0])) + 6'd1) >> 1) : 5'd0;
    a_upper_ok   = g0.rvc || ((g0.slot == '0) && g0.carried) || (s0_a_len5 < s0_a_nslots);
    a_br_pc      = ((g0.slot == '0) && g0.carried) ?
                   (s0_base - XLEN_BITS'(SLOT_BYTES)) :
                   (s0_base + (XLEN_BITS'(g0.slot) << SLOT_SHIFT));
    disc_ok      = (s0_b_base != (s0_base + (XLEN_BITS'(s0_a_len5) << SLOT_SHIFT))) &&
                   (s0_b_base != (a_br_pc + (g0.rvc ? XLEN_BITS'(2) : XLEN_BITS'(4))));
    bank_ok      = (s2_bank_of_pc(s0_base) != s2_bank_of_pc(s0_b_base));
    b_line_bytes = s0_b_base[5] ? (6'd0 - s0_b_base[5:0]) : 6'd32;
    b_cap_bytes  = {5'(FETCH_WIDTH) - s0_a_len5, 1'b0};
    b_eff_bytes  = (b_line_bytes < b_cap_bytes) ? b_line_bytes : b_cap_bytes;
    b_truncated  = (b_line_bytes > b_cap_bytes);
    b_low_sum    = {1'b0, s0_b_base[5:0]} + {1'b0, b_eff_bytes};
    s0_b_bnd     = {b_low_sum[6] ? (s0_b_base[XLEN_BITS-1:6] + (XLEN_BITS-6)'(1)) : s0_b_base[XLEN_BITS-1:6],
                    b_low_sum[5:0]};
    s0_b_len5    = b_eff_bytes[5:1];
    b_cand_ok    = g0.taken && (s0_a_len5 >= 5'd1) && (s0_a_len5 < 5'(FETCH_WIDTH)) &&
                   a_upper_ok && disc_ok && ic_pair_ok(s0_base, s0_b_base) && bank_ok && (s0_b_len5 >= 5'd2);
    s0_a_len     = s0_a_len5[3:0];
    s0_b_len     = s0_b_len5[3:0];
  end

  always_comb begin
    ah2_sel_tag = ftb_ah_tag(ah_pipe0.key_base, s0_base, $clog2(FTB_AH2_SETS));
    for (int w = 0; w < FTB_AH2_WAYS; w++) begin
      ah2_w_match[w] = ah_src_v && ah2_pipe0.ftb_ways[w].valid &&
                       (ah2_pipe0.ftb_ways[w].tag == FTB_MAX_TAG_W'(ah2_sel_tag));
    end
  end
  ttg_first_set #(.N(FTB_AH2_WAYS)) u_ah2_fs (.req(ah2_w_match), .onehot(ah2_w_oh), .any(ah2_hit_raw));
  always_comb begin
    ah2_ent      = '0;
    ah2_b_base38 = '0;
    ah2_hit_way  = 3'd0;
    for (int w = 0; w < FTB_AH2_WAYS; w++) begin
      if (ah2_w_oh[w]) begin
        ah2_ent      = ah2_ent      | ah2_pipe0.ftb_ways[w];
        ah2_b_base38 = ah2_b_base38 | ah2_pipe0.b_base[w];
        ah2_hit_way  = 3'(w);
      end
    end
    ah2_b_base = sv39_unpack(ah2_b_base38);
    ah2_hit    = ah2_hit_raw && (ah2_b_base == s0_b_base);
    ah2_sel_ix = ftb_make_ah_index(ah_pipe0.key_base, s0_base, ah_pipe0.key_fh, 1'b1);
    s0_ah_meta_b = '0;
    if (ah_src_v) begin
      s0_ah_meta_b.ftb.hit = ah2_hit;
      s0_ah_meta_b.ftb.way = ah2_hit_way;
      s0_ah_meta_b.ftb.ent = ah2_hit ? ah2_ent : '0;
    end
    for (int k = 0; k < FTB_SLOTS; k++) begin
      ah2_tp[k]   = ftb_tage_select(ah2_sel_ix, ah2_pipe0.tage_raw[k],
                                    ah2_hit && ah2_ent.s[k].valid, ah2_ent.s[k].ctr, ah2_prefer_alt);
      ah2_dirs[k] = ah2_tp[k].pred;
      if (ah_src_v) begin
        s0_ah_meta_b.tage[k].pcpn     = ah2_tp[k].pcpn;
        s0_ah_meta_b.tage[k].pred     = ah2_tp[k].pred;
        s0_ah_meta_b.tage[k].alt      = ah2_tp[k].alt;
        s0_ah_meta_b.tage[k].prov_cnt = (ah2_tp[k].pcpn < PCPN_W'(TN)) ? ah2_pipe0.tage_raw[k].cnt[ah2_tp[k].pcpn[1:0]] : 3'd0;
        s0_ah_meta_b.tage[k].prov_u   = (ah2_tp[k].pcpn < PCPN_W'(TN)) ? ah2_pipe0.tage_raw[k].useful[ah2_tp[k].pcpn[1:0]] : 2'd0;
        s0_ah_meta_b.tage[k].useful   = ah2_pipe0.tage_raw[k].useful;
      end
    end
    ah2_itt = ftb_itt_select(ah2_sel_ix, ah2_pipe0.itt_raw);
    if (ah_src_v) s0_ah_meta_b.itt = ftb_itt_meta(ah2_sel_ix, ah2_pipe0.itt_raw);
    ah2_eval  = ftb_eval_ent(ah2_b_base, block_bnd(ah2_b_base), ah2_ent, ah2_hit_raw, 1'b1, ah2_dirs,
                             ah2_itt.hit, ah2_itt.target, spec_a_ras_nonempty, spec_a_ras_top);
    g0_b      = ah2_hit ? ah2_eval.pred : '{hit: 1'b0, taken: 1'b0, slot: '0, ty: BR_NONCTL, rvc: 1'b0,
                                            carried: 1'b0, next: s0_b_bnd, hbits: '0, ras_op: 2'd0, ras_val: '0};
    if (ah2_hit && b_truncated && (!ah2_eval.pred.taken || ({1'b0, ah2_eval.pred.slot} >= s0_b_len5))) begin
      g0_b.taken  = 1'b0;
      g0_b.next   = s0_b_bnd;
      g0_b.hbits  = '0;
      g0_b.ras_op = 2'd0;
    end
    s0_paired  = b_cand_ok && (!b_truncated || g0_b.taken);
    s0_b_ix    = ftb_make_index(s0_b_base, spec_a_fh);
    ah_rd_base = s0_paired ? s0_b_base : s0_base;
    ah_rd_fh   = s0_paired ? spec_a_fh : s0_fh;
  end

  // ---- Stage S2: Parallel SRAM-to-reg pre-eval + Meta pack (-> s3_blk_eval_t) ----
  always_comb begin
    s2_eval_a_d         = '0;
    s2_eval_b_d         = '0;
    s2_eval_a_d.ftb_hit = s2_ftb_hit;
    s2_eval_a_d.ftb_way = s2_ftb_way;
    s2_eval_a_d.ftb_ent = s2_ftb_ent;
    s2_eval_b_d.ftb_hit = s2_b_ftb_hit;
    s2_eval_b_d.ftb_way = s2_b_ftb_way;
    s2_eval_b_d.ftb_ent = s2_b_ftb_ent;
    s2_eval_a_d.sc_meta.loc_idx = s2_sc_loc_idx;
    s2_eval_b_d.sc_meta.loc_idx = s2_b_sc_loc_idx;

    for (int k = 0; k < FTB_SLOTS; k++) begin
      ex_tage_pred_t ta, tb;
      logic          pa_weak, pb_weak, pa_ulow, pb_ulow;
      ta = ex_tage_select(r1_ex_ix_q,   s2_tage_raw[k],   s2_use_alt);
      tb = ex_tage_select(r1_ex_ix_b_q, s2_b_tage_raw[k], s2_use_alt);
      s2_eval_a_d.tage_tp[k] = ta;
      s2_eval_b_d.tage_tp[k] = tb;
      s2_eval_a_d.tage_pp[k] = (ta.pcpn == 4'(EX_TN)) ? (ta.base_cnt >= 2'd2) : (ta.prov_cnt >= 3'd4);
      s2_eval_b_d.tage_pp[k] = (tb.pcpn == 4'(EX_TN)) ? (tb.base_cnt >= 2'd2) : (tb.prov_cnt >= 3'd4);
      pa_weak = (ta.pcpn != 4'(EX_TN)) && ((ta.prov_cnt == 3'd3) || (ta.prov_cnt == 3'd4));
      pb_weak = (tb.pcpn != 4'(EX_TN)) && ((tb.prov_cnt == 3'd3) || (tb.prov_cnt == 3'd4));
      pa_ulow = (ta.pcpn != 4'(EX_TN)) && (s2_tage_raw[k].useful[ta.pcpn[2:0]]   == 2'd0);
      pb_ulow = (tb.pcpn != 4'(EX_TN)) && (s2_b_tage_raw[k].useful[tb.pcpn[2:0]] == 2'd0);
      s2_eval_a_d.tage_weak_ulow[k] = pa_weak && pa_ulow;
      s2_eval_b_d.tage_weak_ulow[k] = pb_weak && pb_ulow;
      s2_eval_a_d.tage_useful[k]    = s2_tage_raw[k].useful;
      s2_eval_b_d.tage_useful[k]    = s2_b_tage_raw[k].useful;
      s2_eval_a_d.sc_nonbias[k]     = sc_eval_nonbias(s2_sc_raw[k]);
      s2_eval_b_d.sc_nonbias[k]     = sc_eval_nonbias(s2_b_sc_raw[k]);
      s2_eval_a_d.sc_meta.s[k].bias = s2_sc_raw[k].bias;
      s2_eval_a_d.sc_meta.s[k].gehl = s2_sc_raw[k].gehl;
      s2_eval_a_d.sc_meta.s[k].imli = s2_sc_raw[k].imli;
      s2_eval_a_d.sc_meta.s[k].loc  = s2_sc_raw[k].loc;
      s2_eval_b_d.sc_meta.s[k].bias = s2_b_sc_raw[k].bias;
      s2_eval_b_d.sc_meta.s[k].gehl = s2_b_sc_raw[k].gehl;
      s2_eval_b_d.sc_meta.s[k].imli = s2_b_sc_raw[k].imli;
      s2_eval_b_d.sc_meta.s[k].loc  = s2_b_sc_raw[k].loc;
    end
    s2_eval_a_d.itt      = ftb_itt_select(r1_ix_q,   s2_itt_raw);
    s2_eval_b_d.itt      = ftb_itt_select(r1_ix_b_q, s2_b_itt_raw);
    s2_eval_a_d.itt_meta = ftb_itt_meta(r1_ix_q,     s2_itt_raw);
    s2_eval_b_d.itt_meta = ftb_itt_meta(r1_ix_b_q,   s2_b_itt_raw);
  end

  // ---- Stage S3: Fast reg-to-reg final select + S2Meta assembly + PTAB merge ----
  logic [XLEN_BITS-1:0] s3_bnd;
  logic [31:0]          s3_wa, s3_wb;
  logic [FTB_SLOTS-1:0] s3_dirs, s3_b_dirs;
  ftb_eval_res_t        s3_eval, s3_b_eval;
  logic [NLANE-1:0]     a_pred_dir, a_alt_pred, b_pred_dir, b_alt_pred;
  logic [PCPN_W-1:0]    a_pcpn [NLANE], b_pcpn [NLANE];

  always_comb begin
    s3_bnd = block_bnd(r2_q.base);
    s3_wa  = 32'(r2_q.base   >> SLOT_SHIFT);
    s3_wb  = 32'(r2_q.base_b >> SLOT_SHIFT);

    s3_s2_meta_a         = '0;
    s3_s2_meta_b         = '0;
    s3_s2_meta_a.ftb     = '{hit: s3_eval_a_q.ftb_hit, way: s3_eval_a_q.ftb_way, ent: s3_eval_a_q.ftb_hit ? s3_eval_a_q.ftb_ent : '0};
    s3_s2_meta_b.ftb     = '{hit: s3_eval_b_q.ftb_hit, way: s3_eval_b_q.ftb_way, ent: s3_eval_b_q.ftb_hit ? s3_eval_b_q.ftb_ent : '0};
    s3_s2_meta_a.sc      = s3_eval_a_q.sc_meta;
    s3_s2_meta_b.sc      = s3_eval_b_q.sc_meta;
    s3_s2_meta_a.itt     = s3_eval_a_q.itt_meta;
    s3_s2_meta_b.itt     = s3_eval_b_q.itt_meta;

    for (int k = 0; k < FTB_SLOTS; k++) begin
      logic ua_a, ua_b, pred_a, pred_b;
      logic [3:0] pa, pb;
      pa     = s3_eval_a_q.tage_tp[k].pcpn;
      pb     = s3_eval_b_q.tage_tp[k].pcpn;
      ua_a   = s3_eval_a_q.tage_weak_ulow[k] && (s2_use_alt[s3_wa[5:2]] <= FTB_USE_ALT_THR);
      ua_b   = s3_eval_b_q.tage_weak_ulow[k] && (s2_use_alt[s3_wb[5:2]] <= FTB_USE_ALT_THR);
      pred_a = ua_a ? s3_eval_a_q.tage_tp[k].alt : s3_eval_a_q.tage_pp[k];
      pred_b = ua_b ? s3_eval_b_q.tage_tp[k].alt : s3_eval_b_q.tage_pp[k];

      s3_s2_meta_a.tage[k] = '{
        pcpn:     pa,
        pred:     pred_a,
        alt:      s3_eval_a_q.tage_tp[k].alt,
        base_cnt: s3_eval_a_q.tage_tp[k].base_cnt,
        prov_cnt: s3_eval_a_q.tage_tp[k].prov_cnt,
        prov_u:   (pa < 4'(EX_TN)) ? s3_eval_a_q.tage_useful[k][pa[2:0]] : 2'd0,
        useful:   s3_eval_a_q.tage_useful[k]
      };
      s3_s2_meta_b.tage[k] = '{
        pcpn:     pb,
        pred:     pred_b,
        alt:      s3_eval_b_q.tage_tp[k].alt,
        base_cnt: s3_eval_b_q.tage_tp[k].base_cnt,
        prov_cnt: s3_eval_b_q.tage_tp[k].prov_cnt,
        prov_u:   (pb < 4'(EX_TN)) ? s3_eval_b_q.tage_useful[k][pb[2:0]] : 2'd0,
        useful:   s3_eval_b_q.tage_useful[k]
      };

      s3_dirs[k]   = sc_select_s3(s3_wa, s3_eval_a_q.sc_nonbias[k], s3_eval_a_q.sc_meta.s[k].bias,
                                  pred_a, pa < 4'(EX_TN),
                                  s3_eval_a_q.tage_tp[k].prov_cnt, s3_eval_a_q.tage_tp[k].base_cnt, s2_sc_thres);
      s3_b_dirs[k] = sc_select_s3(s3_wb, s3_eval_b_q.sc_nonbias[k], s3_eval_b_q.sc_meta.s[k].bias,
                                  pred_b, pb < 4'(EX_TN),
                                  s3_eval_b_q.tage_tp[k].prov_cnt, s3_eval_b_q.tage_tp[k].base_cnt, s2_sc_thres);
    end

    s3_eval   = ftb_eval_ent(r2_q.base, s3_bnd, s3_eval_a_q.ftb_ent, s3_eval_a_q.ftb_hit, 1'b1, s3_dirs,
                             s3_eval_a_q.itt.hit, s3_eval_a_q.itt.target, r2_q.ck.r.cnt != '0, r2_q.ck.r.top);
    fin       = s3_eval.pred;
    s3_b_eval = ftb_eval_ent(r2_q.base_b, r2_q.bnd_b, s3_eval_b_q.ftb_ent, s3_eval_b_q.ftb_hit, 1'b1, s3_b_dirs,
                             s3_eval_b_q.itt.hit, s3_eval_b_q.itt.target, r2_q.ck_b.r.cnt != '0, r2_q.ck_b.r.top);
    fin_b     = s3_b_eval.pred;
  end

  always_comb begin
    logic [4:0] s3_ns, s3_bns;
    s3_ns  = (s3_bnd != '0) ? 5'(((6'(s3_bnd[5:0]) - 6'(r2_q.base[5:0])) + 6'd1) >> 1) : 5'd0;
    s3_bns = (r2_q.bnd_b != '0) ? 5'(((6'(r2_q.bnd_b[5:0]) - 6'(r2_q.base_b[5:0])) + 6'd1) >> 1) : 5'd0;
    a_pred_dir = '0; a_alt_pred = '0;
    b_pred_dir = '0; b_alt_pred = '0;
    for (int i = 0; i < NLANE; i++) begin
      a_pcpn[i] = PCPN_W'(TN);
      b_pcpn[i] = PCPN_W'(TN);
    end
    if (s3_eval_a_q.ftb_hit) begin
      for (int k = 0; k < FTB_SLOTS; k++) begin
        if (s3_eval_a_q.ftb_ent.s[k].valid && ({1'b0, s3_eval_a_q.ftb_ent.s[k].offset} < s3_ns)) begin
          a_pred_dir[s3_eval_a_q.ftb_ent.s[k].offset] = s3_eval.slot_tk[k];
          a_alt_pred[s3_eval_a_q.ftb_ent.s[k].offset] = s3_eval_a_q.tage_tp[k].alt;
          a_pcpn[s3_eval_a_q.ftb_ent.s[k].offset]     = (s3_eval_a_q.tage_tp[k].pcpn < 4'(EX_TN))
              ? ((s3_eval_a_q.tage_tp[k].pcpn >= 4'(TN)) ? PCPN_W'(TN - 1) : PCPN_W'(s3_eval_a_q.tage_tp[k].pcpn))
              : PCPN_W'(TN);
        end
      end
    end
    if (s3_eval_b_q.ftb_hit) begin
      for (int k = 0; k < FTB_SLOTS; k++) begin
        if (s3_eval_b_q.ftb_ent.s[k].valid && ({1'b0, s3_eval_b_q.ftb_ent.s[k].offset} < s3_bns)) begin
          b_pred_dir[s3_eval_b_q.ftb_ent.s[k].offset] = s3_b_eval.slot_tk[k];
          b_alt_pred[s3_eval_b_q.ftb_ent.s[k].offset] = s3_eval_b_q.tage_tp[k].alt;
          b_pcpn[s3_eval_b_q.ftb_ent.s[k].offset]     = (s3_eval_b_q.tage_tp[k].pcpn < 4'(EX_TN))
              ? ((s3_eval_b_q.tage_tp[k].pcpn >= 4'(TN)) ? PCPN_W'(TN - 1) : PCPN_W'(s3_eval_b_q.tage_tp[k].pcpn))
              : PCPN_W'(TN);
        end
      end
    end
    out_blk_id = blk_seq_q;
    for (int i = 0; i < NLANE; i++) begin
      logic [3:0] j;
      j = 4'(i) - r2_q.a_len;
      if (d_pair && (4'(i) >= r2_q.a_len)) begin
        out_pred_dir[i] = b_pred_dir[j];
        out_alt_pred[i] = b_alt_pred[j];
        out_pcpn[i]     = b_pcpn[j];
      end else begin
        out_pred_dir[i] = a_pred_dir[i];
        out_alt_pred[i] = a_alt_pred[i];
        out_pcpn[i]     = a_pcpn[i];
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = ^{ftb0_b_hit, ftb0_b_ent, ah_eval.slot_tk, u0_eval.slot_tk, ah2_eval.slot_tk,
                       s3_wa, s3_wb};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
