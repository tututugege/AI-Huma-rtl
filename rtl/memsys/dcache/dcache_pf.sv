`default_nettype none
// Ref: MemSubSystem/include/DataPrefetcher.h  BertiHw (PF_KIND=4, EXP-048 M3), docs/modules/dcache_pf.md
// L1D data prefetcher: hardware Berti (16-way dedup history, 16x16 PC delta table, VA + LSU DTLB-port cross-page
// translation, 8-entry deduplicated request FIFO).
module dcache_pf
  import dcache_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,
  // FIFO head (probe candidate -> dcache_s1)
  output logic                 head_valid,
  output logic [LINE_W-1:0]    head_line,
  output logic                 head_llc,
  input  logic                 head_taken,
  // cache fill event (dcache_s2_fill)
  input  logic                 fill_valid,
  input  logic [LINE_W-1:0]    fill_line,
  input  logic                 fill_is_pf,
  // access events of this cycle (dcache_s2_ld)
  input  logic [NLD-1:0]       acc_valid,
  input  logic [LINE_W-1:0]    acc_line  [NLD],
  input  logic [31:0]          acc_pc    [NLD],
  input  logic [38:0]          acc_va    [NLD],
  input  logic [NLD-1:0]       acc_miss,
  input  logic [NLD-1:0]       acc_pf_hit,
  // cross-page DTLB translation interface (<-> LSU lp_l1)
  output logic [NLD-1:0]       pf_xq_v,
  output logic [38:0]          pf_xq_va   [NLD],
  output logic [NLD-1:0]       pf_xq_llc,
  input  logic [2:0]           pf_xq_pop,
  input  logic [NLD-1:0]       pf_xans_v,
  input  logic [LINE_W-1:0]    pf_xans_line [NLD],
  input  logic [NLD-1:0]       pf_xans_llc
);
  localparam int QD     = 8;
  localparam int QW     = 3;
  localparam int TRNQ_N = 4;

  typedef struct packed {
    logic [31:0]       pc;
    logic [31:0]       vline;
    logic [LINE_W-1:0] pline;
    logic              vaneg;
    logic              miss;
  } trn_e_t;

  // ---------------- state: cycle counter, reqq FIFO, train FIFO ----------------
  logic [19:0]       cyc_q;
  logic [LINE_W-1:0] q_line_q [QD];
  logic [QD-1:0]     q_llc_q;
  logic [QW-1:0]     q_head_q;
  logic [QW:0]       q_cnt_q;
  trn_e_t            trnq_q [TRNQ_N];
  logic [2:0]        trnq_n_q;

  assign head_valid = (q_cnt_q != '0);
  assign head_line  = q_line_q[q_head_q];
  assign head_llc   = q_llc_q[q_head_q];

  // ---------------- Berti submodules ----------------
  logic               srch_v, trig_go, push_en, push_llc;
  logic [31:0]        srch_pc;
  logic [15:0]        srch_uniq, trig_mask;
  logic signed [6:0]  srch_d [16], trig_d [16];
  logic [1:0]         trig_st [16];
  logic [4:0]         trig_cov [16];
  logic [LINE_W-1:0]  push_line;
  logic               trn_pop;

  assign trn_pop = (trnq_n_q != 3'd0);

  dcache_pf_berti_hist u_hist (
    .clk, .rst_n, .cyc_q,
    .pfi_en(head_taken && !head_llc), .pfi_pline(head_line),
    .fill_valid, .fill_pline(fill_line), .fill_is_pf,
    .trn_v(trn_pop), .trn_miss(trnq_q[0].miss), .trn_pc(trnq_q[0].pc),
    .trn_vline(trnq_q[0].vline), .trn_pline(trnq_q[0].pline),
    .srch_v, .srch_pc, .srch_uniq, .srch_d
  );

  dcache_pf_berti_tab u_tab (
    .clk, .rst_n, .srch_v, .srch_pc, .srch_uniq, .srch_d,
    .trig_v(trn_pop), .trig_pc(trnq_q[0].pc),
    .trig_go, .trig_mask, .trig_d, .trig_st, .trig_cov
  );

  dcache_pf_berti_gen u_gen (
    .clk, .rst_n,
    .trig_go, .trig_mask, .trig_d, .trig_st, .trig_cov,
    .trig_vline(trnq_q[0].vline), .trig_ppn(trnq_q[0].pline[LINE_W-1:6]), .trig_vaneg(trnq_q[0].vaneg),
    .xq_v(pf_xq_v), .xq_va(pf_xq_va), .xq_llc(pf_xq_llc), .xq_pop(pf_xq_pop),
    .xans_in_v(pf_xans_v), .xans_in_line(pf_xans_line), .xans_in_llc(pf_xans_llc),
    .push_en, .push_line, .push_llc
  );

  // ---------------- reqq dedup + next state ----------------
  logic [QW:0]   cnt_a;
  logic [QW-1:0] head_a;
  logic          dup, do_push;

  always_comb begin
    cnt_a  = q_cnt_q - (QW+1)'(head_taken);
    head_a = q_head_q + QW'(head_taken);
    dup    = 1'b0;
    for (int e = 0; e < QD; e++) begin
      logic [QW-1:0] pos;
      pos = QW'(e) - head_a;
      if (((QW+1)'(pos) < cnt_a) && (q_line_q[e] == push_line)) dup = 1'b1;
    end
    do_push = push_en && !dup && (cnt_a != (QW+1)'(QD));
  end

  // ---------------- train FIFO next state: pop 1, push up to 2 load events ----------------
  logic [NLD-1:0] ev_cand, ev0_oh, ev1_oh;
  logic           ev0_any, ev1_any;
  logic [1:0]     ev0_idx, ev1_idx;
  trn_e_t         trnq_d [TRNQ_N];
  logic [2:0]     trnq_n_d;

  assign ev_cand = acc_valid & (acc_miss | acc_pf_hit);
  ttg_first_set #(.N(NLD)) u_ev0 (.req(ev_cand), .onehot(ev0_oh), .any(ev0_any));
  ttg_first_set #(.N(NLD)) u_ev1 (.req(ev_cand & ~ev0_oh), .onehot(ev1_oh), .any(ev1_any));
  ttg_onehot_to_idx #(.N(NLD), .IDXW(2)) u_ev0_i (.onehot(ev0_oh), .idx(ev0_idx));
  ttg_onehot_to_idx #(.N(NLD), .IDXW(2)) u_ev1_i (.onehot(ev1_oh), .idx(ev1_idx));

  always_comb begin
    logic [2:0] n;
    for (int i = 0; i < TRNQ_N; i++) trnq_d[i] = trnq_q[i];
    n = trnq_n_q;
    if (n != 3'd0) begin
      for (int i = 0; i < TRNQ_N - 1; i++) trnq_d[i] = trnq_q[i + 1];
      n = n - 3'd1;
    end
    if (ev0_any && (n < 3'(TRNQ_N))) begin
      trnq_d[n[1:0]] = '{pc: acc_pc[ev0_idx], vline: acc_va[ev0_idx][37:6], pline: acc_line[ev0_idx],
                         vaneg: acc_va[ev0_idx][38], miss: acc_miss[ev0_idx]};
      n = n + 3'd1;
    end
    if (ev1_any && (n < 3'(TRNQ_N))) begin
      trnq_d[n[1:0]] = '{pc: acc_pc[ev1_idx], vline: acc_va[ev1_idx][37:6], pline: acc_line[ev1_idx],
                         vaneg: acc_va[ev1_idx][38], miss: acc_miss[ev1_idx]};
      n = n + 3'd1;
    end
    trnq_n_d = n;
  end

  // ---------------- registers ----------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cyc_q    <= '0;
      q_head_q <= '0;
      q_cnt_q  <= '0;
      q_llc_q  <= '0;
      trnq_n_q <= '0;
    end else begin
      cyc_q    <= cyc_q + 20'd1;
      q_head_q <= head_a;
      q_cnt_q  <= cnt_a + (QW+1)'(do_push);
      trnq_n_q <= trnq_n_d;
      for (int i = 0; i < TRNQ_N; i++) trnq_q[i] <= trnq_d[i];
    end
    if (do_push) begin
      q_line_q[QW'(head_a + QW'(cnt_a))] <= push_line;
      q_llc_q[QW'(head_a + QW'(cnt_a))]  <= push_llc;
    end
  end
endmodule

`default_nettype wire
