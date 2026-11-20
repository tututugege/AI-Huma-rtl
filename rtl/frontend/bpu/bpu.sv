// Ref: front-end/BPU/BPU_pipe.h & BpuFtb.h  (block-based 1-ahead FTB BPU, ah1_4k_a2k1k + FTB_BRQ=2)
`default_nettype none

module bpu import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                refetch,
  input  logic [XLEN_BITS-1:0] refetch_address,
  input  logic                refetch_pd,
  input  logic                icache_read_ready,
  input  logic [7:0]          ptab_size,
  // repair information of a back-end branch mispredict
  input  logic                rf_valid,
  input  logic [HCK_W-1:0]    rf_ck,
  input  logic [EPOCH_W-1:0]  rf_epoch,
  input  logic [2:0]          rf_type,
  input  logic [XLEN_BITS-1:0] rf_pc,
  input  logic                rf_is_rvc,
  // result of the predecode check of the previous cycle
  input  logic                pd_valid,
  input  logic                pd_flush,
  input  logic                pd_hv,
  input  logic [HSYM_W-1:0]   pd_hbits,
  input  logic [1:0]          pd_ras_op,
  input  logic [XLEN_BITS-1:0] pd_ras_val,
  input  logic                pd_nb_valid,
  input  logic [XLEN_BITS-1:0] pd_nb_pc,
  // commit stream
  input  logic [NCOMMIT-1:0]  upd_valid,
  input  logic [XLEN_BITS-1:0] base_pc    [NCOMMIT],
  input  logic [NCOMMIT-1:0]  actual_dir,
  input  logic [NCOMMIT-1:0]  upd_is_rvc,
  input  logic [2:0]          br_type    [NCOMMIT],
  input  logic [XLEN_BITS-1:0] target     [NCOMMIT],
  input  logic [NCOMMIT-1:0]  pred_dir,
  input  logic [NCOMMIT-1:0]  alt_pred,
  input  logic [PCPN_W-1:0]   pcpn       [NCOMMIT],
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [T_TAG_W-1:0]  tags       [NCOMMIT][TN],
  input  logic [T_IDX_W-1:0]  idxs       [NCOMMIT][TN],
  /* verilator lint_on UNUSEDSIGNAL */
  // S0: block address to the fetch-address queue
  output logic                icache_read_valid,
  output logic [XLEN_BITS-1:0] fetch_address,
  // S2: override of the younger block
  output logic                override_valid,
  output logic                override_squash,
  // S2: prediction written into the PTAB
  output logic                ptab_write_enable,
  output logic [XLEN_BITS-1:0] ptab_base_pc,
  output logic [XLEN_BITS-1:0] predict_next_fetch_address,
  output logic [NLANE-1:0]    out_pred_dir,
  output logic [NLANE-1:0]    out_alt_pred,
  output logic [PCPN_W-1:0]   out_pcpn      [NLANE],
  output logic [T_TAG_W-1:0]  out_tage_tags [NLANE][TN],
  output logic [T_IDX_W-1:0]  out_tage_idxs [NLANE][TN],
  output logic [HCK_W-1:0]    out_ck,
  output logic [EPOCH_W-1:0]  out_epoch,
  output logic [3:0]          commit_upd_free,
  output logic [3:0]          commit_tq_free
);

  // ---- Pipeline registers ----
  logic [XLEN_BITS-1:0]    pc_q, pc_d;
  blk_t                    r0_q, r0_d, r1_q, r1_d;
  ftb_ix_t                 r0_ix_q, r1_ix_q;
  ftb_s1_raw_t             r1_raw_q;
  ftb_ah_pipe_t            ah_pipe_q [2];
  ftb_ah_pipe_t            ah_pipe_d [2];
  logic [EPOCH_W-1:0]      epoch_q, epoch_d;
  logic [FTB_BLK_ID_W-1:0] blk_seq_q, blk_seq_d;

  // ---- S0 state selection ----
  ck_t                 spec_ck, spec1_ck, s0_ck;
  logic                spec_ras_nonempty, spec1_ras_nonempty, s0_ras_nonempty;
  logic [XLEN_BITS-1:0] spec_ras_top, spec1_ras_top, s0_ras_top;
  fh_t                 spec_fh, spec1_fh, s0_fh;
  logic [XLEN_BITS-1:0] s0_base, s0_bnd, pc1;
  ftb_ix_t             s0_ix, ah_rd_ix;

  localparam bit FAST    = (FE_RFAST & 1) != 0 || FE_BFAST != 0;
  localparam bit REFONLY = FAST && (FE_BFAST & 3) == 0;

  always_comb begin
    s0_base         = FAST ? pc1 : pc_q;
    s0_ck           = FAST ? spec1_ck : spec_ck;
    s0_ras_nonempty = FAST ? spec1_ras_nonempty : spec_ras_nonempty;
    s0_ras_top      = FAST ? spec1_ras_top : spec_ras_top;
    s0_fh           = FAST ? spec1_fh : spec_fh;
    if (REFONLY && !refetch) begin
      s0_ck           = spec_ck;
      s0_ras_nonempty = spec_ras_nonempty;
      s0_ras_top      = spec_ras_top;
      s0_fh           = spec_fh;
    end
    s0_bnd   = block_bnd(s0_base);
    s0_ix    = ftb_make_index(s0_base, s0_fh);
    ah_rd_ix = ftb_make_ah_index(s0_base, '0, s0_fh);
  end

  // ---- Commit branch queue + ftb_rec ----
  logic [FTB_BLK_ID_W-1:0] cmt_blk_id [NCOMMIT];
  logic                    upd_en, upd_ah_v;
  logic [XLEN_BITS-1:0]    upd_start, upd_ah_key_base, upd_pc;
  fh_t                     upd_fh, upd_ah_key_fh;
  ftb_br_upd_t             upd_br;
  ftb_ix_t                 upd_ix, upd_ah_ix;
  ftb_rec_t                rec_wr_data;

  always_comb begin
    for (int i = 0; i < NCOMMIT; i++) cmt_blk_id[i] = idxs[i][0];
    upd_ix                  = ftb_make_index(upd_start, upd_fh);
    upd_ah_ix               = ftb_make_ah_index(upd_ah_key_base, upd_start, upd_ah_key_fh);
    rec_wr_data.valid       = 1'b1;
    rec_wr_data.id          = blk_seq_q;
    rec_wr_data.base        = r1_q.base;
    rec_wr_data.fh          = r1_q.ck.h.fh;
    rec_wr_data.ah_v        = r1_q.ah_v;
    rec_wr_data.ah_key_base = r1_q.ah_key_base;
    rec_wr_data.ah_key_fh   = r1_q.ah_key_fh;
  end

  logic d_valid, ovr, squash, l1_ov, issue, fast, s0_go, pd_restore, rep_ok;
  logic pdq_have;
  ck_t  pd_ck;
  logic [XLEN_BITS-1:0] pd_base;

  bpu_ftb_brq u_brq (
    .clk, .rst_n,
    .rec_wr_en(d_valid), .rec_wr_addr(blk_seq_q[FTB_REC_W-1:0]), .rec_wr_data,
    .upd_valid, .base_pc, .actual_dir, .upd_is_rvc, .br_type, .target, .pred_dir, .alt_pred, .pcpn,
    .blk_id(cmt_blk_id),
    .upd_en, .upd_start, .upd_fh, .upd_ah_v, .upd_ah_key_base, .upd_ah_key_fh, .upd_br, .upd_pc,
    .commit_upd_free, .commit_tq_free
  );

  // ---- Predictor arrays ----
  logic        ftb0_hit, s2_prefer_alt, ah_prefer_alt;
  ftb_ent_t    ftb0_ent;
  ftb_ah_raw_t ah_rd_raw;
  ftb_s1_raw_t s1_raw;

  bpu_ftb_arrays u_arrays (
    .clk, .rst_n,
    .s0_base, .ah_rd_ix, .ftb0_hit, .ftb0_ent, .ah_rd_raw, .ah_prefer_alt,
    .s1_base(r0_q.base), .s1_ix(r0_ix_q), .s1_raw, .s2_prefer_alt,
    .upd_en, .upd_start, .upd_ix, .upd_ah_v, .upd_ah_key_base, .upd_ah_ix, .upd_br,
    .clr_en(pd_valid && pd_nb_valid && pdq_have), .clr_base(pd_base), .clr_pc(pd_nb_pc)
  );

  // ---- S0 1-ahead select + uFTB fallback ----
  logic                    ah_src_v, ah_hit;
  logic [FTB_AH_TAG_W-1:0] ah_sel_tag;
  ftb_ent_t                ah_ent;
  ftb_ix_t                 ah_sel_ix;
  logic [FTB_SLOTS-1:0]    ah_dirs;
  ftb_tage_pred_t          ah_tp [FTB_SLOTS];
  ftb_itt_sel_t            ah_itt;
  ftb_eval_res_t           ah_eval, u0_eval;
  pred_t                   g0;

  always_comb begin
    ah_src_v   = !refetch && ah_pipe_q[0].valid;
    ah_sel_tag = ftb_ah_tag(ah_pipe_q[0].key_base, s0_base);
    ah_hit     = 1'b0;
    ah_ent     = '0;
    if (ah_src_v) begin
      for (int w = 0; w < FTB_AH_WAYS; w++) begin
        if (!ah_hit && ah_pipe_q[0].raw.ftb_ways[w].valid &&
            (ah_pipe_q[0].raw.ftb_ways[w].tag == FTB_MAX_TAG_W'(ah_sel_tag))) begin
          ah_hit = 1'b1;
          ah_ent = ah_pipe_q[0].raw.ftb_ways[w];
        end
      end
    end
    ah_sel_ix = ftb_make_ah_index(ah_pipe_q[0].key_base, s0_base, ah_pipe_q[0].key_fh);
    for (int k = 0; k < FTB_SLOTS; k++) begin
      ah_tp[k]   = ftb_tage_select(ah_sel_ix, ah_pipe_q[0].raw.tage_raw[k],
                                   ah_ent.s[k].valid, ah_ent.s[k].ctr, ah_prefer_alt);
      ah_dirs[k] = ah_tp[k].pred;
    end
    ah_itt  = ftb_itt_select(ah_sel_ix, ah_pipe_q[0].raw.itt_raw);
    ah_eval = ftb_eval_ent(s0_base, s0_bnd, ah_ent, ah_hit, 1'b1, ah_dirs, ah_itt.hit, ah_itt.target,
                           s0_ras_nonempty, s0_ras_top);
    u0_eval = ftb_eval_ent(s0_base, s0_bnd, ftb0_ent, ftb0_hit, 1'b0, '0, 1'b0, '0,
                           s0_ras_nonempty, s0_ras_top);
    g0      = ah_hit ? ah_eval.pred : u0_eval.pred;
  end

  // ---- S1 fallback guess (FTB_S1_DIR=0: bimodal ctr in Main FTB) ----
  ftb_eval_res_t s1_eval;
  pred_t         g1;

  always_comb begin
    s1_eval = ftb_eval_ent(r0_q.base, block_bnd(r0_q.base), s1_raw.ent, s1_raw.ftb_hit, 1'b0, '0, 1'b0, '0,
                           r0_q.ck.r.cnt != '0, r0_q.ck.r.top);
    g1      = s1_eval.pred;
  end

  // ---- S2 final select & PTAB metadata ----
  logic [XLEN_BITS-1:0] s2_bnd;
  logic [FTB_SLOTS-1:0] s2_dirs;
  ftb_tage_pred_t       s2_tp [FTB_SLOTS];
  ftb_itt_sel_t         s2_itt;
  ftb_eval_res_t        s2_eval;
  pred_t                fin;

  always_comb begin
    s2_bnd = block_bnd(r1_q.base);
    for (int k = 0; k < FTB_SLOTS; k++) begin
      s2_tp[k]   = ftb_tage_select(r1_ix_q, r1_raw_q.s2_tage_raw[k], 1'b0, 2'd0, s2_prefer_alt);
      s2_dirs[k] = s2_tp[k].pred;
    end
    s2_itt  = ftb_itt_select(r1_ix_q, r1_raw_q.itt_raw);
    s2_eval = ftb_eval_ent(r1_q.base, s2_bnd, r1_raw_q.ent, r1_raw_q.ftb_hit, 1'b1, s2_dirs,
                           s2_itt.hit, s2_itt.target, r1_q.ck.r.cnt != '0, r1_q.ck.r.top);
    fin     = s2_eval.pred;

    out_pred_dir = '0;
    out_alt_pred = '0;
    for (int i = 0; i < NLANE; i++) begin
      out_pcpn[i]         = PCPN_W'(TN);
      out_tage_idxs[i][0] = blk_seq_q;
      for (int t = 1; t < TN; t++) out_tage_idxs[i][t] = r1_ix_q.idx[t][T_IDX_W-1:0];
      for (int t = 0; t < TN; t++) out_tage_tags[i][t] = r1_ix_q.tag[t][T_TAG_W-1:0];
    end
    if (r1_raw_q.ftb_hit) begin
      for (int k = 0; k < FTB_SLOTS; k++) begin
        if (r1_raw_q.ent.s[k].valid &&
            ((r1_q.base + (XLEN_BITS'(r1_raw_q.ent.s[k].offset) << SLOT_SHIFT)) < s2_bnd)) begin
          out_pred_dir[r1_raw_q.ent.s[k].offset] = s2_eval.slot_tk[k];
          out_alt_pred[r1_raw_q.ent.s[k].offset] = s2_tp[k].alt;
          out_pcpn[r1_raw_q.ent.s[k].offset]     = s2_tp[k].pcpn;
        end
      end
    end
  end

  // ---- Control, speculative history/RAS, PDCKPT ----
  logic [1:0]  h_mode, r_mode, r_op, r2_op, hr_mode, rr_mode, rr_op;
  hist_ck_t    h_ck, hr_ck;
  logic        h_push_en, h2_en, hr_push_en;
  logic [HSYM_W-1:0] h_push_bits, h2_bits, hr_push_bits;
  ras_ck_t     r_ck, rr_ck;
  logic [XLEN_BITS-1:0] r_val, r2_val, rr_val;

  bpu_ctl u_ctl (
    .refetch, .refetch_pd, .rf_valid, .rf_epoch_ok(rf_epoch == epoch_q),
    .pd_valid, .pd_flush, .pdq_have, .icache_read_ready, .ptab_size,
    .r0(r0_q), .r1(r1_q), .fin, .g1,
    .d_valid, .ovr, .squash, .l1_ov, .issue, .fast, .s0_go, .pd_restore, .rep_ok
  );

  bpu_cmd u_cmd (
    .refetch, .pd_restore, .rep_ok, .ovr, .l1_ov, .issue, .s0_go, .pc(pc_q), .refetch_address, .g0, .g1, .fin,
    .r0(r0_q), .r1(r1_q), .pd_ck, .pd_hv, .pd_hbits, .pd_ras_op, .pd_ras_val,
    .rf_ck(hist_ck_t'(rf_ck[HHCK_W-1:0])),
    .rf_rck(ras_ck_t'({rf_ck[HCK_W-1:HHCK_W], {XLEN_BITS{1'b0}}})),
    .rf_type, .rf_pc, .rf_is_rvc,
    .h_mode, .h_ck, .h_push_en, .h_push_bits, .r_mode, .r_ck, .r_op, .r_val, .pc1,
    .h2_en, .h2_bits, .r2_op, .r2_val, .pc_d,
    .hr_mode, .hr_ck, .hr_push_en, .hr_push_bits, .rr_mode, .rr_ck, .rr_op, .rr_val
  );

  bpu_spec u_spec (
    .clk, .rst_n, .upd_valid, .base_pc, .br_type, .actual_dir, .upd_is_rvc, .target,
    .h_mode, .h_ck, .h_push_en, .h_push_bits, .r_mode, .r_ck, .r_op, .r_val,
    .h2_en, .h2_bits, .r2_op, .r2_val,
    .spec_ck, .spec_ras_nonempty, .spec_ras_top, .spec_fh,
    .spec1_ck, .spec1_ras_nonempty, .spec1_ras_top, .spec1_fh,
    .refetch, .hr_mode, .hr_ck, .hr_push_en, .hr_push_bits, .rr_mode, .rr_ck, .rr_op, .rr_val
  );

  bpu_pdq u_pdq (
    .clk, .rst_n, .pop(pd_valid), .push(d_valid), .push_ck(r1_q.ck), .push_base(r1_q.base),
    .clear(refetch), .head_valid(pdq_have), .head_ck(pd_ck), .head_base(pd_base)
  );

  // ---- Next stage registers & 1-ahead pipeline ----
  always_comb begin
    r0_d             = '0;
    r0_d.valid       = s0_go;
    r0_d.ah_v        = ah_src_v;
    r0_d.ah_hit      = ah_hit;
    r0_d.ah_key_base = ah_pipe_q[0].key_base;
    r0_d.ah_key_fh   = ah_pipe_q[0].key_fh;
    r0_d.base        = s0_base;
    r0_d.g           = g0;
    r0_d.ck          = s0_ck;

    r1_d       = r0_q;
    r1_d.valid = r0_q.valid && !refetch && !ovr;
    if (l1_ov) r1_d.g = g1;

    epoch_d   = epoch_q + EPOCH_W'(refetch && !pd_restore && !rep_ok);
    blk_seq_d = blk_seq_q + FTB_BLK_ID_W'(d_valid);

    ah_pipe_d[0] = ah_pipe_q[0];
    ah_pipe_d[1] = ah_pipe_q[1];
    if (refetch) begin
      ah_pipe_d[0].valid = 1'b0;
      ah_pipe_d[1].valid = 1'b0;
      if (s0_go) begin
        ah_pipe_d[0].valid    = 1'b1;
        ah_pipe_d[0].key_base = s0_base;
        ah_pipe_d[0].key_fh   = s0_fh;
        ah_pipe_d[0].raw      = ah_rd_raw;
      end
    end else if (ovr) begin
      if (ah_pipe_q[1].valid && (ah_pipe_q[1].key_base == r1_q.base)) begin
        ah_pipe_d[0]       = ah_pipe_q[1];
        ah_pipe_d[1].valid = 1'b0;
      end else if (!(ah_pipe_q[0].valid && (ah_pipe_q[0].key_base == r1_q.base))) begin
        ah_pipe_d[0].valid = 1'b0;
        ah_pipe_d[1].valid = 1'b0;
      end
    end else if (s0_go) begin
      ah_pipe_d[1]          = ah_pipe_q[0];
      ah_pipe_d[0].valid    = 1'b1;
      ah_pipe_d[0].key_base = s0_base;
      ah_pipe_d[0].key_fh   = s0_fh;
      ah_pipe_d[0].raw      = ah_rd_raw;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pc_q               <= '0;
      r0_q               <= '0;
      r1_q               <= '0;
      epoch_q            <= '0;
      blk_seq_q          <= '0;
      ah_pipe_q[0].valid <= 1'b0;
      ah_pipe_q[1].valid <= 1'b0;
    end else begin
      pc_q         <= pc_d;
      r0_q         <= r0_d;
      r1_q         <= r1_d;
      epoch_q      <= epoch_d;
      blk_seq_q    <= blk_seq_d;
      ah_pipe_q[0] <= ah_pipe_d[0];
      ah_pipe_q[1] <= ah_pipe_d[1];
    end
  end

  always_ff @(posedge clk) begin
    r0_ix_q  <= s0_ix;
    r1_ix_q  <= r0_ix_q;
    r1_raw_q <= s1_raw;
  end

  assign icache_read_valid          = s0_go;
  assign fetch_address              = s0_base;
  assign override_valid             = ovr;
  assign override_squash            = squash;
  assign ptab_write_enable          = d_valid;
  assign ptab_base_pc               = r1_q.base;
  assign predict_next_fetch_address = fin.next;
  assign out_ck                     = {r1_q.ck.r.tosr, r1_q.ck.r.tosw, r1_q.ck.r.cnt, r1_q.ck.h};
  assign out_epoch                  = epoch_q;

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = ^{g0.slot, g0.ty, g0.rvc, g1.slot, g1.ty, g1.rvc, fin.slot, fin.ty, fin.rvc, fast,
                       spec_ck.h.head, pc1, upd_pc, ah_eval.slot_tk, u0_eval.slot_tk, s1_eval.slot_tk,
                       ah_tp[0].alt, ah_tp[0].pcpn, ah_tp[0].used_alt, s2_tp[0].used_alt};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
