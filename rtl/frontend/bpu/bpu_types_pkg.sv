// Ref: front-end/BPU/BpuFtb.h & BpuSc.h  (Single-Set 2-Ahead BPU: uFTB256 + FTB1 + 2-Way ExTAGE + 4-Tbl ITT)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */
package bpu_types_pkg;
  import ttg_cfg_pkg::*;
  import bpu_pkg::*;
  import bpu_stage_pkg::*;

  // ---- Geometry ----
  localparam int FTB_SLOTS     = 4;
  localparam int FTB_SLOT_W    = 2;
  localparam int FTB_TAG_W     = 10;
  localparam int FTB_MAX_TAG_W = 22;
  localparam int FTB_S0_SETS   = 64;   // 64 sets x 4 ways = 256 entries FF uFTB (20b compressed target)
  localparam int FTB_S0_WAYS   = 4;
  localparam int FTB_S0_TAG_W  = 12;
  localparam int FTB_S0_TGT_B  = 20;
  localparam int FTB_S1_SETS   = 1024; // 1024 sets x 4 ways = 2-Bank 512x4w (215b/way -> 24 x 512x72 macros)
  localparam int FTB_S1_WAYS   = 4;
  localparam int FTB_S1_TAG_W  = 14;
  localparam int EX_TAGE_N     = 4096;
  localparam int EX_TAGE_WAYS  = 2;
  localparam int EX_TAGE_SETS  = EX_TAGE_N / EX_TAGE_WAYS;  // 2048 sets x 2 ways (4-Bank 512x128b)
  localparam int EX_TAGE_IDX_W = $clog2(EX_TAGE_SETS);      // 11
  localparam int EX_TAGE_TAG_W = 11;
  localparam int EX_TAGE_URST  = 11;
  localparam int FTB_ITT_N     = 512;
  localparam int FTB_ITT_IDX_W = $clog2(FTB_ITT_N);         // 9
  localparam int FTB_BRQ_N     = 16;
  localparam int FTB_REC_N     = 512;
  localparam int FTB_REC_W     = 9;
  localparam int FTB_RF_REC_N  = 256;
  localparam int FTB_RF_REC_W  = 8;
  localparam int FTB_BLK_ID_W  = T_IDX_W;
  localparam logic [3:0] FTB_USE_ALT_INIT = 4'd7;
  localparam logic [3:0] FTB_USE_ALT_THR  = 4'd8;

  // ---- Packed structures ----
  typedef struct packed {
    logic valid; logic [3:0] offset; logic carried, is_rvc; logic [2:0] br_type;
    logic [1:0] ctr; logic [FTB_VA_BITS-1:0] target;
  } ftb_slot_t; // 50 bits

  typedef struct packed {
    logic valid; logic [FTB_MAX_TAG_W-1:0] tag; ftb_slot_t [FTB_SLOTS-1:0] s;
  } ftb_ent_t; // 223 bits

  typedef struct packed {
    logic valid; logic [3:0] offset; logic carried, is_rvc; logic [2:0] br_type;
    logic [1:0] ctr; logic [FTB_S0_TGT_B-1:0] tgt20;
  } uftb_slot_t; // 32 bits

  typedef struct packed {
    logic valid; logic [FTB_S0_TAG_W-1:0] tag; uftb_slot_t [FTB_SLOTS-1:0] s;
  } uftb_ent_t; // 141 bits

  typedef struct packed {
    logic [31:0] w;
    logic [EX_TN-1:0][EX_TAGE_IDX_W-1:0] idx;
    logic [EX_TN-1:0][EX_TAGE_TAG_W-1:0] tag;
  } ex_tage_ix_t;

  typedef struct packed {
    logic [EX_TN-1:0] sup_mask;
    logic [EX_TN-1:0][EX_TAGE_WAYS-1:0][EX_TAGE_TAG_W-1:0] tag;
    logic [EX_TN-1:0][EX_TAGE_WAYS-1:0][2:0] cnt;
    logic [EX_TN-1:0][EX_TAGE_WAYS-1:0][1:0] useful;
  } ex_tage_slot_raw_t;

  typedef ex_tage_slot_raw_t [FTB_SLOTS-1:0] ex_tage_raw_t;

  typedef struct packed {
    logic [NITT-1:0][FTB_ITT_IDX_W-1:0] idx;
    logic [NITT-1:0][FTB_TAG_W-1:0]     tag;
  } itt_ix_t;

  typedef struct packed {
    logic valid; logic [FTB_TAG_W-1:0] tag; logic [1:0] conf; logic u;
    logic [FTB_VA_BITS-1:0] target;
  } ftb_itt_ent_t; // 52 bits

  typedef ftb_itt_ent_t [NITT-1:0] ftb_itt_raw_t;
  typedef struct packed { logic hit; logic [XLEN_BITS-1:0] target; } ftb_itt_sel_t;

  typedef struct packed {
    logic [3:0] offset; logic carried, is_rvc; logic [2:0] br_type;
    logic actual_dir, pred_dir, alt_pred; logic [PCPN_W-1:0] pcpn; logic [XLEN_BITS-1:0] target;
  } ftb_br_upd_t;

  typedef struct packed { logic hit; logic [1:0] way; ftb_ent_t ent; } ftb1_lookup_meta_t;

  typedef struct packed {
    logic [3:0] pcpn; logic prov_way, pred, alt;
    logic [1:0] base_cnt; logic [2:0] prov_cnt; logic [1:0] prov_u;
    logic [EX_TN-1:0][EX_TAGE_WAYS-1:0][1:0] useful;
  } ex_tage_slot_meta_t;

  typedef ex_tage_slot_meta_t [FTB_SLOTS-1:0] ex_tage_meta_t;

  typedef struct packed {
    logic hit; logic [1:0] hit_k, conf; logic [NITT-1:0] valid_mask, u_mask;
    logic [FTB_VA_BITS-1:0] target;
  } itt_meta_t;

  typedef struct packed { ex_tage_meta_t ex_tage; itt_meta_t itt; } ah_pred_meta_t;
  typedef struct packed { ah_slot_tage_t st; ex_tage_slot_meta_t meta; } ah_tage_slot_sel_t;

  typedef struct packed {
    logic valid; logic [FTB_BLK_ID_W-1:0] id; logic [XLEN_BITS-1:0] base; ex_fh_t ex_fh;
    logic ah_v, ah_self0; logic [XLEN_BITS-1:0] ah_key_base, prev_base; ex_fh0_t ah_key_ex_fh;
    ftb1_lookup_meta_t ftb1_meta; ah_pred_meta_t ah_meta;
  } ftb_rec_t;

  typedef struct packed {
    logic valid; logic [FTB_BLK_ID_W-1:0] id; logic [EPOCH_W-1:0] epoch;
    logic [XLEN_BITS-1:0] base; ck_t ck;
  } bpu_rf_rec_t;

  typedef struct packed { ex_tage_raw_t ex_tage_raw; ftb_itt_raw_t itt_raw; } ftb_ah_raw_t;
  typedef struct packed {
    logic valid; logic [XLEN_BITS-1:0] key_base; ex_fh0_t key_ex_fh; ftb_ah_raw_t raw;
  } ftb_ah_pipe_t;
  typedef struct packed {
    ftb_ent_t ent; logic slot_found; logic [FTB_SLOT_W-1:0] slot_idx; logic [1:0] slot_ctr;
  } ftb_upsert_res_t;
  typedef struct packed { pred_t pred; logic [FTB_SLOTS-1:0] slot_tk; } ftb_eval_res_t;

  // ---- Pure helper functions ----
  function automatic logic ftb_br_ind(input logic [2:0] ty);
    return (ty == BR_IDIRECT) || (ty == BR_ICALL);
  endfunction

  function automatic logic ftb_br_call(input logic [2:0] ty);
    return (ty == BR_CALL) || (ty == BR_ICALL);
  endfunction

  function automatic logic ftb_s0_tgt_fits(input logic [XLEN_BITS-1:0] base,
                                           input logic [XLEN_BITS-1:0] target);
    logic [XLEN_BITS-1:0] mask;
    mask = ~((XLEN_BITS'(1) << (FTB_S0_TGT_B + SLOT_SHIFT)) - XLEN_BITS'(1));
    return (base & mask) == (target & mask);
  endfunction

  function automatic logic ftb_ent_payload_eq(input ftb_ent_t a, input ftb_ent_t b);
    return (a == b);
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic ex_tage_ix_t make_ah_ex_tage_index(input logic [XLEN_BITS-1:0] key_base,
                                                        input logic [XLEN_BITS-1:0] cur_base,
                                                        input ex_fh0_t key_ex_fh, input ex_fh_t tag_ex_fh,
                                                        input logic [XLEN_BITS-1:0] prev_base, input logic is_self0);
    ex_tage_ix_t ix;
    logic [31:0] wk, wc, sec, self_xor;
    wk       = 32'(key_base >> SLOT_SHIFT);
    wc       = 32'(cur_base >> SLOT_SHIFT);
    sec      = (!is_self0 && (prev_base != '0)) ? (32'(prev_base >> 1) ^ 32'(prev_base >> 7)) : 32'd0;
    self_xor = is_self0 ? 32'h555 : 32'd0;
    ix.w     = (wc != 32'd0) ? wc : wk;
    for (int t = 0; t < EX_TN; t++) begin
      ix.idx[t] = EX_TAGE_IDX_W'(wk ^ (wk >> 11) ^ 32'(key_ex_fh[t]));
      ix.tag[t] = EX_TAGE_TAG_W'(wc ^ (wc >> 11) ^ wk ^ 32'(tag_ex_fh[1][t]) ^
                                 (32'(tag_ex_fh[2][t]) << 1) ^ sec ^ self_xor);
    end
    return ix;
  endfunction

  function automatic itt_ix_t make_ah_itt_index(input logic [XLEN_BITS-1:0] key_base,
                                                input logic [XLEN_BITS-1:0] cur_base,
                                                input ex_fh0_t key_ex_fh, input ex_fh_t tag_ex_fh,
                                                input logic [XLEN_BITS-1:0] prev_base, input logic is_self0);
    itt_ix_t     ix;
    logic [31:0] wk, wc, sec, self_xor;
    wk       = 32'(key_base >> SLOT_SHIFT);
    wc       = 32'(cur_base >> SLOT_SHIFT);
    sec      = (!is_self0 && (prev_base != '0)) ? (32'(prev_base >> 1) ^ 32'(prev_base >> 7)) : 32'd0;
    self_xor = is_self0 ? 32'h2aa : 32'd0;
    for (int k = 0; k < NITT; k++) begin
      int e;
      e         = ITT_EX_MAP[k];
      ix.idx[k] = FTB_ITT_IDX_W'(wk ^ (wk >> 10) ^ 32'(key_ex_fh[e]));
      ix.tag[k] = FTB_TAG_W'(wc ^ (wc >> 10) ^ wk ^ 32'(tag_ex_fh[1][e]) ^
                             (32'(tag_ex_fh[2][e]) << 1) ^ sec ^ self_xor);
    end
    return ix;
  endfunction

  function automatic ah_tage_slot_sel_t ah_ex_tage_select_slot(input ex_tage_ix_t ix,
                                                               input ex_tage_slot_raw_t r,
                                                               input logic [15:0][3:0] use_alt_vec);
    ah_tage_slot_sel_t res;
    logic [EX_TN-1:0]  h0, h1, hit, p_oh, a_oh, t_way, t_ge4, t_ualt;
    logic [2:0]        t_cnt [EX_TN];
    logic [1:0]        t_u   [EX_TN];
    logic [3:0]        pcpn;
    logic [2:0]        prov_cnt_h;
    logic [1:0]        prov_u_h;
    logic              any_p, any_a, ua_le;

    res   = '0;
    ua_le = (use_alt_vec[ix.w[5:2]] <= FTB_USE_ALT_THR);
    for (int t = 0; t < EX_TN; t++) begin
      h0[t]     = !r.sup_mask[t] && (r.tag[t][0] == ix.tag[t]);
      h1[t]     = !r.sup_mask[t] && (r.tag[t][1] == ix.tag[t]);
      hit[t]    = h0[t] || h1[t];
      t_way[t]  = h0[t] ? 1'b0 : 1'b1;
      t_cnt[t]  = h0[t] ? r.cnt[t][0] : r.cnt[t][1];
      t_u[t]    = h0[t] ? r.useful[t][0] : r.useful[t][1];
      t_ge4[t]  = t_cnt[t][2];
      t_ualt[t] = ((t_cnt[t] == 3'd3) || (t_cnt[t] == 3'd4)) && (t_u[t] == 2'd0) && ua_le;
    end
    p_oh = '0; a_oh = '0;
    for (int t = 0; t < EX_TN; t++) begin
      logic any_hi, one_hi;
      any_hi = 1'b0; one_hi = 1'b0;
      for (int j = t + 1; j < EX_TN; j++) begin
        one_hi = (one_hi & ~hit[j]) | (~any_hi & hit[j]);
        any_hi = any_hi | hit[j];
      end
      p_oh[t] = hit[t] & ~any_hi;
      a_oh[t] = hit[t] & one_hi;
    end
    any_p = |hit; any_a = |a_oh; pcpn = 4'(EX_TN); prov_cnt_h = 3'd0; prov_u_h = 2'd0;
    for (int t = 0; t < EX_TN; t++) begin
      if (p_oh[t]) begin pcpn = 4'(t); prov_cnt_h = t_cnt[t]; prov_u_h = t_u[t]; end
    end
    res.st.pcpn = pcpn; res.st.prov_dir = any_p && (|(p_oh & t_ge4));
    res.st.alt_is_tagged = any_a; res.st.alt_dir = any_a && (|(a_oh & t_ge4));
    res.st.use_alt = any_p && (|(p_oh & t_ualt));
    res.meta.pcpn = pcpn; res.meta.prov_way = any_p ? (|(p_oh & t_way)) : 1'b0;
    res.meta.prov_cnt = prov_cnt_h; res.meta.prov_u = prov_u_h; res.meta.useful = r.useful;
    return res;
  endfunction

  function automatic logic [2:0] resolve_ah_dir(input ah_slot_tage_t ts, input logic [1:0] ftb_ctr);
    logic bp, alt_o, ualt_o, pred_o;
    bp = ftb_ctr[1];
    alt_o = ts.alt_is_tagged ? ts.alt_dir : bp;
    if (ts.pcpn >= 4'(EX_TN)) begin ualt_o = 1'b0; pred_o = bp; end
    else begin ualt_o = ts.use_alt; pred_o = ts.use_alt ? alt_o : ts.prov_dir; end
    return {ualt_o, alt_o, pred_o};
  endfunction

  function automatic ftb_itt_sel_t ftb_itt_select(input itt_ix_t ix, input ftb_itt_raw_t r);
    ftb_itt_sel_t res;
    res = '0;
    for (int k = 0; k < NITT; k++) begin
      if (r[k].valid && r[k].tag == ix.tag[k]) begin
        res.hit = 1'b1; res.target = sv39_unpack(r[k].target);
      end
    end
    return res;
  endfunction

  function automatic itt_meta_t ftb_itt_meta(input itt_ix_t ix, input ftb_itt_raw_t r);
    itt_meta_t m;
    m = '0;
    for (int k = 0; k < NITT; k++) begin
      m.valid_mask[k] = r[k].valid; m.u_mask[k] = r[k].u;
      if (r[k].valid && r[k].tag == ix.tag[k]) begin
        m.hit = 1'b1; m.hit_k = 2'(k); m.conf = r[k].conf; m.target = r[k].target;
      end
    end
    return m;
  endfunction

  function automatic ftb_eval_res_t ftb_eval_ent(input logic [XLEN_BITS-1:0] base,
                                                 input logic [XLEN_BITS-1:0] bnd,
                                                 input ftb_ent_t ent, input logic hit_in,
                                                 input logic use_dir_ovr, input logic [FTB_SLOTS-1:0] dir_ovr,
                                                 input logic itt_hit, input logic [XLEN_BITS-1:0] itt_tgt,
                                                 input logic ras_nonempty, input logic [XLEN_BITS-1:0] ras_top);
    ftb_eval_res_t res;
    logic [5:0] diff6; logic [4:0] nslots; logic [FTB_SLOTS-1:0] tk, win;
    logic found; ftb_slot_t sl; logic [XLEN_BITS-1:0] bpc, tgt;

    res = '0; res.pred.hit = hit_in; res.pred.next = bnd; res.pred.ty = BR_NONCTL;
    diff6 = bnd[5:0] - base[5:0]; nslots = (bnd != '0) ? 5'((diff6 + 6'd1) >> 1) : 5'd0;
    tk = '0; win = '0; sl = '0;
    if (hit_in) begin
      for (int k = 0; k < FTB_SLOTS; k++) begin
        if (ent.s[k].valid &&
            (((ent.s[k].offset == 4'd0) && ent.s[k].carried) ? ((bnd != '0) && (|base[XLEN_BITS-1:1]))
                                                              : ({1'b0, ent.s[k].offset} < nslots))) begin
          tk[k] = (ent.s[k].br_type == BR_DIRECT) ? (use_dir_ovr ? dir_ovr[k] : (ent.s[k].ctr >= 2'd2)) : 1'b1;
        end
      end
      res.slot_tk = tk;
      for (int k = 0; k < FTB_SLOTS; k++) begin
        win[k] = tk[k];
        for (int j = 0; j < FTB_SLOTS; j++) begin
          if (j < k)      win[k] = win[k] && (!tk[j] || (ent.s[k].offset <  ent.s[j].offset));
          else if (j > k) win[k] = win[k] && (!tk[j] || (ent.s[k].offset <= ent.s[j].offset));
        end
      end
      found = |win;
      if (found) begin
        for (int k = 0; k < FTB_SLOTS; k++) if (win[k]) sl = ent.s[k];
        bpc = (sl.offset == 4'd0 && sl.carried) ?
              (base - XLEN_BITS'(SLOT_BYTES)) : (base + (XLEN_BITS'(sl.offset) << SLOT_SHIFT));
        tgt = sv39_unpack(sl.target);
        if (sl.br_type == BR_RET && ras_nonempty)     tgt = ras_top;
        else if (ftb_br_ind(sl.br_type) && itt_hit)   tgt = itt_tgt;
        res.pred.taken = 1'b1; res.pred.slot = UB_SLOT_W'(sl.offset); res.pred.ty = sl.br_type;
        res.pred.rvc = sl.is_rvc; res.pred.carried = sl.carried; res.pred.next = tgt;
        res.pred.hbits = hsym_of(bpc, tgt);
        if (ftb_br_call(sl.br_type)) begin
          res.pred.ras_op = 2'd1; res.pred.ras_val = bpc + (sl.is_rvc ? XLEN_BITS'(2) : XLEN_BITS'(4));
        end else if (sl.br_type == BR_RET) res.pred.ras_op = 2'd2;
      end
    end
    return res;
  endfunction

  function automatic ftb_upsert_res_t ftb_upsert_branch(input ftb_ent_t ent, input ftb_br_upd_t b);
    ftb_upsert_res_t res;
    logic hit_found, free_found; logic [FTB_SLOT_W-1:0] hit_k, free_k, pos;
    logic [2:0] min_c; ftb_slot_t ns;

    res.ent = ent; res.slot_found = 1'b0; res.slot_idx = '0; res.slot_ctr = '0;
    hit_found = 1'b0; hit_k = '0; free_found = 1'b0; free_k = '0;
    for (int k = 0; k < FTB_SLOTS; k++) begin
      if (!hit_found && ent.s[k].valid && ent.s[k].offset == b.offset) begin
        hit_found = 1'b1; hit_k = FTB_SLOT_W'(k);
      end
      if (!free_found && !ent.s[k].valid) begin
        free_found = 1'b1; free_k = FTB_SLOT_W'(k);
      end
    end
    if (hit_found) begin
      ns = ent.s[hit_k]; ns.br_type = b.br_type; ns.carried = b.carried; ns.is_rvc = b.is_rvc;
      if (b.actual_dir) ns.target = sv39_pack(b.target);
      if (b.br_type == BR_DIRECT) begin
        if (b.actual_dir) ns.ctr = (ns.ctr < 2'd3) ? (ns.ctr + 2'd1) : 2'd3;
        else              ns.ctr = (ns.ctr > 2'd0) ? (ns.ctr - 2'd1) : 2'd0;
      end else ns.ctr = 2'd3;
      res.ent.s[hit_k] = ns; res.slot_found = 1'b1; res.slot_idx = hit_k; res.slot_ctr = ns.ctr;
    end else if (free_found || b.actual_dir || (b.br_type != BR_DIRECT)) begin
      pos = free_found ? free_k : FTB_SLOT_W'(FTB_SLOTS - 1);
      if (!free_found) begin
        min_c = 3'd7;
        for (int k = 0; k < FTB_SLOTS; k++) begin
          if (ent.s[k].br_type == BR_DIRECT && ({1'b0, ent.s[k].ctr} < min_c)) begin
            min_c = {1'b0, ent.s[k].ctr}; pos = FTB_SLOT_W'(k);
          end
        end
      end
      ns = '{valid: 1'b1, offset: b.offset, carried: b.carried, is_rvc: b.is_rvc, br_type: b.br_type,
             ctr: (b.br_type == BR_DIRECT) ? (b.actual_dir ? 2'd2 : 2'd1) : 2'd3, target: sv39_pack(b.target)};
      res.ent.s[pos] = ns; res.slot_found = 1'b1; res.slot_idx = pos; res.slot_ctr = ns.ctr;
    end
    return res;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

endpackage
/* verilator lint_on UNUSEDPARAM */

`default_nettype wire
