// Ref: front-end/BPU/BPU_pipe.h & BpuFtb.h
// Clean BPU v11 (Plan A): Single-block 1-Taken 1-Ahead A + S2 6-table ExBlockTage + Deep Multi-Bank 1RW SRAM
//   - 3-stage pipeline: S0 (1-Ahead A / uFTB) -> S1 (1RW SRAM read) -> S2 (Main eval/override, MAIN_LAT=2)
//   - Single unified folded-history engine ex_fh[3][6] (HR_BITS=256, ARCH_SR_W=200); ZERO 2-Ahead B / SC / S3
//   - 2A (no same-cycle refetch S0 issue) + 2B (1-cycle registered ovr_pend_q spec/RAS restore + Zero-FF Ahead re-read)
//   - External port interface 100% compatible with Unified FTQ-64 / front_pred_path (pair_valid=0, ptab_is_pair=0)
`default_nettype none

module bpu import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    refetch,
  input  logic [XLEN_BITS-1:0]    refetch_address,
  input  logic                    refetch_pd,
  input  logic                    icache_read_ready,
  // repair information of a back-end branch mispredict (single-bank sync SRAM rec_q[256] pre-launched from next_rf_blk)
  input  logic                    rf_valid,
  input  logic [FTB_BLK_ID_W-1:0] rf_blk,
  input  logic [FTB_BLK_ID_W-1:0] next_rf_blk,
  input  logic [2:0]              rf_type,
  input  logic [XLEN_BITS-1:0]    rf_pc,
  input  logic                    rf_is_rvc,
  // result of the predecode check of the previous cycle
  input  logic                    pd_valid,
  input  logic                    pd_flush,
  input  logic [1:0]              pd_hn,
  input  logic [5:0]              pd_hbits,
  input  logic [1:0]              pd_ras_op,
  input  logic [XLEN_BITS-1:0]    pd_ras_val,
  input  logic [1:0]              pd_ras_op2,
  input  logic [XLEN_BITS-1:0]    pd_ras_val2,
  input  logic                    pd_nb_valid,
  input  logic [XLEN_BITS-1:0]    pd_nb_pc,
  input  logic [XLEN_BITS-1:0]    pd_nb_base,
  // commit stream
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
  // S0: block address to Unified FTQ-64 (1-Taken: pair_valid = 0)
  output logic                    icache_read_valid,
  output logic [XLEN_BITS-1:0]    fetch_address,
  output logic                    pair_valid,
  output logic [XLEN_BITS-1:0]    pair_addr2,
  output logic [3:0]              pair_a_len,
  output logic [3:0]              pair_b_len,
  // S2: override of S1 block (squash_n in 0..1) & exact FTQ ifu_ptr hold count
  output logic                    override_valid,
  output logic [1:0]              override_squash_n,
  output logic [1:0]              hold_n,
  // S2: prediction written into Unified FTQ-64
  output logic                    ptab_write_enable,
  output logic [XLEN_BITS-1:0]    ptab_base_pc,
  output logic                    ptab_is_pair,
  output logic [XLEN_BITS-1:0]    ptab_base_b,
  output logic [3:0]              ptab_a_len,
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
    ex_fh_t               key_ex_fh;
  } ah_key_t;

  // ---- Pipeline registers (S0 -> r0_q [S1] -> r1_q [S2]) ----
  logic [XLEN_BITS-1:0]    pc_q, pc_d;
  blk_t                    r0_q, r0_d, r1_q, r1_d;
  ftb_ix_t                 r0_ix_q, r1_ix_q;
  ex_tage_ix_t             r0_ex_ix_q, r1_ex_ix_q;
  ah_pred_meta_t           r0_ah_meta_q, r1_ah_meta_q;
  ah_key_t                 ah_key_q, ah_key_d;
  logic [EPOCH_W-1:0]      epoch_q, epoch_d;
  logic [FTB_BLK_ID_W-1:0] blk_seq_q, blk_seq_d;
  // 2B: 1-cycle registered S2 override recovery (decouples S2 ovr from u_spec & u_arrays!)
  logic                    ovr_pend_q, ovr_pend_d;
  ck_t                     ovr_ck_q;
  pred_t                   ovr_out_q;
  logic [XLEN_BITS-1:0]    ovr_base_q;

  // ---- S0 state selection (2A: pure registered spec_q / pc_q!) ----
  ck_t                 spec_ck;
  logic                spec_ras_nonempty;
  logic [XLEN_BITS-1:0] spec_ras_top;
  ex_fh_t              spec_ex_fh;
  logic [XLEN_BITS-1:0] s0_base, s0_bnd;
  ftb_ix_t             s0_ix, ah_rd_ix_eff;
  ex_tage_ix_t         s0_ex_ix;
  logic [XLEN_BITS-1:0] ah_rd_base_eff;
  ex_fh_t              ah_rd_ex_fh_eff;
  logic                ah_rd_en_eff;

  always_comb begin
    s0_base  = pc_q;
    s0_bnd   = block_bnd(s0_base);
    s0_ix    = ftb_make_index(s0_base, spec_ex_fh);
    s0_ex_ix = ftb_make_ex_tage_index(s0_base, spec_ex_fh);
  end

  // ---- Control flags ----
  logic d_valid, ovr, issue, issue_no_ovr, s0_go, pd_restore, rep_ok;
  logic [1:0] squash_n, ctl_hold_n;
  logic pdq_have, rep_ok_in;
  ck_t  pd_ck;
  logic [XLEN_BITS-1:0] pd_base;

  // ---- Single-bank internal rec_q[256] strict sync 1R1W SRAM (pre-launched from next_rf_blk) ----
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
    .DEPTH      (FTB_RF_REC_N),
    .WIDTH      (RF_BITS),
    .MASK_W     (1),
    .WRITE_FIRST(1'b1),
    .TAG        ("BPU_RF_REC")
  ) u_rf_rec (
    .clk  (clk),
    .re   (1'b1),
    .raddr(next_rf_blk[FTB_RF_REC_W-1:0]),
    .rdata(rf_rd_raw),
    .we   (d_valid),
    .waddr(blk_seq_q[FTB_RF_REC_W-1:0]),
    .wdata(RF_BITS'(rf_wd)),
    .wmask(1'b1)
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

  // ---- Commit branch queue + single-bank ftb_rec (native 1.00 br/cyc pop) ----
  logic                 upd_en, upd_ah_v;
  logic [XLEN_BITS-1:0] upd_start, upd_ah_key_base, upd_pc;
  ex_fh_t               upd_ex_fh, upd_ah_key_ex_fh;
  s2_pred_meta_t        upd_s2_meta, s2_meta;
  ah_pred_meta_t        upd_ah_meta, s0_ah_meta;
  ftb_br_upd_t          upd_br;
  ftb_ix_t              upd_ix, upd_ah_ix;
  ex_tage_ix_t          upd_ex_ix;
  ftb_rec_t             rec_wr_data;

  always_comb begin
    upd_ix    = ftb_make_index(upd_start, upd_ex_fh);
    upd_ex_ix = ftb_make_ex_tage_index(upd_start, upd_ex_fh);
    upd_ah_ix = ftb_make_ah_index(upd_ah_key_base, upd_start, upd_ah_key_ex_fh);
    rec_wr_data = '{
      valid:        1'b1,
      id:           blk_seq_q,
      base:         r1_q.base,
      ex_fh:        r1_q.ck.h.ex_fh,
      ah_v:         r1_q.ah_v,
      ah_key_base:  r1_q.ah_key_base,
      ah_key_ex_fh: r1_q.ah_key_ex_fh,
      s2_meta:      s2_meta,
      ah_meta:      r1_ah_meta_q
    };
  end

  bpu_ftb_brq u_brq (
    .clk, .rst_n,
    .rec_wr_en(d_valid), .rec_wr_addr(blk_seq_q[FTB_REC_W-1:0]), .rec_wr_data,
    .upd_valid, .base_pc, .actual_dir, .upd_is_rvc, .br_type, .target, .pred_dir, .alt_pred, .pcpn,
    .blk_id,
    .upd_en, .upd_start, .upd_ex_fh,
    .upd_ah_v, .upd_ah_key_base, .upd_ah_key_ex_fh,
    .upd_s2_meta, .upd_ah_meta, .upd_br, .upd_pc,
    .commit_upd_free, .commit_tq_free
  );

  // ---- Zero-FF S2 override ahead SRAM re-read mux (2B + Cut A1: decoupled from combinational ovr!) ----
  always_comb begin
    ah_rd_en_eff    = !refetch && (ovr_pend_q || icache_read_ready);
    ah_rd_base_eff  = (!refetch && ovr_pend_q) ? ovr_base_q       : s0_base;
    ah_rd_ex_fh_eff = (!refetch && ovr_pend_q) ? ovr_ck_q.h.ex_fh : spec_ex_fh;
    ah_rd_ix_eff    = ftb_make_ah_index(ah_rd_base_eff, '0, ah_rd_ex_fh_eff);
  end

  // ---- Predictor arrays (7 clean tables, deep Multi-Bank 1RW SRAM, ZERO T0 read ports!) ----
  logic                 ftb0_hit, ah_prefer_alt;
  logic [15:0][3:0]     s2_use_alt;
  ftb_ent_t             ftb0_ent;
  ftb_ah_raw_t          ah_sram_raw;
  logic                 s2_ftb_hit;
  logic [1:0]           s2_ftb_way;
  ftb_ent_t             s2_ftb_ent;
  ex_tage_raw_t         s2_tage_raw;
  ftb_itt_raw_t         s2_itt_raw;
  logic [XLEN_BITS-1:0] clr_base_eff;

  assign clr_base_eff = (pd_nb_base != '0) ? pd_nb_base : pd_base;

  bpu_ftb_arrays u_arrays (
    .clk, .rst_n,
    .s0_base,
    .ah_rd_en(ah_rd_en_eff), .ah_rd_base(ah_rd_base_eff), .ah_rd_ix(ah_rd_ix_eff),
    .ftb0_hit, .ftb0_ent, .ah_sram_raw, .ah_prefer_alt,
    .s1_valid(r0_q.valid), .s1_base(r0_q.base), .s2_base(r1_q.base), .s1_ix(r0_ix_q), .s1_ex_ix(r0_ex_ix_q),
    .s2_ftb_hit, .s2_ftb_way, .s2_ftb_ent, .s2_tage_raw, .s2_itt_raw, .s2_use_alt,
    .upd_en, .upd_start, .upd_ix, .upd_ex_ix,
    .upd_ah_v, .upd_ah_key_base, .upd_ah_ix,
    .upd_s2_meta, .upd_ah_meta, .upd_br,
    .clr_en(pd_valid && pd_nb_valid && pdq_have), .clr_base(clr_base_eff), .clr_pc(pd_nb_pc)
  );

  // ---- Direct live SRAM output to S0 (ZERO ah_bak FF copies!) ----
  ftb_ah_pipe_t ah_pipe0;
  always_comb begin
    ah_pipe0 = '{valid: ah_key_q.valid, key_base: ah_key_q.key_base, key_ex_fh: ah_key_q.key_ex_fh, raw: ah_sram_raw};
  end

  // ---- S0 / S2 evaluation & PTAB metadata ----
  logic  ah_src_v, ah_hit, fin_diff;
  pred_t g0, fin;

  bpu_eval u_eval (
    .refetch,
    .s0_base, .s0_bnd, .s0_ras_nonempty(spec_ras_nonempty), .s0_ras_top(spec_ras_top),
    .ah_pipe0, .ftb0_hit, .ftb0_ent, .ah_prefer_alt,
    .r1_q, .r1_ix_q, .r1_ex_ix_q,
    .s2_ftb_hit, .s2_ftb_way, .s2_ftb_ent, .s2_tage_raw, .s2_itt_raw, .s2_use_alt,
    .blk_seq_q,
    .ah_src_v, .ah_hit, .g0, .s0_ah_meta,
    .fin, .fin_diff, .s2_meta, .out_pred_dir, .out_alt_pred, .out_pcpn, .out_blk_id
  );

  // ---- Control, speculative history/RAS, PDCKPT ----
  logic [1:0]           h_mode, r_mode, r_op;
  logic [1:0]           hr_mode, hr_push_n, rr_mode, rr_op, rr_op2;
  hist_ck_t             h_ck, hr_ck;
  logic                 h_push_en;
  logic [5:0]           hr_push_bits;
  logic [HSYM_W-1:0]    h_push_bits;
  ras_ck_t              r_ck, rr_ck;
  logic [XLEN_BITS-1:0] r_val, rr_val, rr_val2;

  assign issue_no_ovr = !refetch && !ovr_pend_q && icache_read_ready;

  bpu_ctl u_ctl (
    .refetch, .refetch_pd, .ovr_pend(ovr_pend_q), .rep_ok_in,
    .pd_valid, .pd_flush, .pdq_have, .icache_read_ready,
    .r0(r0_q), .r1(r1_q), .fin_diff,
    .d_valid, .ovr, .squash_n, .hold_n(ctl_hold_n),
    .issue, .s0_go, .pd_restore, .rep_ok
  );

  bpu_cmd u_cmd (
    .refetch, .pd_restore, .rep_ok, .ovr,
    .ovr_pend(ovr_pend_q), .ovr_ck(ovr_ck_q), .ovr_out(ovr_out_q),
    .issue, .pc(pc_q), .refetch_address, .g0, .fin,
    .pd_ck, .pd_hn, .pd_hbits, .pd_ras_op, .pd_ras_val, .pd_ras_op2, .pd_ras_val2,
    .rf_ck_rec(rf_rc.ck), .rf_type, .rf_pc, .rf_is_rvc,
    .h_mode, .h_ck, .h_push_en, .h_push_bits, .r_mode, .r_ck, .r_op, .r_val, .pc_d,
    .hr_mode, .hr_ck, .hr_push_n, .hr_push_bits, .rr_mode, .rr_ck, .rr_op, .rr_val, .rr_op2, .rr_val2
  );

  bpu_spec u_spec (
    .clk, .rst_n, .upd_valid, .base_pc, .br_type, .actual_dir, .upd_is_rvc, .target,
    .h_mode, .h_ck, .h_push_en, .h_push_bits, .r_mode, .r_ck, .r_op, .r_val,
    .spec_ck, .spec_ras_nonempty, .spec_ras_top, .spec_ex_fh,
    .refetch, .ovr, .issue(issue_no_ovr),
    .g0_h_en(g0.taken), .g0_h_bits(g0.hbits), .g0_r_op(g0.ras_op), .g0_r_val(g0.ras_val),
    .hr_mode, .hr_ck, .hr_push_n, .hr_push_bits, .rr_mode, .rr_ck, .rr_op, .rr_val, .rr_op2, .rr_val2
  );

  bpu_pdq u_pdq (
    .clk, .rst_n, .pop(pd_valid), .push(d_valid), .push_ck(r1_q.ck), .push_base(r1_q.base),
    .clear(refetch), .head_valid(pdq_have), .head_ck(pd_ck), .head_base(pd_base)
  );

  // ---- Next stage registers & single ahead key register ----
  always_comb begin
    r1_d       = r0_q;
    r1_d.valid = r0_q.valid && !refetch && !ovr;

    r0_d              = '0;
    r0_d.valid        = s0_go;
    r0_d.sq           = r1_d.valid;
    r0_d.ah_v         = ah_src_v;
    r0_d.ah_hit       = ah_hit;
    r0_d.ah_key_base  = ah_key_q.key_base;
    r0_d.ah_key_ex_fh = ah_key_q.key_ex_fh;
    r0_d.base         = s0_base;
    r0_d.g            = g0;
    r0_d.ck           = spec_ck;

    epoch_d    = epoch_q + EPOCH_W'(refetch && !pd_restore && !rep_ok);
    blk_seq_d  = blk_seq_q + FTB_BLK_ID_W'(d_valid);
    ovr_pend_d = !refetch && !ovr_pend_q && ovr;

    ah_key_d = ah_key_q;
    if (ah_rd_en_eff) begin
      ah_key_d = '{valid: 1'b1, key_base: ah_rd_base_eff, key_ex_fh: ah_rd_ex_fh_eff};
    end else if (refetch) begin
      ah_key_d.valid = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pc_q           <= '0;
      r0_q           <= '0;
      r1_q           <= '0;
      epoch_q        <= '0;
      blk_seq_q      <= '0;
      ah_key_q.valid <= 1'b0;
      ovr_pend_q     <= 1'b0;
    end else begin
      pc_q       <= pc_d;
      r0_q       <= r0_d;
      r1_q       <= r1_d;
      epoch_q    <= epoch_d;
      blk_seq_q  <= blk_seq_d;
      ah_key_q   <= ah_key_d;
      ovr_pend_q <= ovr_pend_d;
    end
    if (!refetch && !ovr_pend_q && ovr) begin
      ovr_ck_q   <= r1_q.ck;
      ovr_out_q  <= fin;
      ovr_base_q <= r1_q.base;
    end
  end

  always_ff @(posedge clk) begin
    r0_ix_q      <= s0_ix;
    r1_ix_q      <= r0_ix_q;
    r0_ex_ix_q   <= s0_ex_ix;
    r1_ex_ix_q   <= r0_ex_ix_q;
    r0_ah_meta_q <= s0_ah_meta;
    r1_ah_meta_q <= r0_ah_meta_q;
  end

  // ---- External ports (100% compatible with Unified FTQ-64 / front_pred_path) ----
  assign icache_read_valid          = s0_go;
  assign fetch_address              = s0_base;
  assign pair_valid                 = 1'b0;
  assign pair_addr2                 = '0;
  assign pair_a_len                 = '0;
  assign pair_b_len                 = '0;
  assign override_valid             = ovr;
  assign override_squash_n          = squash_n;
  assign hold_n                     = ctl_hold_n;
  assign ptab_write_enable          = d_valid;
  assign ptab_base_pc               = r1_q.base;
  assign ptab_is_pair               = 1'b0;
  assign ptab_base_b                = '0;
  assign ptab_a_len                 = '0;
  assign predict_next_fetch_address = fin.next;

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = ^{g0.ty, fin.slot, fin.ty, fin.rvc, fin.carried,
                       upd_pc, next_rf_blk, rf_diff};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
