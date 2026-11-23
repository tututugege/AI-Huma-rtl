`default_nettype none
// Ref: MemSubSystem/include/DataPrefetcher.h  BertiHw (tab[16] x dl[16], 4-bit exact LRU, parallel hit + 2 allocs)
// Per-PC delta table of hardware Berti: 16 fully-associative PC entries x 16 delta slots.
// Accepts 1 search update/cycle and serves 1 trigger read/cycle (forwarding the post-search entry for exact match).
module dcache_pf_berti_tab (
  input  logic               clk,
  input  logic               rst_n,
  // search update (1/cycle from dcache_pf_berti_hist)
  input  logic               srch_v,
  input  logic [31:0]        srch_pc,
  input  logic [15:0]        srch_uniq,
  input  logic signed [6:0]  srch_d [16],
  // trigger read (1/cycle from trn_q[0], sees post-search table)
  input  logic               trig_v,
  input  logic [31:0]        trig_pc,
  output logic               trig_go,
  output logic [15:0]        trig_mask,
  output logic signed [6:0]  trig_d   [16],
  output logic [1:0]         trig_st  [16],
  output logic [4:0]         trig_cov [16]
);
  localparam int DPCS    = 16;
  localparam int DDELTAS = 16;
  localparam int ROUND   = 16;
  localparam int HI_COV  = 11;
  localparam int LO_COV  = 6;

  typedef struct packed {
    logic              v;
    logic signed [6:0] d;
    logic [4:0]        cov;
    logic [4:0]        last_cov;
    logic [1:0]        st;
  } dl_t;

  // ---------------- state ----------------
  logic [DPCS-1:0]  pc_v_q;
  logic [31:0]      pc_q   [DPCS];
  logic [4:0]       cnt_q  [DPCS];
  logic [3:0]       lru_q  [DPCS];
  dl_t              dl_q   [DPCS][DDELTAS];

  // ---------------- 1. Search PC lookup / victim selection ----------------
  logic [DPCS-1:0]  hit_vec, hit_oh, inv_oh, lru_vec, lru_oh;
  logic             hit_any, inv_any, lru_any, srch_do;
  logic [3:0]       hit_idx, inv_idx, lru_idx, upd_idx, old_lru;

  always_comb begin
    for (int i = 0; i < DPCS; i++) begin
      hit_vec[i] = pc_v_q[i] && (pc_q[i] == srch_pc);
      lru_vec[i] = (lru_q[i] == 4'd15);
    end
  end
  ttg_first_set #(.N(DPCS)) u_hit (.req(hit_vec), .onehot(hit_oh), .any(hit_any));
  ttg_first_set #(.N(DPCS)) u_inv (.req(~pc_v_q), .onehot(inv_oh), .any(inv_any));
  ttg_first_set #(.N(DPCS)) u_lru (.req(lru_vec), .onehot(lru_oh), .any(lru_any));
  ttg_onehot_to_idx #(.N(DPCS), .IDXW(4)) u_hit_i (.onehot(hit_oh), .idx(hit_idx));
  ttg_onehot_to_idx #(.N(DPCS), .IDXW(4)) u_inv_i (.onehot(inv_oh), .idx(inv_idx));
  ttg_onehot_to_idx #(.N(DPCS), .IDXW(4)) u_lru_i (.onehot(lru_oh), .idx(lru_idx));

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_lru_any;
  assign unused_lru_any = lru_any;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    srch_do = srch_v && (hit_any || (|srch_uniq));
    upd_idx = hit_any ? hit_idx : (inv_any ? inv_idx : lru_idx);
    old_lru = hit_any ? lru_q[hit_idx] : 4'd15;
  end

  // ---------------- 2. Parallel hit-increment on selected PC entry ----------------
  // Read cur_dl directly via hit_oh (skips inv/lru/upd_idx dependency!)
  dl_t              cur_dl [DDELTAS];
  dl_t              hit_dl [DDELTAS];
  logic [15:0]      matched_w, unm_w;
  logic [15:0]      unm0_oh, unm1_oh;
  logic             unm0_any, unm1_any;
  logic [3:0]       unm0_idx, unm1_idx;

  for (genvar m = 0; m < DDELTAS; m++) begin : g_cur_dl
    logic [$bits(dl_t)-1:0] dl_col [DPCS];
    logic [$bits(dl_t)-1:0] dl_sel;
    for (genvar p = 0; p < DPCS; p++) begin : g_col
      assign dl_col[p] = dl_q[p][m];
    end
    ttg_onehot_mux #(.N(DPCS), .W($bits(dl_t))) u_dl_rd (.sel(hit_oh), .data(dl_col), .out(dl_sel));
    assign cur_dl[m] = dl_t'(dl_sel);
  end

  always_comb begin
    matched_w = '0;
    for (int m = 0; m < DDELTAS; m++) begin
      logic hit_m;
      hit_m = 1'b0;
      for (int w = 0; w < 16; w++) begin
        if (cur_dl[m].v && srch_uniq[w] && (srch_d[w] == cur_dl[m].d)) begin
          hit_m = 1'b1;
          matched_w[w] = 1'b1;
        end
      end
      hit_dl[m] = cur_dl[m];
      if (hit_m) hit_dl[m].cov = cur_dl[m].cov + 5'd1;
    end
    unm_w = srch_uniq & ~matched_w;
  end

  logic [15:0] unm_oh [2];
  logic [1:0]  unm_any;
  ttg_pick_k #(.N(16), .K(2)) u_unm_pk (.req(unm_w), .pick_oh(unm_oh), .valid(unm_any));
  assign unm0_oh  = unm_oh[0];
  assign unm1_oh  = unm_oh[1];
  assign unm0_any = unm_any[0];
  assign unm1_any = unm_any[1];
  ttg_onehot_to_idx #(.N(16), .IDXW(4)) u_u0_i (.onehot(unm0_oh), .idx(unm0_idx));
  ttg_onehot_to_idx #(.N(16), .IDXW(4)) u_u1_i (.onehot(unm1_oh), .idx(unm1_idx));

  // ---------------- Stage T1 -> T2 pipeline register (breaks PC CAM + 16x16 match from Top-2 tree + write) ----------------
  logic              t1_v_q;
  logic [31:0]       t1_pc_q;
  logic [3:0]        t1_upd_idx_q, t1_old_lru_q;
  logic [4:0]        t1_cnt_q;
  dl_t               t1_hit_dl_q [DDELTAS];
  logic              t1_unm0_any_q, t1_unm1_any_q;
  logic signed [6:0] t1_unm0_d_q, t1_unm1_d_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      t1_v_q <= 1'b0;
    end else begin
      t1_v_q        <= srch_do;
      t1_pc_q       <= srch_pc;
      t1_upd_idx_q  <= upd_idx;
      t1_old_lru_q  <= old_lru;
      t1_cnt_q      <= hit_any ? cnt_q[hit_idx] : 5'd0;
      t1_unm0_any_q <= unm0_any;
      t1_unm1_any_q <= unm1_any;
      t1_unm0_d_q   <= srch_d[unm0_idx];
      t1_unm1_d_q   <= srch_d[unm1_idx];
      for (int m = 0; m < DDELTAS; m++) t1_hit_dl_q[m] <= hit_dl[m];
    end
  end

  // ---------------- 3. Stage T2: Parallel top-2 slot selection + insert up to 2 unmatched deltas ----------------
  logic [DDELTAS-1:0] dl_inv_vec;
  logic [DDELTAS-1:0] inv_pk_oh [2];
  logic [1:0]         inv_pk_v;
  logic [3:0]         inv0_idx_dl, inv1_idx_dl;

  always_comb begin
    for (int m = 0; m < DDELTAS; m++) dl_inv_vec[m] = !t1_hit_dl_q[m].v;
  end
  ttg_pick_k #(.N(DDELTAS), .K(2)) u_dl_inv_pk (.req(dl_inv_vec), .pick_oh(inv_pk_oh), .valid(inv_pk_v));
  ttg_onehot_to_idx #(.N(DDELTAS), .IDXW(4)) u_inv0_dl (.onehot(inv_pk_oh[0]), .idx(inv0_idx_dl));
  ttg_onehot_to_idx #(.N(DDELTAS), .IDXW(4)) u_inv1_dl (.onehot(inv_pk_oh[1]), .idx(inv1_idx_dl));

  typedef struct packed {
    logic       v;
    logic [4:0] cov;
    logic [3:0] idx;
  } min_cand_t;

  typedef struct packed {
    min_cand_t m0;
    min_cand_t m1;
  } min_pair_t;

  function automatic logic cand_lt(input min_cand_t a, input min_cand_t b);
    return a.v && (!b.v || (a.cov < b.cov) || ((a.cov == b.cov) && (a.idx < b.idx)));
  endfunction

  function automatic min_pair_t merge_min2(input min_pair_t a, input min_pair_t b);
    min_pair_t r;
    min_cand_t c0, c1;
    if (cand_lt(a.m0, b.m0)) begin
      r.m0 = a.m0; c0 = a.m1; c1 = b.m0;
    end else begin
      r.m0 = b.m0; c0 = a.m0; c1 = b.m1;
    end
    r.m1 = cand_lt(c0, c1) ? c0 : c1;
    return r;
  endfunction

  dl_t        upd_dl [DDELTAS];
  logic [4:0] upd_cnt;

  always_comb begin
    min_pair_t l0 [16], l1 [8], l2 [4], l3 [2], l4;
    logic [4:0] s0, s1;
    min_cand_t  c_new, c_old;
    logic       do_ins0, do_ins1;
    logic [4:0] next_cnt;

    for (int m = 0; m < 16; m++) begin
      l0[m].m0 = '{v: (t1_hit_dl_q[m].v && (t1_hit_dl_q[m].st == 2'd0)), cov: t1_hit_dl_q[m].cov, idx: 4'(m)};
      l0[m].m1 = '{v: 1'b0, cov: 5'd31, idx: 4'd0};
    end
    for (int i = 0; i < 8; i++) l1[i] = merge_min2(l0[2*i], l0[2*i+1]);
    for (int i = 0; i < 4; i++) l2[i] = merge_min2(l1[2*i], l1[2*i+1]);
    for (int i = 0; i < 2; i++) l3[i] = merge_min2(l2[2*i], l2[2*i+1]);
    l4 = merge_min2(l3[0], l3[1]);

    if (inv_pk_v[0])       s0 = {1'b1, inv0_idx_dl};
    else if (l4.m0.v)      s0 = {1'b1, l4.m0.idx};
    else                   s0 = 5'd0;

    c_new = '{v: 1'b1, cov: 5'd1, idx: s0[3:0]};
    c_old = inv_pk_v[0] ? l4.m0 : l4.m1;
    if (inv_pk_v[1])                s1 = {1'b1, inv1_idx_dl};
    else if (cand_lt(c_old, c_new)) s1 = {1'b1, c_old.idx};
    else                            s1 = {1'b1, c_new.idx};

    do_ins0 = t1_unm0_any_q && s0[4];
    do_ins1 = t1_unm1_any_q && s0[4] && s1[4];

    next_cnt = t1_cnt_q + 5'd1;
    upd_cnt  = (next_cnt >= 5'(ROUND)) ? 5'd0 : next_cnt;
    for (int m = 0; m < DDELTAS; m++) begin
      dl_t e_ins;
      if (do_ins1 && (s1[3:0] == 4'(m)))
        e_ins = '{v: 1'b1, d: t1_unm1_d_q, cov: 5'd1, last_cov: 5'd0, st: 2'd0};
      else if (do_ins0 && (s0[3:0] == 4'(m)))
        e_ins = '{v: 1'b1, d: t1_unm0_d_q, cov: 5'd1, last_cov: 5'd0, st: 2'd0};
      else
        e_ins = t1_hit_dl_q[m];

      upd_dl[m] = e_ins;
      if ((next_cnt >= 5'(ROUND)) && e_ins.v) begin
        upd_dl[m].st       = (e_ins.cov >= 5'(HI_COV)) ? 2'd1 :
                             (e_ins.cov >= 5'(LO_COV)) ? 2'd2 : 2'd0;
        upd_dl[m].last_cov = e_ins.cov;
        upd_dl[m].cov      = 5'd0;
      end
    end
  end

  // ---------------- 4. Trigger read (decoupled from search update: reads registered table directly!) ----------------
  logic [DPCS-1:0]  t_hit_vec, t_hit_oh;
  logic             t_hit_any;
  logic [3:0]       t_hit_idx;

  always_comb begin
    for (int i = 0; i < DPCS; i++) begin
      t_hit_vec[i] = trig_v && pc_v_q[i] && (pc_q[i] == trig_pc);
    end
  end
  ttg_first_set #(.N(DPCS)) u_thit (.req(t_hit_vec), .onehot(t_hit_oh), .any(t_hit_any));
  ttg_onehot_to_idx #(.N(DPCS), .IDXW(4)) u_thit_i (.onehot(t_hit_oh), .idx(t_hit_idx));

  always_comb begin
    trig_mask = '0;
    for (int m = 0; m < DDELTAS; m++) begin
      logic ev;
      logic [1:0] est;
      ev           = dl_q[t_hit_idx][m].v;
      est          = dl_q[t_hit_idx][m].st;
      trig_mask[m] = t_hit_any && ev && (est != 2'd0);
      trig_d[m]    = dl_q[t_hit_idx][m].d;
      trig_st[m]   = est;
      trig_cov[m]  = dl_q[t_hit_idx][m].last_cov;
    end
    trig_go = t_hit_any && (|trig_mask);
  end

  // ---------------- 5. Registers ----------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pc_v_q <= '0;
      for (int i = 0; i < DPCS; i++) begin
        cnt_q[i] <= '0;
        lru_q[i] <= 4'(i);
      end
    end else if (t1_v_q) begin
      pc_v_q[t1_upd_idx_q] <= 1'b1;
      pc_q[t1_upd_idx_q]   <= t1_pc_q;
      cnt_q[t1_upd_idx_q]  <= upd_cnt;
      for (int m = 0; m < DDELTAS; m++) dl_q[t1_upd_idx_q][m] <= upd_dl[m];
      for (int i = 0; i < DPCS; i++) begin
        if (4'(i) == t1_upd_idx_q) lru_q[i] <= 4'd0;
        else if (pc_v_q[i] && (lru_q[i] < t1_old_lru_q)) lru_q[i] <= lru_q[i] + 4'd1;
      end
    end
  end
endmodule

`default_nettype wire
