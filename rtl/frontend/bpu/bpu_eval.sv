// Ref: front-end/BPU/BPU_pipe.h  (Single-Set 2-Ahead BPU: S0 2-Ahead+uFTB, S2 MainFTB+self0)
`default_nettype none

module bpu_eval import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                    refetch,
  // S0 inputs
  input  logic [XLEN_BITS-1:0]    s0_base,
  input  logic [XLEN_BITS-1:0]    s0_bnd,
  input  ex_fh_t                  spec_ex_fh,
  input  logic [XLEN_BITS-1:0]    prev_base_q,
  input  logic                    s0_ras_nonempty,
  input  logic [XLEN_BITS-1:0]    s0_ras_top,
  input  ftb_ah_pipe_t            ah_a1_raw_q,
  input  logic                    ftb0_hit,
  input  ftb_ent_t                ftb0_ent,
  input  logic [15:0][3:0]        ah_use_alt,
  // S2 inputs (r1_q + Main FTB1 SRAM + self0 FF)
  /* verilator lint_off UNUSEDSIGNAL */
  input  blk_t                    r1_q,
  /* verilator lint_on UNUSEDSIGNAL */
  input  ah_pred_meta_t           r1_ah_meta_q,
  input  logic                    self0_v_q,
  input  ftb_ah_raw_t             self0_raw_q,
  input  logic                    s2_ftb_hit,
  input  logic [1:0]              s2_ftb_way,
  input  ftb_ent_t                s2_ftb_ent,
  input  logic [FTB_BLK_ID_W-1:0] blk_seq_q,
  // S0 outputs
  output logic                    ah_src_v,
  output logic                    ah_hit,
  output ah_dir_itt_t             s0_ah_dir_itt,
  output pred_t                   g0,
  output ah_pred_meta_t           s0_ah_meta,
  // S2 outputs
  output pred_t                   fin,
  output logic                    fin_diff,
  output logic                    s2_ah_self0,
  output ftb1_lookup_meta_t       s2_ftb1_meta,
  output ah_pred_meta_t           s2_ah_meta,
  output logic [NLANE-1:0]        out_pred_dir,
  output logic [NLANE-1:0]        out_alt_pred,
  output logic [PCPN_W-1:0]       out_pcpn      [NLANE],
  output logic [FTB_BLK_ID_W-1:0] out_blk_id
);

  // ---- S0: 2-Ahead FF select (with current H_t & MORSL prev_base) + uFTB ----
  logic [FTB_SLOTS-1:0] s0_dirs;
  ftb_eval_res_t        u0_eval;

  always_comb begin
    ex_tage_ix_t       s0_ex_ix;
    itt_ix_t           s0_itt_ix;
    ah_tage_slot_sel_t sl_sel;
    ftb_itt_sel_t      s0_itt;

    ah_src_v  = !refetch && ah_a1_raw_q.valid;
    s0_ex_ix  = make_ah_ex_tage_index(ah_a1_raw_q.key_base, s0_base, ah_a1_raw_q.key_ex_fh,
                                      spec_ex_fh, prev_base_q, 1'b0);
    s0_itt_ix = make_ah_itt_index(ah_a1_raw_q.key_base, s0_base, ah_a1_raw_q.key_ex_fh,
                                  spec_ex_fh, prev_base_q, 1'b0);

    sl_sel        = '0;
    s0_itt        = '0;
    s0_ah_dir_itt = '0;
    s0_ah_meta    = '0;
    for (int k = 0; k < FTB_SLOTS; k++) begin
      s0_ah_dir_itt.s[k].pcpn     = 4'(EX_TN);
      s0_ah_meta.ex_tage[k].pcpn  = 4'(EX_TN);
    end

    if (ah_src_v) begin
      s0_ah_dir_itt.valid = 1'b1;
      for (int k = 0; k < FTB_SLOTS; k++) begin
        sl_sel                 = ah_ex_tage_select_slot(s0_ex_ix, ah_a1_raw_q.raw.ex_tage_raw[k], ah_use_alt);
        s0_ah_dir_itt.s[k]     = sl_sel.st;
        s0_ah_meta.ex_tage[k]  = sl_sel.meta;
      end
      s0_itt                = ftb_itt_select(s0_itt_ix, ah_a1_raw_q.raw.itt_raw);
      s0_ah_dir_itt.itt_hit = s0_itt.hit;
      s0_ah_dir_itt.itt_tgt = sv39_pack(s0_itt.target);
      s0_ah_meta.itt        = ftb_itt_meta(s0_itt_ix, ah_a1_raw_q.raw.itt_raw);
    end
  end

  logic [FTB_SLOTS-1:0][2:0] s0_r3;
  always_comb begin
    for (int k = 0; k < FTB_SLOTS; k++) begin
      s0_r3[k]   = resolve_ah_dir(s0_ah_dir_itt.s[k], ftb0_ent.s[k].ctr);
      s0_dirs[k] = ah_src_v ? s0_r3[k][0] : ftb0_ent.s[k].ctr[1];
    end
    u0_eval = ftb_eval_ent(s0_base, s0_bnd, ftb0_ent, ftb0_hit, 1'b1, s0_dirs,
                           ah_src_v && s0_ah_dir_itt.itt_hit, sv39_unpack(s0_ah_dir_itt.itt_tgt),
                           s0_ras_nonempty, s0_ras_top);
    g0      = u0_eval.pred;
    ah_hit  = g0.hit && ah_src_v;
  end

  // ---- S2 Stage 1: self0 A0-reuse eval IN PARALLEL with u_ftb1 SRAM read ----
  logic          eff_ah_v;
  ah_dir_itt_t   eff_di;
  ah_pred_meta_t base_ah_meta;

  always_comb begin
    ex_tage_ix_t       s0_rf_ex_ix;
    itt_ix_t           s0_rf_itt_ix;
    ah_dir_itt_t       self0_di;
    ah_pred_meta_t     self0_meta;
    ah_tage_slot_sel_t sl_sel;
    ftb_itt_sel_t      self0_itt;

    s2_ah_self0  = !r1_q.ah_v && self0_v_q;
    s0_rf_ex_ix  = make_ah_ex_tage_index(r1_q.base, r1_q.base, r1_q.ck.h.ex_fh, r1_q.ck.h.ex_fh, '0, 1'b1);
    s0_rf_itt_ix = make_ah_itt_index(r1_q.base, r1_q.base, r1_q.ck.h.ex_fh, r1_q.ck.h.ex_fh, '0, 1'b1);

    sl_sel     = '0;
    self0_itt  = '0;
    self0_di   = '0;
    self0_meta = '0;
    for (int k = 0; k < FTB_SLOTS; k++) begin
      self0_di.s[k].pcpn         = 4'(EX_TN);
      self0_meta.ex_tage[k].pcpn = 4'(EX_TN);
    end
    if (s2_ah_self0) begin
      self0_di.valid = 1'b1;
      for (int k = 0; k < FTB_SLOTS; k++) begin
        sl_sel                = ah_ex_tage_select_slot(s0_rf_ex_ix, self0_raw_q.ex_tage_raw[k], ah_use_alt);
        self0_di.s[k]         = sl_sel.st;
        self0_meta.ex_tage[k] = sl_sel.meta;
      end
      self0_itt        = ftb_itt_select(s0_rf_itt_ix, self0_raw_q.itt_raw);
      self0_di.itt_hit = self0_itt.hit;
      self0_di.itt_tgt = sv39_pack(self0_itt.target);
      self0_meta.itt   = ftb_itt_meta(s0_rf_itt_ix, self0_raw_q.itt_raw);
    end

    eff_ah_v     = r1_q.ah_v || s2_ah_self0;
    eff_di       = s2_ah_self0 ? self0_di : r1_q.ah_dir_itt;
    base_ah_meta = s2_ah_self0 ? self0_meta : r1_ah_meta_q;
  end

  // ---- S2 Stage 2: Parallel slot pre-evaluation ----
  logic [XLEN_BITS-1:0] s2_bnd;
  logic [4:0]           s2_nslots;
  logic [FTB_SLOTS-1:0] s2_in_rng, s2_diff_slot;
  logic                 s2_diff_ft, s2_itt_hit;
  pred_t                s2_ft_pred;
  pred_t                s2_slot_pred [FTB_SLOTS];

  always_comb begin
    logic [5:0]           s2_diff6;
    logic [XLEN_BITS-1:0] s2_itt_tgt;
    logic                 s2_ras_ne;

    s2_bnd     = block_bnd(r1_q.base);
    s2_diff6   = s2_bnd[5:0] - r1_q.base[5:0];
    s2_nslots  = (s2_bnd != '0) ? 5'((s2_diff6 + 6'd1) >> 1) : 5'd0;
    s2_ras_ne  = (r1_q.ck.r.cnt != '0);
    s2_itt_hit = eff_ah_v && eff_di.itt_hit;
    s2_itt_tgt = sv39_unpack(eff_di.itt_tgt);

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
      if (sk.br_type == BR_RET && s2_ras_ne)       tgt_k = r1_q.ck.r.top;
      else if (ftb_br_ind(sk.br_type) && s2_itt_hit) tgt_k = s2_itt_tgt;
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
      end else if (sk.br_type == BR_RET) s2_slot_pred[k].ras_op = 2'd2;
      s2_diff_slot[k] = pred_differs(s2_slot_pred[k], r1_q.g);
    end
  end

  // ---- S2 Stage 3: ctr dir resolve, winner select, metadata & PTAB output ----
  logic [FTB_SLOTS-1:0]      s2_slot_tk;
  logic [FTB_SLOTS-1:0][2:0] s2_r3;

  always_comb begin
    logic [FTB_SLOTS-1:0] s2_dirs, s2_win, s2_alt;
    logic                 s2_found;

    s2_ftb1_meta = '{hit: s2_ftb_hit, way: s2_ftb_way, ent: s2_ftb_hit ? s2_ftb_ent : '0};
    s2_ah_meta   = base_ah_meta;
    s2_dirs      = '0; s2_alt = '0; s2_slot_tk = '0; s2_win = '0;
    for (int k = 0; k < FTB_SLOTS; k++) s2_r3[k] = '0;
    if (s2_ftb_hit) begin
      for (int k = 0; k < FTB_SLOTS; k++) begin
        s2_r3[k]   = resolve_ah_dir(eff_di.s[k], s2_ftb_ent.s[k].ctr);
        s2_dirs[k] = eff_ah_v ? s2_r3[k][0] : s2_ftb_ent.s[k].ctr[1];
        s2_alt[k]  = eff_ah_v ? s2_r3[k][1] : s2_ftb_ent.s[k].ctr[1];
        s2_ah_meta.ex_tage[k].base_cnt = s2_ftb_ent.s[k].ctr;
        s2_ah_meta.ex_tage[k].alt      = s2_alt[k];
        s2_ah_meta.ex_tage[k].pred     = s2_dirs[k];
        if (s2_ah_meta.ex_tage[k].pcpn >= 4'(EX_TN))
          s2_ah_meta.ex_tage[k].prov_cnt = {1'b0, s2_ftb_ent.s[k].ctr};
        s2_slot_tk[k] = s2_in_rng[k] && ((s2_ftb_ent.s[k].br_type == BR_DIRECT) ? s2_dirs[k] : 1'b1);
      end
      for (int k = 0; k < FTB_SLOTS; k++) begin
        s2_win[k] = s2_slot_tk[k];
        for (int j = 0; j < FTB_SLOTS; j++) begin
          if (j < k)
            s2_win[k] = s2_win[k] && (!s2_slot_tk[j] || (s2_ftb_ent.s[k].offset <  s2_ftb_ent.s[j].offset));
          else if (j > k)
            s2_win[k] = s2_win[k] && (!s2_slot_tk[j] || (s2_ftb_ent.s[k].offset <= s2_ftb_ent.s[j].offset));
        end
      end
    end
    s2_found = |s2_win;
    fin_diff = (|(s2_win & s2_diff_slot)) || (!s2_found && s2_diff_ft);
    fin      = s2_ft_pred;
    for (int k = 0; k < FTB_SLOTS; k++) if (s2_win[k]) fin = s2_slot_pred[k];

    out_pred_dir = '0; out_alt_pred = '0; out_blk_id = blk_seq_q;
    for (int i = 0; i < NLANE; i++) out_pcpn[i] = PCPN_W'(TN);
    if (s2_ftb_hit) begin
      for (int k = 0; k < FTB_SLOTS; k++) begin
        if (s2_ftb_ent.s[k].valid && ({1'b0, s2_ftb_ent.s[k].offset} < s2_nslots)) begin
          out_pred_dir[s2_ftb_ent.s[k].offset] = s2_slot_tk[k];
          out_alt_pred[s2_ftb_ent.s[k].offset] = s2_alt[k];
          out_pcpn[s2_ftb_ent.s[k].offset]     = (eff_ah_v && (eff_di.s[k].pcpn < 4'(EX_TN)))
              ? ((eff_di.s[k].pcpn >= 4'(TN)) ? PCPN_W'(TN - 1) : PCPN_W'(eff_di.s[k].pcpn))
              : PCPN_W'(TN);
        end
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = ^{u0_eval.slot_tk, eff_di.valid, s0_r3, s2_r3};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
`default_nettype wire
