// Ref: front-end/BPU/BPU_pipe.h & BpuFtb.h
// Pure Single-Set Unified 2-Ahead BPU (uFTB 256 + 1x Main FTB + 1x 2-Way 6-tbl 2-Ahead TAGE + 1x 4-tbl 2-Ahead ITT)
//   - A0 -> A1 (ah_a1_raw_q) -> S0 (2-Ahead + uFTB) -> S1 (Main FTB read + self0 capture) -> S2 (Main FTB + self0 eval)
//   - T0 -> T1 training register in u_brq + uFTB FastFill + MORSL prev_base sec_tag; external port unchanged
`default_nettype none

module bpu import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    refetch,
  input  logic [XLEN_BITS-1:0]    refetch_address,
  input  logic                    refetch_pd,
  input  logic                    icache_read_ready,
  input  logic                    rf_valid,
  input  logic [FTB_BLK_ID_W-1:0] rf_blk,
  input  logic [FTB_BLK_ID_W-1:0] next_rf_blk,
  input  logic [2:0]              rf_type,
  input  logic [XLEN_BITS-1:0]    rf_pc,
  input  logic                    rf_is_rvc,
  input  logic                    pd_valid,
  input  logic                    pd_flush,
  input  logic                    pd_hn,
  input  logic [HSYM_W-1:0]       pd_hbits,
  input  logic [1:0]              pd_ras_op,
  input  logic [XLEN_BITS-1:0]    pd_ras_val,
  input  logic                    pd_nb_valid,
  input  logic [XLEN_BITS-1:0]    pd_nb_pc,
  input  logic [NCOMMIT-1:0]      upd_valid,
  input  logic [XLEN_BITS-1:0]    base_pc    [NCOMMIT],
  input  logic [NCOMMIT-1:0]      actual_dir,
  input  logic [NCOMMIT-1:0]      upd_is_rvc,
  input  logic [2:0]              br_type    [NCOMMIT],
  input  logic [XLEN_BITS-1:0]    target     [NCOMMIT],
  input  logic [NCOMMIT-1:0]      pred_dir,
  input  logic [NCOMMIT-1:0]      alt_pred,
  input  logic [PCPN_W-1:0]       pcpn       [NCOMMIT],
  input  logic [FTB_BLK_ID_W-1:0] blk_id     [NCOMMIT],
  output logic                    icache_read_valid,
  output logic [XLEN_BITS-1:0]    fetch_address,
  output logic                    override_valid,
  output logic [1:0]              override_squash_n,
  output logic [1:0]              hold_n,
  output logic                    ptab_write_enable,
  output logic [XLEN_BITS-1:0]    ptab_base_pc,
  output logic [XLEN_BITS-1:0]    predict_next_fetch_address,
  output logic [NLANE-1:0]        out_pred_dir,
  output logic [NLANE-1:0]        out_alt_pred,
  output logic [PCPN_W-1:0]       out_pcpn      [NLANE],
  output logic [FTB_BLK_ID_W-1:0] out_blk_id,
  output logic [3:0]              commit_upd_free,
  output logic [3:0]              commit_tq_free
);

  typedef struct packed {
    logic                 valid;
    logic [XLEN_BITS-1:0] key_base;
    ex_fh0_t              key_ex_fh;
  } ah_key_t;

  // ---- Pipeline registers (A0 -> ah_key_q -> ah_a1_raw_q [S0] -> r0_q [S1] -> r1_q [S2]) ----
  logic [XLEN_BITS-1:0]    pc_q, pc_d, prev_base_q, prev_base_d;
  blk_t                    r0_q, r0_d, r1_q, r1_d;
  ah_pred_meta_t           r0_ah_meta_q, r1_ah_meta_q;
  ah_key_t                 ah_key_q, ah_key_d;
  ftb_ah_pipe_t            ah_a1_raw_q, ah_a1_raw_d;
  logic                    self0_v_q, self0_v_d;
  ftb_ah_raw_t             self0_raw_q;
  logic [EPOCH_W-1:0]      epoch_q, epoch_d;
  logic [FTB_BLK_ID_W-1:0] blk_seq_q, blk_seq_d;

  // ---- Control & S0 state ----
  ck_t                 spec_ck, pd_ck;
  logic                spec_ras_nonempty, pdq_have, rep_ok_in;
  logic [XLEN_BITS-1:0] spec_ras_top, pd_base, s0_base, s0_bnd;
  ex_fh_t              spec_ex_fh;
  logic                d_valid, ovr, issue, s0_go, pd_restore, rep_ok;
  logic [1:0]          squash_n, ctl_hold_n;

  assign s0_base = pc_q;
  assign s0_bnd  = block_bnd(s0_base);

  // ---- Single-bank internal u_rf_rec[256] strict sync 1R1W SRAM ----
  localparam int RF_BITS = $bits(bpu_rf_rec_t);
  logic [RF_BITS-1:0]   rf_rd_raw;
  bpu_rf_rec_t          rf_wd, rf_rc;
  logic                 rf_carried;
  logic [XLEN_BITS-1:0] rf_diff;

  always_comb begin
    rf_wd      = '{valid: 1'b1, id: blk_seq_q, epoch: epoch_q, base: r1_q.base, ck: r1_q.ck};
    rf_rc      = bpu_rf_rec_t'(rf_rd_raw);
    rf_diff    = rf_pc - rf_rc.base;
    rf_carried = rf_rc.valid && (rf_diff == -XLEN_BITS'(SLOT_BYTES));
    rep_ok_in  = rf_valid && rf_rc.valid && (rf_rc.id == rf_blk) && (rf_rc.epoch == epoch_q) &&
                 (rf_carried || ((rf_diff[XLEN_BITS-1:SLOT_SHIFT+4] == '0) && (rf_diff[SLOT_SHIFT-1:0] == '0)));
  end

  ttg_sram_1r1w #(
    .DEPTH(FTB_RF_REC_N), .WIDTH(RF_BITS), .MASK_W(1), .TAG("BPU_RF_REC")
  ) u_rf_rec (
    .clk, .rst_n(rst_n), .re(1'b1), .raddr(next_rf_blk[FTB_RF_REC_W-1:0]), .rdata(rf_rd_raw),
    .we(d_valid), .waddr(blk_seq_q[FTB_RF_REC_W-1:0]), .wdata(RF_BITS'(rf_wd)), .wmask(1'b1)
  );

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

  // ---- Commit branch queue (T0 -> T1) + single-bank u_rec[512] ----
  logic                 upd_en, upd_ah_v, upd_ah_self0;
  logic [XLEN_BITS-1:0] upd_start, upd_ah_key_base, upd_prev_base, upd_pc;
  ex_fh_t               upd_ex_fh;
  ex_fh0_t              upd_ah_key_ex_fh;
  ftb1_lookup_meta_t    s2_ftb1_meta, upd_ftb1_meta;
  ah_pred_meta_t        s0_ah_meta, s2_ah_meta, upd_ah_meta;
  ftb_br_upd_t          upd_br;
  ftb_rec_t             rec_wr_data;
  logic                 s2_ah_self0;

  assign rec_wr_data = '{
    valid:        1'b1,
    id:           blk_seq_q,
    base:         r1_q.base,
    ex_fh:        r1_q.ck.h.ex_fh,
    ah_v:         r1_q.ah_v,
    ah_self0:     s2_ah_self0,
    ah_key_base:  r1_q.ah_key_base,
    prev_base:    r1_q.prev_base,
    ah_key_ex_fh: r1_q.ah_key_ex_fh,
    ftb1_meta:    s2_ftb1_meta,
    ah_meta:      s2_ah_meta
  };

  bpu_ftb_brq u_brq (
    .clk, .rst_n,
    .rec_wr_en(d_valid), .rec_wr_addr(blk_seq_q[FTB_REC_W-1:0]), .rec_wr_data,
    .upd_valid, .base_pc, .actual_dir, .upd_is_rvc, .br_type, .target, .pred_dir, .alt_pred, .pcpn, .blk_id,
    .upd_en, .upd_start, .upd_ex_fh, .upd_ah_v, .upd_ah_self0, .upd_ah_key_base, .upd_prev_base,
    .upd_ah_key_ex_fh, .upd_ftb1_meta, .upd_ah_meta, .upd_br, .upd_pc,
    .commit_upd_free, .commit_tq_free
  );

  // ---- A0 2-Ahead SRAM read launch mux ----
  logic                 ah_rd_en_eff;
  logic [XLEN_BITS-1:0] ah_rd_base_eff;
  ex_fh0_t              ah_rd_key_fh;
  ex_tage_ix_t          ah_rd_ex_ix;
  itt_ix_t              ah_rd_itt_ix;

  always_comb begin
    // an S2 override relaunches the read for its own block (fast override, no registered ovr_pend bubble)
    ah_rd_en_eff     = !refetch && (ovr || icache_read_ready);
    ah_rd_base_eff   = ovr ? r1_q.base          : s0_base;
    ah_rd_key_fh     = ovr ? r1_q.ck.h.ex_fh[0] : spec_ex_fh[0];
    // the read launch needs only the index: w / tag of the read index are not consumed
    ah_rd_ex_ix      = '0;
    ah_rd_itt_ix     = '0;
    ah_rd_ex_ix.idx  = ah_ex_tage_idx(ah_rd_base_eff, ah_rd_key_fh);
    ah_rd_itt_ix.idx = ah_itt_idx(ah_rd_base_eff, ah_rd_key_fh);
  end

  // ---- Single-Set Predictor Arrays ----
  logic                 ftb0_hit, s2_ftb_hit, ff_en;
  logic [15:0][3:0]     ah_use_alt;
  ftb_ent_t             ftb0_ent, s2_ftb_ent;
  ftb_ah_raw_t          ah_sram_raw;
  logic [1:0]           s2_ftb_way;
  pred_t                g0, fin;

  assign ff_en        = d_valid && s2_ftb_hit && !r1_q.g.hit && fin.taken;

  bpu_ftb_arrays u_arrays (
    .clk, .rst_n,
    .s0_base, .ah_rd_en(ah_rd_en_eff), .ah_rd_ex_ix, .ah_rd_itt_ix,
    .ftb0_hit, .ftb0_ent, .ah_sram_raw, .ah_use_alt,
    .s1_valid(r0_q.valid), .s1_base(r0_q.base), .s2_base(r1_q.base),
    .s2_ftb_hit, .s2_ftb_way, .s2_ftb_ent,
    .ff_en, .ff_base(r1_q.base), .ff_ent(s2_ftb_ent),
    .upd_en, .upd_start, .upd_ex_fh, .upd_ah_v, .upd_ah_self0, .upd_ah_key_base, .upd_prev_base,
    .upd_ah_key_ex_fh, .upd_ftb1_meta, .upd_ah_meta, .upd_br,
    .clr_en(pd_valid && pd_nb_valid && pdq_have), .clr_base(pd_base), .clr_pc(pd_nb_pc)
  );

  // ---- S0 / S2 evaluation ----
  logic        ah_src_v, ah_hit, fin_diff;
  ah_dir_itt_t s0_ah_dir_itt;

  bpu_eval u_eval (
    .refetch,
    .s0_base, .s0_bnd, .spec_ex_fh, .prev_base_q,
    .s0_ras_nonempty(spec_ras_nonempty), .s0_ras_top(spec_ras_top),
    .ah_a1_raw_q, .ftb0_hit, .ftb0_ent, .ah_use_alt,
    .r1_q, .r1_ah_meta_q, .self0_v_q, .self0_raw_q,
    .s2_ftb_hit, .s2_ftb_way, .s2_ftb_ent, .blk_seq_q,
    .ah_src_v, .ah_hit, .s0_ah_dir_itt, .g0, .s0_ah_meta,
    .fin, .fin_diff, .s2_ah_self0, .s2_ftb1_meta, .s2_ah_meta,
    .out_pred_dir, .out_alt_pred, .out_pcpn, .out_blk_id
  );

  // ---- Control, speculative history/RAS, PDCKPT ----
  logic [1:0]           h_mode, r_mode, r_op, hr_mode, rr_mode, rr_op;
  hist_ck_t             h_ck, hr_ck;
  logic                 h_push_en, hr_push_n;
  logic [HSYM_W-1:0]    h_push_bits, hr_push_bits;
  ras_ck_t              r_ck, rr_ck;
  logic [XLEN_BITS-1:0] r_val, rr_val;

  bpu_ctl u_ctl (
    .refetch, .refetch_pd, .rep_ok_in,
    .pd_valid, .pd_flush, .pdq_have, .icache_read_ready,
    .r0(r0_q), .r1(r1_q), .fin_diff,
    .d_valid, .ovr, .squash_n, .hold_n(ctl_hold_n), .issue, .s0_go, .pd_restore, .rep_ok
  );

  bpu_cmd u_cmd (
    .refetch, .pd_restore, .rep_ok, .ovr, .r1_ck(r1_q.ck),
    .issue, .pc(pc_q), .refetch_address, .g0, .fin,
    .pd_ck, .pd_hn, .pd_hbits, .pd_ras_op, .pd_ras_val,
    .rf_ck_rec(rf_rc.ck), .rf_type, .rf_pc, .rf_is_rvc,
    .h_mode, .h_ck, .h_push_en, .h_push_bits, .r_mode, .r_ck, .r_op, .r_val, .pc_d,
    .hr_mode, .hr_ck, .hr_push_n, .hr_push_bits, .rr_mode, .rr_ck, .rr_op, .rr_val
  );

  bpu_spec u_spec (
    .clk, .rst_n, .upd_valid, .base_pc, .br_type, .actual_dir, .upd_is_rvc, .target,
    .h_mode, .h_ck, .h_push_en, .h_push_bits, .r_mode, .r_ck, .r_op, .r_val,
    .spec_ck, .spec_ras_nonempty, .spec_ras_top, .spec_ex_fh,
    .refetch, .issue,
    .g0_h_en(g0.taken), .g0_h_bits(g0.hbits), .g0_r_op(g0.ras_op), .g0_r_val(g0.ras_val),
    .hr_mode, .hr_ck, .hr_push_n, .hr_push_bits, .rr_mode, .rr_ck, .rr_op, .rr_val
  );

  bpu_pdq u_pdq (
    .clk, .rst_n, .pop(pd_valid), .push(d_valid), .push_ck(r1_q.ck), .push_base(r1_q.base),
    .clear(refetch), .head_valid(pdq_have), .head_ck(pd_ck), .head_base(pd_base)
  );

  // ---- Pipeline & 2-Ahead registers ----
  always_comb begin
    r1_d              = r0_q;
    r1_d.valid        = r0_q.valid && !refetch && !ovr;
    r0_d              = '0;
    r0_d.valid        = s0_go;
    r0_d.sq           = r1_d.valid;
    r0_d.ah_v         = ah_src_v;
    r0_d.ah_hit       = ah_hit;
    r0_d.ah_key_base  = ah_a1_raw_q.key_base;
    r0_d.prev_base    = prev_base_q;
    r0_d.ah_key_ex_fh = ah_a1_raw_q.key_ex_fh;
    r0_d.base         = s0_base;
    r0_d.g            = g0;
    r0_d.ck           = spec_ck;
    r0_d.ah_dir_itt   = s0_ah_dir_itt;
    self0_v_d         = r1_d.valid && !r0_q.ah_v && ah_key_q.valid && (ah_key_q.key_base == r0_q.base);
    epoch_d           = epoch_q + EPOCH_W'(refetch && !pd_restore && !rep_ok);
    blk_seq_d         = blk_seq_q + FTB_BLK_ID_W'(d_valid);
  end

  always_comb begin
    ah_key_d    = ah_key_q;
    ah_a1_raw_d = ah_a1_raw_q;
    prev_base_d = prev_base_q;
    if (refetch) begin
      ah_key_d.valid    = 1'b0;
      ah_a1_raw_d.valid = 1'b0;
      prev_base_d       = '0;
    end else if (ovr) begin
      ah_a1_raw_d.valid = 1'b0;
      ah_key_d          = '{valid: 1'b1, key_base: r1_q.base, key_ex_fh: r1_q.ck.h.ex_fh[0]};
      prev_base_d       = r1_q.base;
    end else if (icache_read_ready) begin
      ah_key_d    = '{valid: 1'b1, key_base: s0_base, key_ex_fh: spec_ex_fh[0]};
      ah_a1_raw_d = '{valid: ah_key_q.valid, key_base: ah_key_q.key_base,
                      key_ex_fh: ah_key_q.key_ex_fh, raw: ah_sram_raw};
      prev_base_d = s0_base;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pc_q <= '0; prev_base_q <= '0; r0_q <= '0; r1_q <= '0;
      epoch_q <= '0; blk_seq_q <= '0;
      ah_key_q.valid <= 1'b0; ah_a1_raw_q.valid <= 1'b0;
      self0_v_q <= 1'b0;
    end else begin
      pc_q <= pc_d; prev_base_q <= prev_base_d; r0_q <= r0_d; r1_q <= r1_d;
      epoch_q <= epoch_d; blk_seq_q <= blk_seq_d;
      ah_key_q <= ah_key_d; ah_a1_raw_q <= ah_a1_raw_d;
      self0_v_q <= self0_v_d;
    end
    if (!rst_n) self0_raw_q <= '0;
    else if (self0_v_d) self0_raw_q <= ah_sram_raw;
    r0_ah_meta_q <= s0_ah_meta;
    r1_ah_meta_q <= r0_ah_meta_q;
  end

  // ---- External ports ----
  assign icache_read_valid          = s0_go;
  assign fetch_address              = s0_base;
  assign override_valid             = ovr;
  assign override_squash_n          = squash_n;
  assign hold_n                     = ctl_hold_n;
  assign ptab_write_enable          = d_valid;
  assign ptab_base_pc               = r1_q.base;
  assign predict_next_fetch_address = fin.next;

  logic unused_ok;
  assign unused_ok = ^{upd_pc, next_rf_blk[FTB_BLK_ID_W-1:FTB_RF_REC_W]};

endmodule
`default_nettype wire
