// Ref: front-end/BPU/BpuFtb.h  (block-based 1-ahead FTB BPU types and pure functions, EXP-050)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */
package bpu_types_pkg;
  import ttg_cfg_pkg::*;
  import bpu_pkg::*;
  import bpu_stage_pkg::*;

  // ---- Target ah1_4k_a2k1k + FTB_BRQ=2 geometry ----
  localparam int FTB_SLOTS     = 4;
  localparam int FTB_SLOT_W    = 2;
  localparam int FTB_TAG_W     = 10;
  localparam int FTB_MAX_TAG_W = 22;

  localparam int FTB_S0_SETS   = 64;
  localparam int FTB_S0_WAYS   = 4;
  localparam int FTB_S0_TAG_W  = 12;
  localparam int FTB_S0_TGT_B  = 20;

  localparam int FTB_S1_SETS   = 1024;
  localparam int FTB_S1_WAYS   = 4;
  localparam int FTB_S1_TAG_W  = 14;

  localparam int FTB_AH_SETS    = 256;
  localparam int FTB_AH_WAYS    = 8;
  localparam int FTB_AH_TAG_W   = 22;

  localparam int FTB_AH2_SETS   = 128;
  localparam int FTB_AH2_WAYS   = 8;
  localparam int FTB_AH2_TAGE_N = 512;

  localparam int FTB_S2_TAGE_N  = 4096;
  localparam int EX_TAGE_N      = 4096;
  localparam int EX_TAGE_TAG_W  = 11;
  localparam int EX_TAGE_URST   = 11;
  localparam int SC_BIAS_SETS   = 64;
  localparam int SC_GEHL_N_ENT  = 512;
  localparam int SC_IMLI_N      = 256;
  localparam int SC_LOC_N       = 256;
  localparam int SC_LHT_N       = 64;
  localparam int FTB_AH_TAGE_N  = 1024;
  localparam int FTB_ITT_N      = 256;

  localparam int FTB_BRQ_N      = 16;
  localparam int FTB_REC_N      = 512;
  localparam int FTB_REC_W      = 9;
  localparam int FTB_RF_REC_N   = 256;
  localparam int FTB_RF_REC_W   = 8;
  localparam int FTB_BLK_ID_W   = T_IDX_W;   // 10-bit blk_id carried via out_tage_idxs[i][0]

  localparam logic [3:0] FTB_USE_ALT_INIT = 4'd7;
  localparam logic [3:0] FTB_USE_ALT_THR  = 4'd8;
  localparam int         FTB_URST_BITS    = 11;

  // ---- Packed structures ----
  typedef struct packed {
    logic                 valid;
    logic [3:0]           offset;
    logic                 carried;
    logic                 is_rvc;
    logic [2:0]           br_type;
    logic [1:0]           ctr;
    logic [XLEN_BITS-1:0] target;
  } ftb_slot_t;

  typedef struct packed {
    logic                     valid;
    logic [FTB_MAX_TAG_W-1:0] tag;
    logic [2:0]               lru;
    ftb_slot_t [FTB_SLOTS-1:0] s;
  } ftb_ent_t;

  typedef struct packed {
    logic [31:0]                     base_idx;
    logic [TN-1:0][31:0]             idx;
    logic [TN-1:0][FTB_TAG_W-1:0]    tag;
  } ftb_ix_t;

  typedef struct packed {
    logic [1:0]                      base_cnt;
    logic [TN-1:0][FTB_TAG_W-1:0]    tag;
    logic [TN-1:0][2:0]              cnt;
    logic [TN-1:0][1:0]              useful;
  } ftb_tage_slot_raw_t;

  typedef ftb_tage_slot_raw_t [FTB_SLOTS-1:0] ftb_tage_raw_t;

  typedef struct packed {
    logic              pred;
    logic              alt;
    logic [PCPN_W-1:0] pcpn;
    logic              used_alt;
  } ftb_tage_pred_t;

  // ---- Batch 2: S2 8-table ExBlockTage + S2 StatCorrector types ----
  typedef struct packed {
    logic [31:0]                            w;
    logic [11:0]                            base_idx;
    logic [EX_TN-1:0][11:0]                 idx;
    logic [EX_TN-1:0][EX_TAGE_TAG_W-1:0]    tag;
  } ex_tage_ix_t;

  typedef struct packed {
    logic [1:0]                             base_cnt;
    logic [EX_TN-1:0][EX_TAGE_TAG_W-1:0]    tag;
    logic [EX_TN-1:0][2:0]                  cnt;
    logic [EX_TN-1:0][1:0]                  useful;
  } ex_tage_slot_raw_t;

  typedef ex_tage_slot_raw_t [FTB_SLOTS-1:0] ex_tage_raw_t;

  typedef struct packed {
    logic       pred;
    logic       alt;
    logic [3:0] pcpn;
    logic       used_alt;
    logic [2:0] prov_cnt;
    logic [1:0] base_cnt;
  } ex_tage_pred_t;

  typedef struct packed {
    logic [31:0]                  w;
    logic [5:0]                   bias_set;
    logic [SC_GEHL_N-1:0][8:0]    gehl_idx;
    logic [7:0]                   imli_idx;
    logic [5:0]                   lht_idx;
  } sc_ix_t;

  typedef struct packed {
    logic signed [3:0][5:0]             bias;
    logic signed [SC_GEHL_N-1:0][5:0]   gehl;
    logic signed [5:0]                  imli;
    logic signed [5:0]                  loc;
  } sc_slot_raw_t;

  typedef sc_slot_raw_t [FTB_SLOTS-1:0] sc_raw_t;

  typedef struct packed {
    logic                 valid;
    logic [FTB_TAG_W-1:0] tag;
    logic [1:0]           conf;
    logic                 u;
    logic [XLEN_BITS-1:0] target;
  } ftb_itt_ent_t;

  typedef ftb_itt_ent_t [NITT-1:0] ftb_itt_raw_t;

  typedef struct packed {
    logic                 hit;
    logic [XLEN_BITS-1:0] target;
  } ftb_itt_sel_t;

  typedef struct packed {
    logic [3:0]           offset;
    logic                 carried;
    logic                 is_rvc;
    logic [2:0]           br_type;
    logic                 actual_dir;
    logic                 pred_dir;
    logic                 alt_pred;
    logic [PCPN_W-1:0]    pcpn;
    logic [XLEN_BITS-1:0] target;
  } ftb_br_upd_t;

  typedef struct packed {
    logic                    valid;
    logic [FTB_BLK_ID_W-1:0] id;
    logic [XLEN_BITS-1:0]    base;
    fh_t                     fh;
    ex_fh_t                  ex_fh;
    sc_fh_t                  sc_fh;
    logic [7:0]              imli;
    logic                    ah_v;
    logic                    ah_kind; // 0 = 1-ahead A (aftb), 1 = 2-ahead B (aftb2)
    logic [XLEN_BITS-1:0]    ah_key_base;
    logic [XLEN_BITS-1:0]    ah_a_base;
    fh_t                     ah_key_fh;
  } ftb_rec_t;

  // Prediction-time repair record for back-end branch mispredict (matches BpuPipe::rec_[256])
  typedef struct packed {
    logic                    valid;
    logic [FTB_BLK_ID_W-1:0] id;
    logic [EPOCH_W-1:0]      epoch;
    logic [XLEN_BITS-1:0]    base;
    ck_t                     ck;
  } bpu_rf_rec_t;

  typedef struct packed {
    ftb_ent_t [FTB_AH_WAYS-1:0]             ftb_ways;
    logic [FTB_AH_WAYS-1:0][XLEN_BITS-1:0]  b_base;
    ftb_tage_raw_t                          tage_raw;
    ftb_itt_raw_t                           itt_raw;
  } ftb_ah_raw_t;

  typedef struct packed {
    logic                 valid;
    logic [XLEN_BITS-1:0] key_base;
    fh_t                  key_fh;
    ftb_ah_raw_t          raw;
  } ftb_ah_pipe_t;

  typedef struct packed {
    logic         ftb_hit;
    ftb_ent_t     ent;
    ex_tage_raw_t s2_tage_raw;
    sc_raw_t      s2_sc_raw;
    ftb_itt_raw_t itt_raw;
  } ftb_s1_raw_t;

  typedef struct packed {
    ftb_ent_t              ent;
    logic                  slot_found;
    logic [FTB_SLOT_W-1:0] slot_idx;
    logic [1:0]            slot_ctr;
  } ftb_upsert_res_t;

  typedef struct packed {
    pred_t                 pred;
    logic [FTB_SLOTS-1:0]  slot_tk;
  } ftb_eval_res_t;

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

  function automatic logic [FTB_AH_TAG_W-1:0] ftb_ah_tag(input logic [XLEN_BITS-1:0] key_base,
                                                         input logic [XLEN_BITS-1:0] cur_base,
                                                         input int set_bits = $clog2(FTB_AH_SETS));
    logic [31:0] wk, wc, tk, tc;
    wk = 32'(key_base >> SLOT_SHIFT);
    wc = 32'(cur_base >> SLOT_SHIFT);
    tk = (wk >> set_bits) & 32'h3ff;
    tc = (wc ^ (wc >> 12)) & 32'hfff;
    return FTB_AH_TAG_W'((tk << 12) | tc);
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic ftb_ix_t ftb_make_index(input logic [XLEN_BITS-1:0] base, input fh_t fh);
    ftb_ix_t ix;
    logic [31:0] w;
    w = 32'(base >> SLOT_SHIFT);
    ix.base_idx = w ^ (w >> 11);
    for (int t = 0; t < TN; t++) begin
      ix.idx[t] = w ^ (w >> 10) ^ 32'(fh[0][t]) ^ ((32'(fh[1][t]) & 32'h7) << 9);
      ix.tag[t] = FTB_TAG_W'(w ^ (w >> 10) ^ 32'(fh[1][t]) ^ (32'(fh[2][t]) << 2));
    end
    return ix;
  endfunction

  function automatic ftb_ix_t ftb_make_ah_index(input logic [XLEN_BITS-1:0] key_base,
                                                input logic [XLEN_BITS-1:0] cur_base,
                                                input fh_t fh);
    ftb_ix_t ix;
    logic [31:0] wk, wc;
    wk = 32'(key_base >> SLOT_SHIFT);
    wc = 32'(cur_base >> SLOT_SHIFT);
    ix.base_idx = wk ^ (wk >> 11);
    for (int t = 0; t < TN; t++) begin
      ix.idx[t] = wk ^ (wk >> 10) ^ 32'(fh[0][t]) ^ ((32'(fh[1][t]) & 32'h7) << 9);
      ix.tag[t] = FTB_TAG_W'(wc ^ (wc >> 10) ^ wk ^ 32'(fh[1][t]) ^ (32'(fh[2][t]) << 2));
    end
    return ix;
  endfunction

  function automatic ftb_tage_pred_t ftb_tage_select(input ftb_ix_t ix,
                                                     input ftb_tage_slot_raw_t r,
                                                     input logic use_base_ovr,
                                                     input logic [1:0] base_ovr,
                                                     input logic prefer_alt);
    ftb_tage_pred_t o;
    logic [PCPN_W-1:0] pcpn, altpcpn;
    logic bp, pp, is_weak, ulow;
    pcpn    = PCPN_W'(TN);
    altpcpn = PCPN_W'(TN);
    for (int t = 0; t < TN; t++) begin
      if (r.tag[t] == ix.tag[t]) begin
        altpcpn = pcpn;
        pcpn    = PCPN_W'(t);
      end
    end
    bp         = use_base_ovr ? (base_ovr >= 2'd2) : (r.base_cnt >= 2'd2);
    o.pcpn     = pcpn;
    o.alt      = (altpcpn == PCPN_W'(TN)) ? bp : (r.cnt[altpcpn[1:0]] >= 3'd4);
    pp         = (pcpn == PCPN_W'(TN)) ? bp : (r.cnt[pcpn[1:0]] >= 3'd4);
    is_weak    = (pcpn != PCPN_W'(TN)) && (r.cnt[pcpn[1:0]] == 3'd3);
    ulow       = (pcpn != PCPN_W'(TN)) && (r.useful[pcpn[1:0]] == 2'd0);
    o.used_alt = (pcpn != PCPN_W'(TN)) && is_weak && ulow && prefer_alt;
    o.pred     = o.used_alt ? o.alt : pp;
    return o;
  endfunction

  function automatic ex_tage_ix_t ftb_make_ex_tage_index(input logic [XLEN_BITS-1:0] base, input ex_fh_t ex_fh);
    ex_tage_ix_t ix;
    logic [31:0] w;
    w           = 32'(base >> SLOT_SHIFT);
    ix.w        = w;
    ix.base_idx = 12'(w ^ (w >> 12));
    for (int t = 0; t < EX_TN; t++) begin
      ix.idx[t] = 12'(w ^ (w >> 11) ^ 32'(ex_fh[0][t]));
      ix.tag[t] = EX_TAGE_TAG_W'(w ^ (w >> 11) ^ 32'(ex_fh[1][t]) ^ (32'(ex_fh[2][t]) << 1));
    end
    return ix;
  endfunction

  function automatic sc_ix_t ftb_make_sc_index(input logic [XLEN_BITS-1:0] base, input sc_fh_t sc_fh,
                                               input logic [7:0] imli);
    sc_ix_t ix;
    logic [31:0] w;
    w           = 32'(base >> SLOT_SHIFT);
    ix.w        = w;
    ix.bias_set = w[5:0];
    for (int g = 0; g < SC_GEHL_N; g++) begin
      ix.gehl_idx[g] = 9'(w ^ (w >> 9) ^ 32'(sc_fh[g]));
    end
    ix.imli_idx = 8'(w ^ (32'(imli) * 32'd13));
    ix.lht_idx  = w[5:0];
    return ix;
  endfunction

  function automatic ex_tage_pred_t ex_tage_select(input ex_tage_ix_t ix,
                                                   input ex_tage_slot_raw_t r,
                                                   input logic [15:0][3:0] use_alt_vec);
    ex_tage_pred_t o;
    logic [3:0] pcpn, altpcpn, ua;
    logic bp, pp, is_weak, ulow;
    pcpn    = 4'(EX_TN);
    altpcpn = 4'(EX_TN);
    for (int t = 0; t < EX_TN; t++) begin
      if (r.tag[t] == ix.tag[t]) begin
        altpcpn = pcpn;
        pcpn    = 4'(t);
      end
    end
    o.base_cnt = r.base_cnt;
    bp         = (r.base_cnt >= 2'd2);
    o.pcpn     = pcpn;
    o.alt      = (altpcpn == 4'(EX_TN)) ? bp : (r.cnt[altpcpn[2:0]] >= 3'd4);
    o.prov_cnt = (pcpn == 4'(EX_TN)) ? {1'b0, r.base_cnt} : r.cnt[pcpn[2:0]];
    pp         = (pcpn == 4'(EX_TN)) ? bp : (o.prov_cnt >= 3'd4);
    is_weak    = (pcpn != 4'(EX_TN)) && ((o.prov_cnt == 3'd3) || (o.prov_cnt == 3'd4));
    ulow       = (pcpn != 4'(EX_TN)) && (r.useful[pcpn[2:0]] == 2'd0);
    ua         = use_alt_vec[ix.w[5:2]];
    o.used_alt = (pcpn != 4'(EX_TN)) && is_weak && ulow && (ua <= FTB_USE_ALT_THR);
    o.pred     = o.used_alt ? o.alt : pp;
    return o;
  endfunction

  function automatic logic signed [10:0] sc_eval_raw(input sc_slot_raw_t r,
                                                     input logic tage_pred,
                                                     input logic prov_hit,
                                                     input logic [2:0] prov_cnt,
                                                     input logic [1:0] base_cnt);
    logic signed [10:0] tage_w, s;
    logic               low_conf;
    logic [1:0]         bway;
    tage_w   = prov_hit ? (11'sd2 * ($signed({8'b0, prov_cnt}) * 11'sd2 - 11'sd7))
                        : (11'sd2 * ($signed({9'b0, base_cnt}) * 11'sd2 - 11'sd3));
    low_conf = prov_hit ? ((prov_cnt == 3'd3) || (prov_cnt == 3'd4))
                        : ((base_cnt == 2'd1) || (base_cnt == 2'd2));
    bway     = {tage_pred, low_conf};
    s        = tage_w + ($signed({{4{r.bias[bway][5]}}, r.bias[bway], 1'b0}) + 11'sd1);
    for (int g = 0; g < SC_GEHL_N; g++) begin
      s = s + ($signed({{4{r.gehl[g][5]}}, r.gehl[g], 1'b0}) + 11'sd1);
    end
    s = s + ($signed({{4{r.imli[5]}}, r.imli, 1'b0}) + 11'sd1);
    s = s + ($signed({{4{r.loc[5]}},  r.loc,  1'b0}) + 11'sd1);
    return s;
  endfunction

  function automatic logic sc_select_slot(input logic [31:0] w,
                                          input sc_slot_raw_t r,
                                          input logic tage_pred,
                                          input logic prov_hit,
                                          input logic [2:0] prov_cnt,
                                          input logic [1:0] base_cnt,
                                          input logic [15:0][5:0] thres_vec);
    logic signed [10:0] lsum, abs_sum, th;
    logic               sc_pred;
    lsum    = sc_eval_raw(r, tage_pred, prov_hit, prov_cnt, base_cnt);
    abs_sum = (lsum < 11'sd0) ? -lsum : lsum;
    sc_pred = (lsum >= 11'sd0);
    th      = $signed({5'b0, thres_vec[w[5:2]]});
    if ((sc_pred != tage_pred) && (abs_sum >= th)) return sc_pred;
    return tage_pred;
  endfunction

  function automatic ftb_itt_sel_t ftb_itt_select(input ftb_ix_t ix, input ftb_itt_raw_t r);
    ftb_itt_sel_t res;
    res = '0;
    for (int k = 0; k < NITT; k++) begin
      if (r[k].valid && r[k].tag == ix.tag[ITT_TBL[k]]) begin
        res.hit    = 1'b1;
        res.target = r[k].target;
      end
    end
    return res;
  endfunction

  function automatic ftb_eval_res_t ftb_eval_ent(input logic [XLEN_BITS-1:0] base,
                                                 input logic [XLEN_BITS-1:0] bnd,
                                                 input ftb_ent_t ent,
                                                 input logic hit_in,
                                                 input logic use_dir_ovr,
                                                 input logic [FTB_SLOTS-1:0] dir_ovr,
                                                 input logic itt_hit,
                                                 input logic [XLEN_BITS-1:0] itt_tgt,
                                                 input logic ras_nonempty,
                                                 input logic [XLEN_BITS-1:0] ras_top);
    ftb_eval_res_t res;
    logic [5:0]            diff6;
    logic [4:0]            nslots;
    logic [FTB_SLOTS-1:0]  tk, win;
    logic                  found;
    ftb_slot_t             sl;
    logic [XLEN_BITS-1:0]  bpc, tgt;

    res           = '0;
    res.pred.hit  = hit_in;
    res.pred.next = bnd;
    res.pred.ty   = BR_NONCTL;

    // Exact match to (bpc < bnd) without per-slot 64-bit adders:
    //   - bnd == 0 means 64-bit wraparound (no unsigned bpc < 0);
    //   - normal slot k (base + 2*k < bnd) <=> 2*k < diff6 <=> k < ceil(diff6 / 2) = (diff6 + 1) >> 1;
    //   - carried slot 0 (base - 2 < bnd) <=> bnd != 0 && base >= 2 (no underflow).
    diff6  = bnd[5:0] - base[5:0];
    nslots = (bnd != '0) ? 5'((diff6 + 6'd1) >> 1) : 5'd0;
    tk     = '0;
    win    = '0;
    sl     = '0;

    if (hit_in) begin
      for (int k = 0; k < FTB_SLOTS; k++) begin
        if (ent.s[k].valid &&
            (((ent.s[k].offset == 4'd0) && ent.s[k].carried) ? ((bnd != '0) && (|base[XLEN_BITS-1:1]))
                                                              : ({1'b0, ent.s[k].offset} < nslots))) begin
          tk[k] = (ent.s[k].br_type == BR_DIRECT) ? (use_dir_ovr ? dir_ovr[k] : (ent.s[k].ctr >= 2'd2)) : 1'b1;
        end
      end
      res.slot_tk = tk;

      // Parallel 4-way pairwise min-offset tournament (lowest index breaks ties)
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
              (base - XLEN_BITS'(SLOT_BYTES)) :
              (base + (XLEN_BITS'(sl.offset) << SLOT_SHIFT));
        tgt = sl.target;
        if (sl.br_type == BR_RET && ras_nonempty)     tgt = ras_top;
        else if (ftb_br_ind(sl.br_type) && itt_hit)   tgt = itt_tgt;
        res.pred.taken   = 1'b1;
        res.pred.slot    = UB_SLOT_W'(sl.offset);
        res.pred.ty      = sl.br_type;
        res.pred.rvc     = sl.is_rvc;
        res.pred.carried = sl.carried;
        res.pred.next    = tgt;
        res.pred.hbits   = hsym_of(bpc, tgt);
        if (ftb_br_call(sl.br_type)) begin
          res.pred.ras_op  = 2'd1;
          res.pred.ras_val = bpc + (sl.is_rvc ? XLEN_BITS'(2) : XLEN_BITS'(4));
        end else if (sl.br_type == BR_RET) begin
          res.pred.ras_op  = 2'd2;
        end
      end
    end
    return res;
  endfunction

  function automatic ftb_upsert_res_t ftb_upsert_branch(input ftb_ent_t ent, input ftb_br_upd_t b);
    ftb_upsert_res_t res;
    logic                  hit_found, free_found;
    logic [FTB_SLOT_W-1:0] hit_k, free_k, pos;
    logic [2:0]            min_c;
    ftb_slot_t             ns;

    res.ent        = ent;
    res.slot_found = 1'b0;
    res.slot_idx   = '0;
    res.slot_ctr   = '0;
    hit_found      = 1'b0;
    hit_k          = '0;
    free_found     = 1'b0;
    free_k         = '0;

    for (int k = 0; k < FTB_SLOTS; k++) begin
      if (!hit_found && ent.s[k].valid && ent.s[k].offset == b.offset) begin
        hit_found = 1'b1;
        hit_k     = FTB_SLOT_W'(k);
      end
      if (!free_found && !ent.s[k].valid) begin
        free_found = 1'b1;
        free_k     = FTB_SLOT_W'(k);
      end
    end

    if (hit_found) begin
      ns         = ent.s[hit_k];
      ns.br_type = b.br_type;
      ns.carried = b.carried;
      ns.is_rvc  = b.is_rvc;
      if (b.actual_dir) ns.target = b.target;
      if (b.br_type == BR_DIRECT) begin
        if (b.actual_dir) ns.ctr = (ns.ctr < 2'd3) ? (ns.ctr + 2'd1) : 2'd3;
        else              ns.ctr = (ns.ctr > 2'd0) ? (ns.ctr - 2'd1) : 2'd0;
      end else begin
        ns.ctr = 2'd3;
      end
      res.ent.s[hit_k] = ns;
      res.slot_found   = 1'b1;
      res.slot_idx     = hit_k;
      res.slot_ctr     = ns.ctr;
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
             ctr: (b.br_type == BR_DIRECT) ? (b.actual_dir ? 2'd2 : 2'd1) : 2'd3, target: b.target};
      res.ent.s[pos] = ns; res.slot_found = 1'b1; res.slot_idx = pos; res.slot_ctr = ns.ctr;
    end
    return res;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

endpackage
/* verilator lint_on UNUSEDPARAM */

`default_nettype wire
