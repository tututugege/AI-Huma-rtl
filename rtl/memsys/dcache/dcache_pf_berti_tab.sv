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
  dl_t              cur_dl [DDELTAS];
  dl_t              hit_dl [DDELTAS];
  logic [15:0]      matched_w, unm_w;
  logic [15:0]      unm0_oh, unm1_oh;
  logic             unm0_any, unm1_any;
  logic [3:0]       unm0_idx, unm1_idx;

  always_comb begin
    matched_w = '0;
    for (int m = 0; m < DDELTAS; m++) begin
      logic hit_m;
      cur_dl[m] = hit_any ? dl_q[upd_idx][m] : '0;
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

  ttg_first_set #(.N(16)) u_u0 (.req(unm_w), .onehot(unm0_oh), .any(unm0_any));
  ttg_first_set #(.N(16)) u_u1 (.req(unm_w & ~unm0_oh), .onehot(unm1_oh), .any(unm1_any));
  ttg_onehot_to_idx #(.N(16), .IDXW(4)) u_u0_i (.onehot(unm0_oh), .idx(unm0_idx));
  ttg_onehot_to_idx #(.N(16), .IDXW(4)) u_u1_i (.onehot(unm1_oh), .idx(unm1_idx));

  // ---------------- 3. Insert up to 2 unmatched deltas + round-end status update ----------------
  function automatic logic [4:0] pick_slot(input dl_t arr [DDELTAS]);
    logic       found_inv, found_st0;
    logic [3:0] idx_inv, idx_st0;
    logic [4:0] min_cov;
    found_inv = 1'b0; idx_inv = 4'd0;
    found_st0 = 1'b0; idx_st0 = 4'd0; min_cov = 5'd31;
    for (int m = 0; m < DDELTAS; m++) begin
      if (!arr[m].v && !found_inv) begin
        found_inv = 1'b1;
        idx_inv = 4'(m);
      end
      if (arr[m].v && (arr[m].st == 2'd0) && (!found_st0 || (arr[m].cov < min_cov))) begin
        found_st0 = 1'b1;
        idx_st0 = 4'(m);
        min_cov = arr[m].cov;
      end
    end
    if (found_inv) return {1'b1, idx_inv};
    if (found_st0) return {1'b1, idx_st0};
    return 5'd0;
  endfunction

  dl_t        ins1_dl [DDELTAS];
  dl_t        ins2_dl [DDELTAS];
  dl_t        upd_dl  [DDELTAS];
  logic [4:0] upd_cnt;

  always_comb begin
    logic [4:0] s0, s1;
    logic [4:0] next_cnt;
    for (int m = 0; m < DDELTAS; m++) ins1_dl[m] = hit_dl[m];
    s0 = pick_slot(hit_dl);
    if (unm0_any && s0[4]) ins1_dl[s0[3:0]] = '{v: 1'b1, d: srch_d[unm0_idx], cov: 5'd1, last_cov: 5'd0, st: 2'd0};

    for (int m = 0; m < DDELTAS; m++) ins2_dl[m] = ins1_dl[m];
    s1 = pick_slot(ins1_dl);
    if (unm1_any && s0[4] && s1[4]) ins2_dl[s1[3:0]] = '{v: 1'b1, d: srch_d[unm1_idx], cov: 5'd1, last_cov: 5'd0, st: 2'd0};

    next_cnt = (hit_any ? cnt_q[upd_idx] : 5'd0) + 5'd1;
    upd_cnt  = (next_cnt >= 5'(ROUND)) ? 5'd0 : next_cnt;
    for (int m = 0; m < DDELTAS; m++) begin
      upd_dl[m] = ins2_dl[m];
      if ((next_cnt >= 5'(ROUND)) && ins2_dl[m].v) begin
        upd_dl[m].st       = (ins2_dl[m].cov >= 5'(HI_COV)) ? 2'd1 :
                             (ins2_dl[m].cov >= 5'(LO_COV)) ? 2'd2 : 2'd0;
        upd_dl[m].last_cov = ins2_dl[m].cov;
        upd_dl[m].cov      = 5'd0;
      end
    end
  end

  // ---------------- 4. Trigger read (sees post-search state) ----------------
  logic [DPCS-1:0]  t_hit_vec, t_hit_oh;
  logic             t_hit_any;
  logic [3:0]       t_hit_idx;

  always_comb begin
    for (int i = 0; i < DPCS; i++) begin
      logic v_post;
      logic [31:0] pc_post;
      v_post  = (srch_do && (4'(i) == upd_idx)) ? 1'b1 : pc_v_q[i];
      pc_post = (srch_do && (4'(i) == upd_idx)) ? srch_pc : pc_q[i];
      t_hit_vec[i] = trig_v && v_post && (pc_post == trig_pc);
    end
  end
  ttg_first_set #(.N(DPCS)) u_thit (.req(t_hit_vec), .onehot(t_hit_oh), .any(t_hit_any));
  ttg_onehot_to_idx #(.N(DPCS), .IDXW(4)) u_thit_i (.onehot(t_hit_oh), .idx(t_hit_idx));

  always_comb begin
    logic use_fwd;
    use_fwd = srch_do && (t_hit_idx == upd_idx);
    trig_mask = '0;
    for (int m = 0; m < DDELTAS; m++) begin
      logic ev;
      logic [1:0] est;
      ev           = use_fwd ? upd_dl[m].v        : dl_q[t_hit_idx][m].v;
      est          = use_fwd ? upd_dl[m].st       : dl_q[t_hit_idx][m].st;
      trig_mask[m] = t_hit_any && ev && (est != 2'd0);
      trig_d[m]    = use_fwd ? upd_dl[m].d        : dl_q[t_hit_idx][m].d;
      trig_st[m]   = est;
      trig_cov[m]  = use_fwd ? upd_dl[m].last_cov : dl_q[t_hit_idx][m].last_cov;
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
    end else if (srch_do) begin
      pc_v_q[upd_idx] <= 1'b1;
      pc_q[upd_idx]   <= srch_pc;
      cnt_q[upd_idx]  <= upd_cnt;
      for (int m = 0; m < DDELTAS; m++) dl_q[upd_idx][m] <= upd_dl[m];
      for (int i = 0; i < DPCS; i++) begin
        if (4'(i) == upd_idx) lru_q[i] <= 4'd0;
        else if (pc_v_q[i] && (lru_q[i] < old_lru)) lru_q[i] <= lru_q[i] + 4'd1;
      end
    end
  end
endmodule

`default_nettype wire
