// Ref: front-end/BPU/BPU_pipe.h & BpuFtb.h  (block-based 2-taken 1-Ahead A + 2-Ahead B FTB BPU, EXP-051)
`default_nettype none

module bpu import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                refetch,
  input  logic [XLEN_BITS-1:0] refetch_address,
  input  logic                refetch_pd,
  input  logic                icache_read_ready,
  input  logic [7:0]          ptab_size,
  // repair information of a back-end branch mispredict (looks up internal rec_q[256] by rf_blk)
  input  logic                rf_valid,
  input  logic [FTB_BLK_ID_W-1:0] rf_blk,
  input  logic [2:0]          rf_type,
  input  logic [XLEN_BITS-1:0] rf_pc,
  input  logic                rf_is_rvc,
  // result of the predecode check of the previous cycle
  input  logic                pd_valid,
  input  logic                pd_flush,
  input  logic [1:0]          pd_hn,
  input  logic [5:0]          pd_hbits,
  input  logic [1:0]          pd_ras_op,
  input  logic [XLEN_BITS-1:0] pd_ras_val,
  input  logic [1:0]          pd_ras_op2,
  input  logic [XLEN_BITS-1:0] pd_ras_val2,
  input  logic                pd_nb_valid,
  input  logic [XLEN_BITS-1:0] pd_nb_pc,
  input  logic [XLEN_BITS-1:0] pd_nb_base,
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
  input  logic [FTB_BLK_ID_W-1:0] blk_id [NCOMMIT],
  // S0: block address + optional paired Block B to fetch-address queue
  output logic                icache_read_valid,
  output logic [XLEN_BITS-1:0] fetch_address,
  output logic                pair_valid,
  output logic [XLEN_BITS-1:0] pair_addr2,
  output logic [3:0]          pair_a_len,
  output logic [3:0]          pair_b_len,
  // S2: override of the younger block
  output logic                override_valid,
  output logic                override_squash,
  // S2: prediction written into the PTAB
  output logic                ptab_write_enable,
  output logic [XLEN_BITS-1:0] ptab_base_pc,
  output logic                ptab_is_pair,
  output logic [XLEN_BITS-1:0] ptab_base_b,
  output logic [3:0]          ptab_a_len,
  output logic [XLEN_BITS-1:0] predict_next_fetch_address,
  output logic [NLANE-1:0]    out_pred_dir,
  output logic [NLANE-1:0]    out_alt_pred,
  output logic [PCPN_W-1:0]   out_pcpn      [NLANE],
  output logic [FTB_BLK_ID_W-1:0] out_blk_id,
  output logic [3:0]          commit_upd_free,
  output logic [3:0]          commit_tq_free
);

  // ---- Pipeline registers ----
  logic [XLEN_BITS-1:0]    pc_q, pc_d;
  blk_t                    r0_q, r0_d, r1_q, r1_d;
  ftb_ix_t                 r0_ix_q, r1_ix_q, r0_ix_b_q, r1_ix_b_q;
  ftb_s1_raw_t             r1_raw_q, r1_raw_b_q;
  ftb_ah_pipe_t            ah_pipe_q  [2];
  ftb_ah_pipe_t            ah_pipe_d  [2];
  ftb_ah_raw_t             ah2_pipe_q [2];
  ftb_ah_raw_t             ah2_pipe_d [2];
  logic [EPOCH_W-1:0]      epoch_q, epoch_d;
  logic [FTB_BLK_ID_W-1:0] blk_seq_q, blk_seq_d;

  // ---- S0 state selection ----
  ck_t                 spec_ck, spec1_ck, s0_ck, spec_a_ck;
  logic                spec_ras_nonempty, spec1_ras_nonempty, s0_ras_nonempty, spec_a_ras_nonempty;
  logic [XLEN_BITS-1:0] spec_ras_top, spec1_ras_top, s0_ras_top, spec_a_ras_top;
  fh_t                 spec_fh, spec1_fh, s0_fh, spec_a_fh;
  logic [XLEN_BITS-1:0] s0_base, s0_bnd, pc1;
  ftb_ix_t             s0_ix, s0_b_ix, ah_rd_ix;
  logic [XLEN_BITS-1:0] ah_rd_base;
  fh_t                 ah_rd_fh;

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
    s0_bnd = block_bnd(s0_base);
    s0_ix  = ftb_make_index(s0_base, s0_fh);
  end

  // ---- Control flags ----
  logic d_valid, ovr_a, d_pair, ovr_b, ovr, squash, l1_ov, issue, fast, s0_go, pd_restore, rep_ok;
  logic pdq_have, rep_ok_in;
  ck_t  pd_ck;
  logic [XLEN_BITS-1:0] pd_base;

  // ---- Internal rec_q[256] for back-end branch mispredict repair (matches BpuPipe::rec_[256]) ----
  logic [FTB_RF_REC_W-1:0] rf_rd_a [1];
  bpu_rf_rec_t             rf_rd_d [1];
  logic                    rf_we   [2];
  logic [FTB_RF_REC_W-1:0] rf_wa   [2];
  bpu_rf_rec_t             rf_wd   [2];
  logic [FTB_BLK_ID_W-1:0] seq1;
  bpu_rf_rec_t             rf_rc;
  logic                    rf_carried;
  logic [XLEN_BITS-1:0]    rf_rslot;

  assign seq1 = blk_seq_q + FTB_BLK_ID_W'(1);

  always_comb begin
    rf_rd_a[0] = rf_blk[FTB_RF_REC_W-1:0];
    rf_we[0]   = d_valid;
    rf_wa[0]   = blk_seq_q[FTB_RF_REC_W-1:0];
    rf_wd[0]   = '{valid: 1'b1, id: blk_seq_q, epoch: epoch_q, base: r1_q.base, ck: r1_q.ck};
    rf_we[1]   = d_pair;
    rf_wa[1]   = seq1[FTB_RF_REC_W-1:0];
    rf_wd[1]   = '{valid: 1'b1, id: seq1, epoch: epoch_q, base: r1_q.base_b, ck: r1_q.ck_b};

    rf_rc      = rf_rd_d[0];
    rf_carried = rf_rc.valid && ((rf_pc + XLEN_BITS'(SLOT_BYTES)) == rf_rc.base);
    rf_rslot   = rf_carried ? '0 : ((rf_pc - rf_rc.base) >> SLOT_SHIFT);
    rep_ok_in  = rf_valid && rf_rc.valid && (rf_rc.id == rf_blk) && (rf_rc.epoch == epoch_q) &&
                 (rf_rslot < XLEN_BITS'(FETCH_WIDTH)) &&
                 (rf_carried || ((rf_rc.base + (rf_rslot << SLOT_SHIFT)) == rf_pc));
  end

  bpu_mem #(.W($bits(bpu_rf_rec_t)), .DEPTH(FTB_RF_REC_N), .N_RD(1), .N_WR(2), .T(bpu_rf_rec_t)) u_rf_rec (
    .clk, .rst_n, .rd_addr(rf_rd_a), .rd_data(rf_rd_d), .wr_en(rf_we), .wr_addr(rf_wa), .wr_data(rf_wd)
  );

  // ---- Commit branch queue + ftb_rec (1R2W, BRQ_W=1) ----
  logic                    upd_en, upd_ah_v, upd_ah_kind;
  logic [XLEN_BITS-1:0]    upd_start, upd_ah_key_base, upd_ah_a_base, upd_pc;
  fh_t                     upd_fh, upd_ah_key_fh;
  ftb_br_upd_t             upd_br;
  ftb_ix_t                 upd_ix, upd_ah_ix;
  ftb_rec_t                rec_wr_data, rec_wr_b_data;

  always_comb begin
    upd_ix    = ftb_make_index(upd_start, upd_fh);
    upd_ah_ix = ftb_make_ah_index(upd_ah_key_base, upd_ah_kind ? upd_ah_a_base : upd_start, upd_ah_key_fh);
    rec_wr_data = '{
      valid: 1'b1, id: blk_seq_q, base: r1_q.base, fh: r1_q.ck.h.fh,
      ah_v: r1_q.ah_v, ah_kind: 1'b0, ah_key_base: r1_q.ah_key_base, ah_a_base: '0, ah_key_fh: r1_q.ah_key_fh
    };
    rec_wr_b_data = '{
      valid: 1'b1, id: seq1, base: r1_q.base_b, fh: r1_q.ck_b.h.fh,
      ah_v: r1_q.ah_v_b, ah_kind: 1'b1, ah_key_base: r1_q.ah_key_base_b, ah_a_base: r1_q.base, ah_key_fh: r1_q.ah_key_fh_b
    };
  end

  bpu_ftb_brq u_brq (
    .clk, .rst_n,
    .rec_wr_en(d_valid), .rec_wr_addr(blk_seq_q[FTB_REC_W-1:0]), .rec_wr_data,
    .rec_wr_b_en(d_pair), .rec_wr_b_addr(seq1[FTB_REC_W-1:0]), .rec_wr_b_data,
    .upd_valid, .base_pc, .actual_dir, .upd_is_rvc, .br_type, .target, .pred_dir, .alt_pred, .pcpn,
    .blk_id,
    .upd_en, .upd_start, .upd_fh, .upd_ah_v, .upd_ah_kind, .upd_ah_key_base, .upd_ah_a_base, .upd_ah_key_fh, .upd_br, .upd_pc,
    .commit_upd_free, .commit_tq_free
  );

  // ---- Predictor arrays ----
  logic        ftb0_hit, ftb0_b_hit, s2_prefer_alt, ah_prefer_alt, ah2_prefer_alt;
  ftb_ent_t    ftb0_ent, ftb0_b_ent;
  ftb_ah_raw_t ah_rd_raw, ah2_rd_raw;
  ftb_s1_raw_t s1_raw, s1_b_raw;
  logic [XLEN_BITS-1:0] s0_b_base, clr_base_eff;

  assign clr_base_eff = (pd_nb_base != '0) ? pd_nb_base : pd_base;

  bpu_ftb_arrays u_arrays (
    .clk, .rst_n,
    .s0_base, .s0_b_base, .ah_rd_base, .ah_rd_ix,
    .ftb0_hit, .ftb0_ent, .ftb0_b_hit, .ftb0_b_ent,
    .ah_rd_raw, .ah2_rd_raw, .ah_prefer_alt, .ah2_prefer_alt,
    .s1_base(r0_q.base), .s1_ix(r0_ix_q), .s1_b_base(r0_q.base_b), .s1_b_ix(r0_ix_b_q),
    .s1_raw, .s1_b_raw, .s2_prefer_alt,
    .upd_en, .upd_start, .upd_ix, .upd_ah_v, .upd_ah_kind, .upd_ah_key_base, .upd_ah_a_base, .upd_ah_ix, .upd_br,
    .clr_en(pd_valid && pd_nb_valid && pdq_have), .clr_base(clr_base_eff), .clr_pc(pd_nb_pc)
  );

  // ---- S0 / S1 / S2 evaluation & merged PTAB metadata ----
  logic                 ah_src_v, ah_hit, s0_paired;
  logic [XLEN_BITS-1:0] s0_b_bnd;
  logic [3:0]           s0_a_len, s0_b_len;
  pred_t                g0, g0_b, g1, fin, fin_b;

  bpu_eval u_eval (
    .refetch,
    .s0_base, .s0_bnd, .s0_fh, .s0_ras_nonempty, .s0_ras_top,
    .spec_a_fh, .spec_a_ras_nonempty, .spec_a_ras_top,
    .ah_pipe0(ah_pipe_q[0]), .ah2_pipe0(ah2_pipe_q[0]),
    .ftb0_hit, .ftb0_ent, .ftb0_b_hit, .ftb0_b_ent,
    .ah_prefer_alt, .ah2_prefer_alt,
    .r0_q, .r1_q, .r1_ix_q, .r1_ix_b_q, .s1_raw, .r1_raw_q, .r1_raw_b_q, .s2_prefer_alt,
    .d_pair, .blk_seq_q,
    .ah_src_v, .ah_hit, .g0, .s0_b_base, .s0_b_bnd, .s0_a_len, .s0_b_len, .g0_b, .s0_paired,
    .s0_b_ix, .ah_rd_base, .ah_rd_fh, .ah_rd_ix,
    .g1, .fin, .fin_b,
    .out_pred_dir, .out_alt_pred, .out_pcpn, .out_blk_id
  );

  // ---- Control, speculative history/RAS, PDCKPT ----
  logic [1:0]  h_mode, h_push_n, r_mode, r_op, r_op2, r2_op, r3_op;
  logic [1:0]  hr_mode, hr_push_n, rr_mode, rr_op, rr_op2;
  hist_ck_t    h_ck, hr_ck;
  logic        h2_en, h3_en;
  logic [5:0]  h_push_bits, hr_push_bits;
  logic [HSYM_W-1:0] h2_bits, h3_bits;
  ras_ck_t     r_ck, rr_ck;
  logic [XLEN_BITS-1:0] r_val, r_val2, r2_val, r3_val, rr_val, rr_val2;

  bpu_ctl u_ctl (
    .refetch, .refetch_pd, .rep_ok_in,
    .pd_valid, .pd_flush, .pdq_have, .icache_read_ready, .ptab_size,
    .r0(r0_q), .r1(r1_q), .fin, .fin_b, .g1,
    .d_valid, .ovr_a, .d_pair, .ovr_b, .ovr, .squash, .l1_ov, .issue, .fast, .s0_go, .pd_restore, .rep_ok
  );

  bpu_cmd u_cmd (
    .refetch, .pd_restore, .rep_ok, .ovr, .ovr_a, .d_pair, .l1_ov, .issue, .s0_go, .s0_paired,
    .pc(pc_q), .refetch_address, .g0, .g0_b, .g1, .fin, .fin_b, .r0(r0_q), .r1(r1_q),
    .pd_ck, .pd_hn, .pd_hbits, .pd_ras_op, .pd_ras_val, .pd_ras_op2, .pd_ras_val2,
    .rf_ck_rec(rf_rc.ck), .rf_type, .rf_pc, .rf_is_rvc,
    .h_mode, .h_ck, .h_push_n, .h_push_bits, .r_mode, .r_ck, .r_op, .r_val, .r_op2, .r_val2, .pc1,
    .h2_en, .h2_bits, .r2_op, .r2_val, .h3_en, .h3_bits, .r3_op, .r3_val, .pc_d,
    .hr_mode, .hr_ck, .hr_push_n, .hr_push_bits, .rr_mode, .rr_ck, .rr_op, .rr_val, .rr_op2, .rr_val2
  );

  bpu_spec u_spec (
    .clk, .rst_n, .upd_valid, .base_pc, .br_type, .actual_dir, .upd_is_rvc, .target,
    .h_mode, .h_ck, .h_push_n, .h_push_bits, .r_mode, .r_ck, .r_op, .r_val, .r_op2, .r_val2,
    .h2_en, .h2_bits, .r2_op, .r2_val, .h3_en, .h3_bits, .r3_op, .r3_val,
    .spec_ck, .spec_ras_nonempty, .spec_ras_top, .spec_fh,
    .spec1_ck, .spec1_ras_nonempty, .spec1_ras_top, .spec1_fh,
    .spec_a_ck, .spec_a_ras_nonempty, .spec_a_ras_top, .spec_a_fh,
    .refetch, .issue, .g0_h_en(g0.taken), .g0_h_bits(g0.hbits), .g0_r_op(g0.ras_op), .g0_r_val(g0.ras_val),
    .hr_mode, .hr_ck, .hr_push_n, .hr_push_bits, .rr_mode, .rr_ck, .rr_op, .rr_val, .rr_op2, .rr_val2
  );

  bpu_pdq u_pdq (
    .clk, .rst_n, .pop(pd_valid), .push(d_valid), .push_ck(r1_q.ck), .push_base(r1_q.base),
    .clear(refetch), .head_valid(pdq_have), .head_ck(pd_ck), .head_base(pd_base)
  );

  // ---- Next stage registers & 1-ahead / 2-ahead pipelines ----
  logic [XLEN_BITS-1:0] d_obase;

  always_comb begin
    r0_d               = '0;
    r0_d.valid         = s0_go;
    r0_d.ah_v          = ah_src_v;
    r0_d.ah_hit        = ah_hit;
    r0_d.ah_key_base   = ah_pipe_q[0].key_base;
    r0_d.ah_key_fh     = ah_pipe_q[0].key_fh;
    r0_d.base          = s0_base;
    r0_d.g             = g0;
    r0_d.ck            = s0_ck;
    r0_d.has_b         = s0_paired;
    r0_d.base_b        = s0_b_base;
    r0_d.bnd_b         = s0_b_bnd;
    r0_d.a_len         = s0_a_len;
    r0_d.b_len         = s0_b_len;
    r0_d.g_b           = g0_b;
    r0_d.ck_b          = spec_a_ck;
    r0_d.ah_v_b        = ah_src_v;
    r0_d.ah_key_base_b = ah_pipe_q[0].key_base;
    r0_d.ah_key_fh_b   = ah_pipe_q[0].key_fh;

    r1_d       = r0_q;
    r1_d.valid = r0_q.valid && !refetch && !ovr;
    if (l1_ov) begin
      r1_d.g     = g1;
      r1_d.has_b = 1'b0;
    end

    epoch_d   = epoch_q + EPOCH_W'(refetch && !pd_restore && !rep_ok);
    blk_seq_d = blk_seq_q + (d_pair ? FTB_BLK_ID_W'(2) : FTB_BLK_ID_W'(d_valid));
    d_obase   = (ovr_a || !d_pair) ? r1_q.base : r1_q.base_b;
  end

  always_comb begin
    ah_pipe_d[0]  = ah_pipe_q[0];
    ah_pipe_d[1]  = ah_pipe_q[1];
    ah2_pipe_d[0] = ah2_pipe_q[0];
    ah2_pipe_d[1] = ah2_pipe_q[1];
    if (refetch) begin
      ah_pipe_d[0].valid = 1'b0;
      ah_pipe_d[1].valid = 1'b0;
      if (s0_go) begin
        ah_pipe_d[0].valid    = 1'b1;
        ah_pipe_d[0].key_base = ah_rd_base;
        ah_pipe_d[0].key_fh   = ah_rd_fh;
        ah_pipe_d[0].raw      = ah_rd_raw;
        ah2_pipe_d[0]         = ah2_rd_raw;
      end
    end else if (ovr) begin
      if (ah_pipe_q[1].valid && (ah_pipe_q[1].key_base == d_obase)) begin
        ah_pipe_d[0]       = ah_pipe_q[1];
        ah2_pipe_d[0]      = ah2_pipe_q[1];
        ah_pipe_d[1].valid = 1'b0;
      end else if (!(ah_pipe_q[0].valid && (ah_pipe_q[0].key_base == d_obase))) begin
        ah_pipe_d[0].valid = 1'b0;
        ah_pipe_d[1].valid = 1'b0;
      end
    end else if (s0_go) begin
      ah_pipe_d[1]          = ah_pipe_q[0];
      ah2_pipe_d[1]         = ah2_pipe_q[0];
      ah_pipe_d[0].valid    = 1'b1;
      ah_pipe_d[0].key_base = ah_rd_base;
      ah_pipe_d[0].key_fh   = ah_rd_fh;
      ah_pipe_d[0].raw      = ah_rd_raw;
      ah2_pipe_d[0]         = ah2_rd_raw;
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
      pc_q          <= pc_d;
      r0_q          <= r0_d;
      r1_q          <= r1_d;
      epoch_q       <= epoch_d;
      blk_seq_q     <= blk_seq_d;
      ah_pipe_q[0]  <= ah_pipe_d[0];
      ah_pipe_q[1]  <= ah_pipe_d[1];
      ah2_pipe_q[0] <= ah2_pipe_d[0];
      ah2_pipe_q[1] <= ah2_pipe_d[1];
    end
  end

  always_ff @(posedge clk) begin
    r0_ix_q    <= s0_ix;
    r1_ix_q    <= r0_ix_q;
    r0_ix_b_q  <= s0_b_ix;
    r1_ix_b_q  <= r0_ix_b_q;
    r1_raw_q   <= s1_raw;
    r1_raw_b_q <= s1_b_raw;
  end

  assign icache_read_valid          = s0_go;
  assign fetch_address              = s0_base;
  assign pair_valid                 = s0_go && s0_paired;
  assign pair_addr2                 = s0_b_base;
  assign pair_a_len                 = s0_a_len;
  assign pair_b_len                 = s0_b_len;
  assign override_valid             = ovr;
  assign override_squash            = squash;
  assign ptab_write_enable          = d_valid;
  assign ptab_base_pc               = r1_q.base;
  assign ptab_is_pair               = d_pair;
  assign ptab_base_b                = r1_q.base_b;
  assign ptab_a_len                 = r1_q.a_len;
  assign predict_next_fetch_address = d_pair ? fin_b.next : fin.next;

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = ^{g0.ty, g0_b.slot, g0_b.ty, g0_b.rvc, g0_b.carried, g1.slot, g1.ty, g1.rvc, g1.carried,
                       fin.slot, fin.ty, fin.rvc, fin.carried, fin_b.slot, fin_b.ty, fin_b.rvc, fin_b.carried,
                       fast, ovr_b, spec_ck.h.head, pc1, upd_pc};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
