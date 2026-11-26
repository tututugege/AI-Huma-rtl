// Ref: front-end/BPU/BPU_pipe.h & BpuFtb.h
// v10 Block-based 2-taken 1-Ahead A + 2-Ahead B FTB BPU (Zero-T0-Read Meta + WRBypass + Deep-Macro 1RW):
//   - All predictor arrays are deep single-port Multi-Bank 1RW SRAMs (ZERO N_RD replication, ZERO T0 read ports)
//   - Zero-FF S3-override ahead recovery: re-reads Ahead 1RW SRAMs directly from (d_obase, o_ck.h.fh) on idle d.ovr cycle!
//     (Deletes all 4 giant ah_bak1/2 FF copies ~45,000 FFs while preserving full ahead hit rate!)
//   - Tiny 64-entry (16x4) FF uFTB cold-start fallback; 38-bit Sv39 VA target compression
//   - S2 -> S3 pipeline split (S1: 1RW SRAM read -> S2: decoupled tag/TAGE/SC-nonbias/ITT -> S3: final eval/override)
`default_nettype none

module bpu import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                refetch,
  input  logic [XLEN_BITS-1:0] refetch_address,
  input  logic                refetch_pd,
  input  logic                icache_read_ready,
  // repair information of a back-end branch mispredict (2-bank sync SRAM rec_q[256] pre-launched from next_rf_blk)
  input  logic                rf_valid,
  input  logic [FTB_BLK_ID_W-1:0] rf_blk,
  input  logic [FTB_BLK_ID_W-1:0] next_rf_blk,
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
  // S0: block address + optional paired Block B to Unified FTQ-64
  output logic                icache_read_valid,
  output logic [XLEN_BITS-1:0] fetch_address,
  output logic                pair_valid,
  output logic [XLEN_BITS-1:0] pair_addr2,
  output logic [3:0]          pair_a_len,
  output logic [3:0]          pair_b_len,
  // S3: override of younger blocks (squash_n in 0..2) & exact FTQ ifu_ptr hold count
  output logic                override_valid,
  output logic [1:0]          override_squash_n,
  output logic [1:0]          hold_n,
  // S3: prediction written into Unified FTQ-64
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

  typedef struct packed {
    logic                 valid;
    logic [XLEN_BITS-1:0] key_base;
    fh_t                  key_fh;
  } ah_key_t;

  // ---- Pipeline registers (S0 -> r0_q [S1] -> r1_q [S2] -> r2_q [S3]) ----
  logic [XLEN_BITS-1:0]    pc_q, pc_d;
  blk_t                    r0_q, r0_d, r1_q, r1_d, r2_q, r2_d;
  ftb_ix_t                 r0_ix_q, r1_ix_q, r0_ix_b_q, r1_ix_b_q;
  ex_tage_ix_t             r0_ex_ix_q, r1_ex_ix_q, r0_ex_ix_b_q, r1_ex_ix_b_q;
  sc_ix_t                  r0_sc_ix_q, r0_sc_ix_b_q;
  ah_pred_meta_t           r0_ah_meta_q, r1_ah_meta_q, r2_ah_meta_q;
  ah_pred_meta_t           r0_ah_meta_b_q, r1_ah_meta_b_q, r2_ah_meta_b_q;
  s3_blk_eval_t            s2_eval_a_d, s2_eval_b_d, s3_eval_a_q, s3_eval_b_q;
  // Single ahead key register (ZERO ah_bak1/2 FF copies! Raw lives directly in sync SRAM output!)
  ah_key_t                 ah_key_q, ah_key_d;
  logic [EPOCH_W-1:0]      epoch_q, epoch_d;
  logic [FTB_BLK_ID_W-1:0] blk_seq_q, blk_seq_d;

  // ---- S0 state selection ----
  ck_t                 spec_ck, spec1_ck, s0_ck, spec_a_ck;
  logic                spec_ras_nonempty, spec1_ras_nonempty, s0_ras_nonempty, spec_a_ras_nonempty;
  logic [XLEN_BITS-1:0] spec_ras_top, spec1_ras_top, s0_ras_top, spec_a_ras_top;
  fh_t                 spec_fh, spec1_fh, s0_fh, spec_a_fh;
  logic [XLEN_BITS-1:0] s0_base, s0_b_base, s0_bnd, pc1;
  ftb_ix_t             s0_ix, s0_b_ix, ah_rd_ix1_eff, ah_rd_ix2_eff;
  ex_tage_ix_t         s0_ex_ix, s0_b_ex_ix;
  sc_ix_t              s0_sc_ix, s0_b_sc_ix;
  logic [XLEN_BITS-1:0] ah_rd_base, ah_rd_base_eff, d_obase;
  fh_t                 ah_rd_fh, ah_rd_fh_eff;
  ck_t                 o_ck;
  logic                ah_rd_en_eff;

  always_comb begin
    s0_base         = pc1;
    s0_ck           = refetch ? spec1_ck           : spec_ck;
    s0_ras_nonempty = refetch ? spec1_ras_nonempty : spec_ras_nonempty;
    s0_ras_top      = refetch ? spec1_ras_top      : spec_ras_top;
    s0_fh           = refetch ? spec1_fh           : spec_fh;
    s0_bnd          = block_bnd(s0_base);
    s0_ix           = ftb_make_index(s0_base, s0_fh);
    s0_ex_ix        = ftb_make_ex_tage_index(s0_base, s0_ck.h.ex_fh);
    s0_sc_ix        = ftb_make_sc_index(s0_base, s0_ck.h.sc_fh, s0_ck.imli);
    s0_b_ex_ix      = ftb_make_ex_tage_index(s0_b_base, spec_a_ck.h.ex_fh);
    s0_b_sc_ix      = ftb_make_sc_index(s0_b_base, spec_a_ck.h.sc_fh, spec_a_ck.imli);
  end

  // ---- Control flags ----
  logic d_valid, ovr_a, d_pair, ovr_b, ovr, issue, fast, s0_go, pd_restore, rep_ok;
  logic [1:0] squash_n, ctl_hold_n;
  logic pdq_have, rep_ok_in;
  ck_t  pd_ck;
  logic [XLEN_BITS-1:0] pd_base;

  // ---- Internal rec_q[256] as 2 even/odd banks of 128 x strict sync 1R1W SRAM (pre-launched from next_rf_blk) ----
  localparam int RF_BDEPTH = FTB_RF_REC_N / 2;
  localparam int RF_BAW    = FTB_RF_REC_W - 1;
  localparam int RF_BITS   = $bits(bpu_rf_rec_t);

  logic                    rf_bk_re [2];
  logic [RF_BAW-1:0]       rf_bk_ra [2];
  logic [RF_BITS-1:0]      rf_bk_rd [2];
  logic                    rf_bk_we [2];
  logic [RF_BAW-1:0]       rf_bk_wa [2];
  logic [RF_BITS-1:0]      rf_bk_wd [2];
  logic [FTB_BLK_ID_W-1:0] seq1;
  bpu_rf_rec_t             rf_wd0, rf_wd1, rf_rc;
  logic                    rf_carried;
  logic [XLEN_BITS-1:0]    rf_rslot;

  assign seq1 = blk_seq_q + FTB_BLK_ID_W'(1);

  always_comb begin
    rf_wd0 = '{valid: 1'b1, id: blk_seq_q, epoch: epoch_q, base: r2_q.base,   ck: r2_q.ck};
    rf_wd1 = '{valid: 1'b1, id: seq1,      epoch: epoch_q, base: r2_q.base_b, ck: r2_q.ck_b};

    rf_bk_re[0] = !next_rf_blk[0];
    rf_bk_re[1] =  next_rf_blk[0];
    rf_bk_ra[0] = next_rf_blk[FTB_RF_REC_W-1:1];
    rf_bk_ra[1] = next_rf_blk[FTB_RF_REC_W-1:1];

    rf_bk_we[0] = (d_valid && !blk_seq_q[0]) || (d_pair && !seq1[0]);
    rf_bk_wa[0] = (d_valid && !blk_seq_q[0]) ? blk_seq_q[FTB_RF_REC_W-1:1] : seq1[FTB_RF_REC_W-1:1];
    rf_bk_wd[0] = (d_valid && !blk_seq_q[0]) ? RF_BITS'(rf_wd0)            : RF_BITS'(rf_wd1);

    rf_bk_we[1] = (d_valid &&  blk_seq_q[0]) || (d_pair &&  seq1[0]);
    rf_bk_wa[1] = (d_valid &&  blk_seq_q[0]) ? blk_seq_q[FTB_RF_REC_W-1:1] : seq1[FTB_RF_REC_W-1:1];
    rf_bk_wd[1] = (d_valid &&  blk_seq_q[0]) ? RF_BITS'(rf_wd0)            : RF_BITS'(rf_wd1);

    rf_rc      = rf_blk[0] ? bpu_rf_rec_t'(rf_bk_rd[1]) : bpu_rf_rec_t'(rf_bk_rd[0]);
    rf_carried = rf_rc.valid && ((rf_pc + XLEN_BITS'(SLOT_BYTES)) == rf_rc.base);
    rf_rslot   = rf_carried ? '0 : ((rf_pc - rf_rc.base) >> SLOT_SHIFT);
    rep_ok_in  = rf_valid && rf_rc.valid && (rf_rc.id == rf_blk) && (rf_rc.epoch == epoch_q) &&
                 (rf_rslot < XLEN_BITS'(FETCH_WIDTH)) &&
                 (rf_carried || ((rf_rc.base + (rf_rslot << SLOT_SHIFT)) == rf_pc));
  end

  for (genvar bk = 0; bk < 2; bk++) begin : g_rf_bk
    ttg_sram_1r1w #(
      .DEPTH      (RF_BDEPTH),
      .WIDTH      (RF_BITS),
      .MASK_W     (1),
      .WRITE_FIRST(1'b1),
      .TAG        ("BPU_RF_REC")
    ) u_rf_rec (
      .clk  (clk),
      .re   (rf_bk_re[bk]),
      .raddr(rf_bk_ra[bk]),
      .rdata(rf_bk_rd[bk]),
      .we   (rf_bk_we[bk]),
      .waddr(rf_bk_wa[bk]),
      .wdata(rf_bk_wd[bk]),
      .wmask(1'b1)
    );
  end

`ifndef SYNTHESIS
  logic [FTB_RF_REC_W-1:0] dbg_rf_id_q;
  always_ff @(posedge clk) begin
    if (!rst_n) dbg_rf_id_q <= '0;
    else        dbg_rf_id_q <= next_rf_blk[FTB_RF_REC_W-1:0];
  end
  always_ff @(posedge clk) begin
    if (rst_n && rf_valid && (dbg_rf_id_q != rf_blk[FTB_RF_REC_W-1:0]))
      $error("bpu: u_rf_rec pre-launch mismatch latched=%0h actual=%0h",
             dbg_rf_id_q, rf_blk[FTB_RF_REC_W-1:0]);
  end
`endif

  // ---- Commit branch queue + ftb_rec (native 1.00 br/cyc pop, carries read-only prediction Meta) ----
  logic                    upd_en, upd_ah_v, upd_ah_kind;
  logic [XLEN_BITS-1:0]    upd_start, upd_ah_key_base, upd_ah_a_base, upd_pc;
  fh_t                     upd_fh, upd_ah_key_fh;
  ex_fh_t                  upd_ex_fh;
  sc_fh_t                  upd_sc_fh;
  logic [7:0]              upd_imli;
  s2_pred_meta_t           upd_s2_meta, s3_s2_meta_a, s3_s2_meta_b;
  ah_pred_meta_t           upd_ah_meta, s0_ah_meta, s0_ah_meta_b;
  ftb_br_upd_t             upd_br;
  ftb_ix_t                 upd_ix, upd_ah_ix1, upd_ah_ix2;
  ex_tage_ix_t             upd_ex_ix;
  sc_ix_t                  upd_sc_ix;
  ftb_rec_t                rec_wr_data, rec_wr_b_data;

  always_comb begin
    upd_ix     = ftb_make_index(upd_start, upd_fh);
    upd_ex_ix  = ftb_make_ex_tage_index(upd_start, upd_ex_fh);
    upd_sc_ix  = ftb_make_sc_index(upd_start, upd_sc_fh, upd_imli);
    upd_ah_ix1 = ftb_make_ah_index(upd_ah_key_base, upd_start, upd_ah_key_fh, 1'b0);
    upd_ah_ix2 = ftb_make_ah_index(upd_ah_key_base, upd_ah_a_base, upd_ah_key_fh, 1'b1);
    rec_wr_data = '{
      valid: 1'b1, id: blk_seq_q, base: r2_q.base, fh: r2_q.ck.h.fh,
      ex_fh: r2_q.ck.h.ex_fh, sc_fh: r2_q.ck.h.sc_fh, imli: r2_q.ck.imli,
      ah_v: r2_q.ah_v, ah_kind: 1'b0, ah_key_base: r2_q.ah_key_base, ah_a_base: '0, ah_key_fh: r2_q.ah_key_fh,
      s2_meta: s3_s2_meta_a, ah_meta: r2_ah_meta_q
    };
    rec_wr_b_data = '{
      valid: 1'b1, id: seq1, base: r2_q.base_b, fh: r2_q.ck_b.h.fh,
      ex_fh: r2_q.ck_b.h.ex_fh, sc_fh: r2_q.ck_b.h.sc_fh, imli: r2_q.ck_b.imli,
      ah_v: r2_q.ah_v_b, ah_kind: 1'b1, ah_key_base: r2_q.ah_key_base_b, ah_a_base: r2_q.base, ah_key_fh: r2_q.ah_key_fh_b,
      s2_meta: s3_s2_meta_b, ah_meta: r2_ah_meta_b_q
    };
  end

  bpu_ftb_brq u_brq (
    .clk, .rst_n,
    .rec_wr_en(d_valid), .rec_wr_addr(blk_seq_q[FTB_REC_W-1:0]), .rec_wr_data,
    .rec_wr_b_en(d_pair), .rec_wr_b_addr(seq1[FTB_REC_W-1:0]), .rec_wr_b_data,
    .upd_valid, .base_pc, .actual_dir, .upd_is_rvc, .br_type, .target, .pred_dir, .alt_pred, .pcpn,
    .blk_id,
    .upd_en, .upd_start, .upd_fh, .upd_ex_fh, .upd_sc_fh, .upd_imli,
    .upd_ah_v, .upd_ah_kind, .upd_ah_key_base, .upd_ah_a_base, .upd_ah_key_fh,
    .upd_s2_meta, .upd_ah_meta, .upd_br, .upd_pc,
    .commit_upd_free, .commit_tq_free
  );

  // ---- Zero-FF S3 override ahead SRAM re-read mux ----
  always_comb begin
    d_obase        = (ovr_a || !d_pair) ? r2_q.base : r2_q.base_b;
    o_ck           = (ovr_a || !d_pair) ? r2_q.ck   : r2_q.ck_b;
    ah_rd_en_eff   = s0_go || (!refetch && ovr);
    ah_rd_base_eff = (!refetch && ovr) ? d_obase   : ah_rd_base;
    ah_rd_fh_eff   = (!refetch && ovr) ? o_ck.h.fh : ah_rd_fh;
    ah_rd_ix1_eff  = ftb_make_ah_index(ah_rd_base_eff, '0, ah_rd_fh_eff, 1'b0);
    ah_rd_ix2_eff  = ftb_make_ah_index(ah_rd_base_eff, '0, ah_rd_fh_eff, 1'b1);
  end

  // ---- Predictor arrays (all deep Multi-Bank 1RW SRAMs, ZERO T0 read ports!) ----
  logic             ftb0_hit, ftb0_b_hit, ah_prefer_alt, ah2_prefer_alt;
  logic [15:0][3:0] s2_use_alt;
  logic [15:0][5:0] s2_sc_thres;
  ftb_ent_t         ftb0_ent, ftb0_b_ent;
  ftb_ah_raw_t      ah_sram_raw, ah2_sram_raw;
  logic             s2_ftb_hit, s2_b_ftb_hit;
  logic [1:0]       s2_ftb_way, s2_b_ftb_way;
  ftb_ent_t         s2_ftb_ent, s2_b_ftb_ent;
  ex_tage_raw_t     s2_tage_raw, s2_b_tage_raw;
  sc_raw_t          s2_sc_raw, s2_b_sc_raw;
  logic [7:0]       s2_sc_loc_idx, s2_b_sc_loc_idx;
  ftb_itt_raw_t     s2_itt_raw, s2_b_itt_raw;
  logic [XLEN_BITS-1:0] clr_base_eff;

  assign clr_base_eff = (pd_nb_base != '0) ? pd_nb_base : pd_base;

  bpu_ftb_arrays u_arrays (
    .clk, .rst_n,
    .s0_base, .s0_b_base,
    .ah_rd_en(ah_rd_en_eff), .ah_rd_base(ah_rd_base_eff), .ah_rd_ix1(ah_rd_ix1_eff), .ah_rd_ix2(ah_rd_ix2_eff),
    .ftb0_hit, .ftb0_ent, .ftb0_b_hit, .ftb0_b_ent,
    .ah_sram_raw, .ah2_sram_raw, .ah_prefer_alt, .ah2_prefer_alt,
    .s1_valid(r0_q.valid), .s1_b_valid(r0_q.has_b),
    .s1_base(r0_q.base), .s2_base(r1_q.base), .s1_ix(r0_ix_q), .s1_ex_ix(r0_ex_ix_q), .s1_sc_ix(r0_sc_ix_q),
    .s1_b_base(r0_q.base_b), .s2_b_base(r1_q.base_b), .s1_b_ix(r0_ix_b_q), .s1_b_ex_ix(r0_ex_ix_b_q), .s1_b_sc_ix(r0_sc_ix_b_q),
    .s2_ftb_hit, .s2_ftb_way, .s2_ftb_ent, .s2_b_ftb_hit, .s2_b_ftb_way, .s2_b_ftb_ent,
    .s2_tage_raw, .s2_sc_raw, .s2_sc_loc_idx, .s2_itt_raw,
    .s2_b_tage_raw, .s2_b_sc_raw, .s2_b_sc_loc_idx, .s2_b_itt_raw,
    .s2_use_alt, .s2_sc_thres,
    .upd_en, .upd_start, .upd_ix, .upd_ex_ix, .upd_sc_ix,
    .upd_ah_v, .upd_ah_kind, .upd_ah_key_base, .upd_ah_a_base, .upd_ah_ix1, .upd_ah_ix2,
    .upd_s2_meta, .upd_ah_meta, .upd_br,
    .clr_en(pd_valid && pd_nb_valid && pdq_have), .clr_base(clr_base_eff), .clr_pc(pd_nb_pc)
  );

  // ---- Direct live SRAM output to S0 (ZERO ah_bak muxes!) ----
  ftb_ah_pipe_t ah_pipe0;
  ftb_ah_raw_t  ah2_pipe0;

  always_comb begin
    ah_pipe0  = '{valid: ah_key_q.valid, key_base: ah_key_q.key_base, key_fh: ah_key_q.key_fh, raw: ah_sram_raw};
    ah2_pipe0 = ah2_sram_raw;
  end

  // ---- S0 / S2 / S3 evaluation & merged PTAB metadata ----
  logic                 ah_src_v, ah_hit, s0_paired;
  logic [XLEN_BITS-1:0] s0_b_bnd;
  logic [3:0]           s0_a_len, s0_b_len;
  pred_t                g0, g0_b, fin, fin_b;

  bpu_eval u_eval (
    .refetch,
    .s0_base, .s0_bnd, .s0_fh, .s0_ras_nonempty, .s0_ras_top,
    .spec_a_fh, .spec_a_ras_nonempty, .spec_a_ras_top,
    .ah_pipe0, .ah2_pipe0,
    .ftb0_hit, .ftb0_ent, .ftb0_b_hit, .ftb0_b_ent,
    .ah_prefer_alt, .ah2_prefer_alt,
    .r1_ix_q, .r1_ix_b_q, .r1_ex_ix_q, .r1_ex_ix_b_q,
    .s2_ftb_hit, .s2_ftb_way, .s2_ftb_ent, .s2_b_ftb_hit, .s2_b_ftb_way, .s2_b_ftb_ent,
    .s2_tage_raw, .s2_sc_raw, .s2_sc_loc_idx, .s2_itt_raw,
    .s2_b_tage_raw, .s2_b_sc_raw, .s2_b_sc_loc_idx, .s2_b_itt_raw,
    .r2_q, .s3_eval_a_q, .s3_eval_b_q,
    .s2_use_alt, .s2_sc_thres,
    .d_pair, .blk_seq_q,
    .ah_src_v, .ah_hit, .g0, .s0_ah_meta, .s0_b_base, .s0_b_bnd, .s0_a_len, .s0_b_len, .g0_b, .s0_ah_meta_b, .s0_paired,
    .s0_b_ix, .ah_rd_base, .ah_rd_fh,
    .s2_eval_a_d, .s2_eval_b_d,
    .fin, .fin_b, .s3_s2_meta_a, .s3_s2_meta_b,
    .out_pred_dir, .out_alt_pred, .out_pcpn, .out_blk_id
  );

  // ---- Control, speculative history/RAS, PDCKPT ----
  logic [1:0]  h_mode, h_push_n, r_mode, r_op, r_op2, r2_op, r3_op;
  logic [1:0]  hr_mode, hr_push_n, rr_mode, rr_op, rr_op2;
  logic [1:0]  i1_op, i2_op, i3_op, ir1_op, g0_i_op;
  logic [7:0]  i_ck, ir_ck;
  hist_ck_t    h_ck, hr_ck;
  logic        h2_en, h3_en;
  logic [5:0]  h_push_bits, hr_push_bits;
  logic [HSYM_W-1:0] h2_bits, h3_bits;
  ras_ck_t     r_ck, rr_ck;
  logic [XLEN_BITS-1:0] r_val, r_val2, r2_val, r3_val, rr_val, rr_val2;

  bpu_ctl u_ctl (
    .refetch, .refetch_pd, .rep_ok_in,
    .pd_valid, .pd_flush, .pdq_have, .icache_read_ready,
    .r0(r0_q), .r1(r1_q), .r2(r2_q), .fin, .fin_b,
    .d_valid, .ovr_a, .d_pair, .ovr_b, .ovr, .squash_n, .hold_n(ctl_hold_n),
    .issue, .fast, .s0_go, .pd_restore, .rep_ok
  );

  bpu_cmd u_cmd (
    .refetch, .pd_restore, .rep_ok, .ovr, .ovr_a, .d_pair, .issue, .s0_go, .s0_paired,
    .pc(pc_q), .s0_base, .s0_b_base, .refetch_address, .g0, .g0_b, .fin, .fin_b, .r2(r2_q),
    .pd_ck, .pd_hn, .pd_hbits, .pd_ras_op, .pd_ras_val, .pd_ras_op2, .pd_ras_val2,
    .rf_ck_rec(rf_rc.ck), .rf_type, .rf_pc, .rf_is_rvc,
    .h_mode, .h_ck, .h_push_n, .h_push_bits, .r_mode, .r_ck, .r_op, .r_val, .r_op2, .r_val2, .pc1,
    .h2_en, .h2_bits, .r2_op, .r2_val, .h3_en, .h3_bits, .r3_op, .r3_val, .pc_d,
    .hr_mode, .hr_ck, .hr_push_n, .hr_push_bits, .rr_mode, .rr_ck, .rr_op, .rr_val, .rr_op2, .rr_val2,
    .i1_op, .i_ck, .i2_op, .i3_op, .ir1_op, .ir_ck, .g0_i_op
  );

  bpu_spec u_spec (
    .clk, .rst_n, .upd_valid, .base_pc, .br_type, .actual_dir, .upd_is_rvc, .target,
    .h_mode, .h_ck, .h_push_n, .h_push_bits, .r_mode, .r_ck, .r_op, .r_val, .r_op2, .r_val2,
    .h2_en, .h2_bits, .r2_op, .r2_val, .h3_en, .h3_bits, .r3_op, .r3_val,
    .spec_ck, .spec_ras_nonempty, .spec_ras_top, .spec_fh,
    .spec1_ck, .spec1_ras_nonempty, .spec1_ras_top, .spec1_fh,
    .spec_a_ck, .spec_a_ras_nonempty, .spec_a_ras_top, .spec_a_fh,
    .refetch, .issue, .g0_h_en(g0.taken), .g0_h_bits(g0.hbits), .g0_r_op(g0.ras_op), .g0_r_val(g0.ras_val),
    .hr_mode, .hr_ck, .hr_push_n, .hr_push_bits, .rr_mode, .rr_ck, .rr_op, .rr_val, .rr_op2, .rr_val2,
    .i1_op, .i_ck, .i2_op, .i3_op, .ir1_op, .ir_ck, .g0_i_op
  );

  bpu_pdq u_pdq (
    .clk, .rst_n, .pop(pd_valid), .push(d_valid), .push_ck(r2_q.ck), .push_base(r2_q.base),
    .clear(refetch), .head_valid(pdq_have), .head_ck(pd_ck), .head_base(pd_base)
  );

  // ---- Next stage registers & single ahead key register ----
  always_comb begin
    r1_d       = r0_q;
    r1_d.valid = r0_q.valid && !refetch && !ovr;
    r2_d       = r1_q;
    r2_d.valid = r1_q.valid && !refetch && !ovr;

    r0_d               = '0;
    r0_d.valid         = s0_go;
    r0_d.sq            = r1_d.valid || r2_d.valid;
    r0_d.ah_v          = ah_src_v;
    r0_d.ah_hit        = ah_hit;
    r0_d.ah_key_base   = ah_key_q.key_base;
    r0_d.ah_key_fh     = ah_key_q.key_fh;
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
    r0_d.ah_key_base_b = ah_key_q.key_base;
    r0_d.ah_key_fh_b   = ah_key_q.key_fh;

    epoch_d   = epoch_q + EPOCH_W'(refetch && !pd_restore && !rep_ok);
    blk_seq_d = blk_seq_q + (d_pair ? FTB_BLK_ID_W'(2) : FTB_BLK_ID_W'(d_valid));

    ah_key_d = ah_key_q;
    if (ah_rd_en_eff) begin
      ah_key_d = '{valid: 1'b1, key_base: ah_rd_base_eff, key_fh: ah_rd_fh_eff};
    end else if (refetch) begin
      ah_key_d.valid = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pc_q           <= '0;
      r0_q           <= '0;
      r1_q           <= '0;
      r2_q           <= '0;
      epoch_q        <= '0;
      blk_seq_q      <= '0;
      ah_key_q.valid <= 1'b0;
    end else begin
      pc_q      <= pc_d;
      r0_q      <= r0_d;
      r1_q      <= r1_d;
      r2_q      <= r2_d;
      epoch_q   <= epoch_d;
      blk_seq_q <= blk_seq_d;
      ah_key_q  <= ah_key_d;
    end
  end

  always_ff @(posedge clk) begin
    r0_ix_q        <= s0_ix;
    r1_ix_q        <= r0_ix_q;
    r0_ix_b_q      <= s0_b_ix;
    r1_ix_b_q      <= r0_ix_b_q;
    r0_ex_ix_q     <= s0_ex_ix;
    r1_ex_ix_q     <= r0_ex_ix_q;
    r0_ex_ix_b_q   <= s0_b_ex_ix;
    r1_ex_ix_b_q   <= r0_ex_ix_b_q;
    r0_sc_ix_q     <= s0_sc_ix;
    r0_sc_ix_b_q   <= s0_b_sc_ix;
    r0_ah_meta_q   <= s0_ah_meta;
    r1_ah_meta_q   <= r0_ah_meta_q;
    r2_ah_meta_q   <= r1_ah_meta_q;
    r0_ah_meta_b_q <= s0_ah_meta_b;
    r1_ah_meta_b_q <= r0_ah_meta_b_q;
    r2_ah_meta_b_q <= r1_ah_meta_b_q;
    s3_eval_a_q    <= s2_eval_a_d;
    s3_eval_b_q    <= s2_eval_b_d;
  end

  assign icache_read_valid          = s0_go;
  assign fetch_address              = s0_base;
  assign pair_valid                 = s0_go && s0_paired;
  assign pair_addr2                 = s0_b_base;
  assign pair_a_len                 = s0_a_len;
  assign pair_b_len                 = s0_b_len;
  assign override_valid             = ovr;
  assign override_squash_n          = squash_n;
  assign hold_n                     = ctl_hold_n;
  assign ptab_write_enable          = d_valid;
  assign ptab_base_pc               = r2_q.base;
  assign ptab_is_pair               = d_pair;
  assign ptab_base_b                = r2_q.base_b;
  assign ptab_a_len                 = r2_q.a_len;
  assign predict_next_fetch_address = d_pair ? fin_b.next : fin.next;

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = ^{g0.ty, g0_b.slot, g0_b.ty, g0_b.rvc, g0_b.carried,
                       fin.slot, fin.ty, fin.rvc, fin.carried, fin_b.slot, fin_b.ty, fin_b.rvc, fin_b.carried,
                       fast, ovr_b, spec_ck.h.head, pc1, upd_pc, next_rf_blk, o_ck};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
