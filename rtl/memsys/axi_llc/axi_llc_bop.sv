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

  // 8-entry candidate FIFO (oldest at index 0)
  logic [25:0] q_line_q [BOP_Q];
  logic [3:0] q_cnt_q;

  // ---------------- launch (combinational, BOP > Bingo) ----------------
  logic has_bop, has_bingo, pop_head, head_in_mshr;
  logic [25:0] launch_line;
  always_comb begin
    has_bop     = (q_cnt_q != 4'd0);
    has_bingo   = !bingo_q_empty;
    launch_line = has_bop ? q_line_q[0] : bingo_q_head;
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

  // ---------------- learn + phase end ----------------
  logic [4:0] score_inc, best_sc, eff_sc;
  logic [4:0] best_idx, test_d;
  logic [6:0] round_d;
  logic [5:0] best_d;
  logic hit_max, last_off, end_round, do_end_phase, on_d;

  always_comb begin
    score_inc = score_q[test_q] + 5'd1;
    hit_max = rr_hit && (score_inc >= 5'(BOP_SCORE_MAX));
    last_off = (test_q == 5'(BOP_OFFS - 1));
    end_round = !hit_max && last_off && (round_q + 7'd1 >= 7'(BOP_ROUNDS));
    do_end_phase = trig_v && (hit_max || end_round);

    best_idx = 5'd0;
    best_sc = (test_q == 5'd0 && rr_hit) ? score_inc : score_q[0];
    for (int i = 1; i < BOP_OFFS; i++) begin
      eff_sc = (test_q == 5'(i) && rr_hit) ? score_inc : score_q[i];
      if (eff_sc > best_sc) begin
        best_sc = eff_sc;
        best_idx = 5'(i);
      end
    end

    on_d = on_q;
    best_d = best_q;
    test_d = test_q;
    round_d = round_q;
    if (do_end_phase) begin
      on_d = (best_sc > 5'(BOP_BAD));
      if (on_d) best_d = OFF_ROM[best_idx];
      test_d = 5'd0;
      round_d = 7'd0;
    end else if (trig_v) begin
      if (last_off) begin
        test_d = 5'd0;
        round_d = round_q + 7'd1;
      end else begin
        test_d = test_q + 5'd1;
      end
    end
  end

  // ---------------- candidate generation + FIFO next state ----------------
  logic [31:0] cand_sum;
  logic [25:0] cand_line;
  logic cand_ok, cand_dup, q_push;
  logic [25:0] q_p [BOP_Q];
  logic [25:0] q_d [BOP_Q];
  logic [3:0] cnt_p, cnt_d;

  always_comb begin
    cand_sum = {6'b0, trig_line} + {26'b0, best_d};
    cand_line = cand_sum[25:0];
    cand_ok = trig_v && on_d && (cand_sum[31:6] == {6'b0, trig_line[25:6]});

    for (int i = 0; i < BOP_Q; i++) begin
      q_p[i] = (pop_head && (i + 1 < BOP_Q)) ? q_line_q[i + 1] : q_line_q[i];
    end
    cnt_p = pop_head ? (q_cnt_q - 4'd1) : q_cnt_q;

    cand_dup = 1'b0;
    for (int i = 0; i < BOP_Q; i++) begin
      if ((4'(i) < cnt_p) && (q_p[i] == cand_line)) cand_dup = 1'b1;
    end
    q_push = cand_ok && !cand_dup;

    for (int i = 0; i < BOP_Q; i++) q_d[i] = q_p[i];
    cnt_d = cnt_p;
    if (q_push) begin
      if (cnt_p == 4'(BOP_Q)) begin
        for (int i = 0; i < BOP_Q - 1; i++) q_d[i] = q_p[i + 1];
        q_d[BOP_Q - 1] = cand_line;
      end else begin
        q_d[cnt_p[2:0]] = cand_line;
        cnt_d = cnt_p + 4'd1;
      end
    end
  end

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
      q_cnt_q <= '0;
      for (int i = 0; i < BOP_Q; i++) q_line_q[i] <= '0;
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
      q_cnt_q <= cnt_d;
      for (int i = 0; i < BOP_Q; i++) q_line_q[i] <= q_d[i];
    end
  end
endmodule

`default_nettype wire
