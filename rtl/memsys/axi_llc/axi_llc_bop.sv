`default_nettype none
// Ref: MemSubSystem/include/Bop.h + axi-interconnect-kit/axi_interconnect/AXI_LLC.cpp (bop_seq, try_launch_prefetch_lookup)
// LLC Best-Offset Prefetcher (Michaud, HPCA 2016; EXP-048 LLC_BOP=1):
//   * Recent-requests (RR) table: 256-entry direct-mapped table indexed by line[7:0] ^ line[15:8], written on
//     non-write refills (prefetch inserts line - best, demand inserts line while prefetching is off).
//   * Learning: each L1D demand read miss or first demand use of a prefetched line tests one of the 26 offsets;
//     a phase ends after BOP_ROUNDS rounds or when a score reaches BOP_SCORE_MAX; best offset is picked if its
//     score exceeds BOP_BAD, else prefetching turns off.
//   * Candidate queue: BOP_Q-entry deduplicated FIFO (drops oldest on overflow); launches a prefetch lookup when
//     the lookup engine is free, pf_allow is high, and prefetch MSHR budget is available.
module axi_llc_bop
  import axi_llc_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  // launch preconditions (stage 5, post-write/read lookup accept)
  input  logic pf_allow,
  input  logic lk_free_pf,
  input  logic pf_alloc_ok_d,
  input  logic [NMSHR-1:0] ml_vld_d,
  input  logic [NMSHR-1:0][31:0] ml_line_d,
  // events of this tick
  input  logic fill_v,
  input  logic fill_pf,
  input  logic [25:0] fill_line,
  input  logic trig_v,
  input  logic [25:0] trig_line,
  // EXP-058: dual-priority Bingo queue partner (BOP > Bingo)
  input  logic bingo_q_empty,
  input  logic [25:0] bingo_q_head,
  output logic bingo_pop,
  // prefetch lookup launch
  output logic p_launch,
  output addr_t p_addr
);
  localparam logic [5:0] OFF_ROM [BOP_OFFS] = '{
    6'd1,  6'd2,  6'd3,  6'd4,  6'd5,  6'd6,  6'd8,  6'd9,  6'd10, 6'd12,
    6'd15, 6'd16, 6'd18, 6'd20, 6'd24, 6'd25, 6'd27, 6'd30, 6'd32, 6'd36,
    6'd40, 6'd45, 6'd48, 6'd50, 6'd54, 6'd60
  };

  // RR table (synchronous write memory + resettable valid bits)
  logic [31:0] rr_tag_q [BOP_RR_SZ];
  logic [BOP_RR_SZ-1:0] rr_v_q;

  // BOP learner state
  logic [4:0] score_q [BOP_OFFS];
  logic [4:0] test_q;
  logic [6:0] round_q;
  logic [5:0] best_q;
  logic on_q;

  // BOP_Q-entry candidate FIFO (axi_llc_pfq, oldest at index 0)
  logic        q_empty;
  logic [25:0] q_head;

  // ---------------- launch (combinational, BOP > Bingo) ----------------
  logic has_bop, has_bingo, pop_head, head_in_mshr;
  logic [25:0] launch_line;
  always_comb begin
    has_bop     = !q_empty;
    has_bingo   = !bingo_q_empty;
    launch_line = has_bop ? q_head : bingo_q_head;
  end
  axi_llc_linecam #(.N(NMSHR)) u_hd_ms (
    .vld(ml_vld_d), .addr(ml_line_d), .line({launch_line, 6'b0}), .hit(head_in_mshr)
  );
  always_comb begin
    pop_head  = has_bop && lk_free_pf && pf_allow && pf_alloc_ok_d;
    bingo_pop = !has_bop && has_bingo && lk_free_pf && pf_allow && pf_alloc_ok_d;
    p_launch  = (pop_head || bingo_pop) && !head_in_mshr;
    p_addr    = {launch_line, 6'b0};
  end

  // ---------------- RR fill + probe (same-cycle fill forwarded to learn) ----------------
  logic rr_we, rr_hit;
  logic [31:0] rr_wval, probe_val;
  logic [BOP_RR_BITS-1:0] rr_widx, probe_idx;
  logic [5:0] cur_off;

  always_comb begin
    rr_we = fill_v && (fill_pf || !on_q);
    rr_wval = fill_pf ? ({6'b0, fill_line} - {26'b0, best_q}) : {6'b0, fill_line};
    rr_widx = rr_wval[7:0] ^ rr_wval[15:8];
    cur_off = OFF_ROM[test_q];
    probe_val = {6'b0, trig_line} - {26'b0, cur_off};
    probe_idx = probe_val[7:0] ^ probe_val[15:8];
    if (rr_we && (rr_widx == probe_idx)) rr_hit = (rr_wval == probe_val);
    else                                 rr_hit = rr_v_q[probe_idx] && (rr_tag_q[probe_idx] == probe_val);
  end

  // ---------------- learn + phase end (speculative parallel: max(score_q) & 3 cand paths in parallel with rr_tag_q!) ----------------
  typedef struct packed {
    logic       v;
    logic [4:0] sc;
    logic [4:0] idx;
  } bop_cand_t;

  function automatic bop_cand_t max_bop(input bop_cand_t a, input bop_cand_t b);
    // Lower index wins ties, matching `eff_sc > best_sc` scan order 0..BOP_OFFS-1
    if (a.v && (!b.v || (a.sc >= b.sc))) return a;
    else                                 return b;
  endfunction

  logic [4:0] score_inc, base_best_sc, base_best_idx, best_sc, best_idx;
  logic [4:0] test_d;
  logic [6:0] round_d;
  logic [5:0] best_d;
  logic hit_max, last_off, end_round, do_end_phase, on_d, test_wins;

  // Path 1 (register-only, parallel with rr_tag_q lookup): max of score_q[0..BOP_OFFS-1]
  always_comb begin
    bop_cand_t b0 [32], b1 [16], b2 [8], b3 [4], b4 [2];
    /* verilator lint_off UNUSEDSIGNAL */
    bop_cand_t b5;
    /* verilator lint_on UNUSEDSIGNAL */
    for (int i = 0; i < 32; i++) begin
      if (i < BOP_OFFS) b0[i] = '{v: 1'b1, sc: score_q[i], idx: 5'(i)};
      else              b0[i] = '{v: 1'b0, sc: 5'd0,       idx: 5'd0};
    end
    for (int i = 0; i < 16; i++) b1[i] = max_bop(b0[2*i], b0[2*i+1]);
    for (int i = 0; i < 8;  i++) b2[i] = max_bop(b1[2*i], b1[2*i+1]);
    for (int i = 0; i < 4;  i++) b3[i] = max_bop(b2[2*i], b2[2*i+1]);
    for (int i = 0; i < 2;  i++) b4[i] = max_bop(b3[2*i], b3[2*i+1]);
    b5            = max_bop(b4[0], b4[1]);
    base_best_sc  = b5.sc;
    base_best_idx = b5.idx;
  end

  always_comb begin
    score_inc    = score_q[test_q] + 5'd1;
    hit_max      = rr_hit && (score_inc >= 5'(BOP_SCORE_MAX));
    last_off     = (test_q == 5'(BOP_OFFS - 1));
    end_round    = !hit_max && last_off && (round_q + 7'd1 >= 7'(BOP_ROUNDS));
    do_end_phase = trig_v && (hit_max || end_round);

    // Only score_q[test_q] can change (by +1 when rr_hit), so only compare score_inc vs base_best_sc
    test_wins = rr_hit && ((score_inc > base_best_sc) || ((score_inc == base_best_sc) && (test_q < base_best_idx)));
    best_sc   = test_wins ? score_inc : base_best_sc;
    best_idx  = test_wins ? test_q    : base_best_idx;

    on_d    = on_q;
    best_d  = best_q;
    test_d  = test_q;
    round_d = round_q;
    if (do_end_phase) begin
      on_d = (best_sc > 5'(BOP_BAD));
      if (on_d) best_d = OFF_ROM[best_idx];
      test_d  = 5'd0;
      round_d = 7'd0;
    end else if (trig_v) begin
      if (last_off) begin
        test_d  = 5'd0;
        round_d = round_q + 7'd1;
      end else begin
        test_d  = test_q + 5'd1;
      end
    end
  end

  // ---------------- candidate generation (the FIFO is axi_llc_pfq) ----------------
  // All 3 possible candidate lines are computed in parallel with the rr_tag_q lookup (the queue checks each of them
  // for a duplicate in parallel too):
  //   0: best_q (normal cycles / end_phase with on_d==0)
  //   1: OFF_ROM[base_best_idx] (end_phase, !test_wins)
  //   2: cur_off = OFF_ROM[test_q] (end_phase, test_wins)
  logic [5:0]  cand_off [3];
  logic [25:0] cand_ln  [3];
  logic [2:0]  cand_pg_ok;
  logic [1:0]  cand_sel;
  logic        cand_ok;

  always_comb begin
    cand_off[0] = best_q;
    cand_off[1] = OFF_ROM[base_best_idx];
    cand_off[2] = cur_off;

    for (int c = 0; c < 3; c++) begin
      logic [31:0] s;
      s             = {6'b0, trig_line} + {26'b0, cand_off[c]};
      cand_ln[c]    = s[25:0];
      cand_pg_ok[c] = (s[31:6] == {6'b0, trig_line[25:6]});
    end

    if (do_end_phase && on_d) begin
      cand_sel = test_wins ? 2'd2 : 2'd1;
      cand_ok  = trig_v && (test_wins ? cand_pg_ok[2] : cand_pg_ok[1]);
    end else begin
      cand_sel = 2'd0;
      cand_ok  = trig_v && on_d && cand_pg_ok[0];
    end
  end

  axi_llc_pfq #(.N(BOP_Q), .NCAND(3), .W(26), .RST_LINES(1'b1)) u_q (
    .clk, .rst_n, .pop(pop_head), .push_v(cand_ok), .cand_line(cand_ln), .cand_sel,
    .empty(q_empty), .head(q_head)
  );

  // ---------------- registers ----------------
  always_ff @(posedge clk) begin
    if (rr_we) rr_tag_q[rr_widx] <= rr_wval;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rr_v_q <= '0;
      for (int i = 0; i < BOP_OFFS; i++) score_q[i] <= '0;
      test_q <= '0;
      round_q <= '0;
      best_q <= 6'd1;
      on_q <= 1'b1;
    end else begin
      if (rr_we) rr_v_q[rr_widx] <= 1'b1;
      if (do_end_phase) begin
        for (int i = 0; i < BOP_OFFS; i++) score_q[i] <= '0;
      end else if (trig_v && rr_hit) begin
        score_q[test_q] <= score_inc;
      end
      test_q <= test_d;
      round_q <= round_d;
      best_q <= best_d;
      on_q <= on_d;
    end
  end
endmodule

`default_nettype wire
