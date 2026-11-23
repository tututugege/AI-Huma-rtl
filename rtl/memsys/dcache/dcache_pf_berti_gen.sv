`default_nettype none
// Ref: MemSubSystem/include/DataPrefetcher.h  BertiHw (step_gen, start_gen, g_pf_xq[8], g_pf_xans[8])
// Burst generator (16-to-1 priority tournament over learned deltas, DEG=12), cross-page VA queue (xq[8] -> LSU DTLB),
// and translated-PA answer queue (xans[8] <- LSU DTLB -> reqq).
module dcache_pf_berti_gen
  import dcache_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,
  // new burst load from trigger (trn_q[0] -> dcache_pf_berti_tab)
  input  logic                 trig_go,
  input  logic [15:0]          trig_mask,
  input  logic signed [6:0]    trig_d   [16],
  input  logic [1:0]           trig_st  [16],
  input  logic [4:0]           trig_cov [16],
  input  logic [31:0]          trig_vline,
  input  logic [LINE_W-7:0]    trig_ppn,
  input  logic                 trig_vaneg,
  // LSU DTLB cross-page translation interface (combinational within tick, registered in xq/xans)
  output logic [NLD-1:0]       xq_v,
  output logic [38:0]          xq_va   [NLD],
  output logic [NLD-1:0]       xq_llc,
  input  logic [2:0]           xq_pop,
  input  logic [NLD-1:0]       xans_in_v,
  input  logic [LINE_W-1:0]    xans_in_line [NLD],
  input  logic [NLD-1:0]       xans_in_llc,
  // 1 candidate per cycle to reqq FIFO
  output logic                 push_en,
  output logic [LINE_W-1:0]    push_line,
  output logic                 push_llc
);
  localparam int DEG  = 12;
  localparam int XQN  = 8;
  localparam int XAN  = 8;

  // ---------------- state ----------------
  logic [15:0]       gen_mask_q;
  logic signed [6:0] gen_d_q   [16];
  logic [1:0]        gen_st_q  [16];
  logic [4:0]        gen_cov_q [16];
  logic [31:0]       gen_vline_q;
  logic [LINE_W-7:0] gen_ppn_q;
  logic              gen_vaneg_q;
  logic [3:0]        gen_left_q;

  logic [38:0]       xq_va_q  [XQN];
  logic [XQN-1:0]    xq_llc_q;
  logic [3:0]        xq_cnt_q;

  logic [LINE_W-1:0] xa_line_q [XAN];
  logic [XAN-1:0]    xa_llc_q;
  logic [3:0]        xa_cnt_q;

  // Expose up to NLD head entries of xq_q to LSU DTLB ports
  always_comb begin
    for (int i = 0; i < NLD; i++) begin
      xq_v[i]   = (4'(i) < xq_cnt_q);
      xq_va[i]  = xq_va_q[i];
      xq_llc[i] = xq_llc_q[i];
    end
  end

  // ---------------- 1. Append this cycle's xans_in to xans_q, pop 1 to reqq ----------------
  logic [LINE_W-1:0] xa_p_line [XAN];
  logic [XAN-1:0]    xa_p_llc;
  logic [3:0]        xa_p_cnt;
  logic              xa_pop;

  always_comb begin
    logic [3:0] n;
    for (int i = 0; i < XAN; i++) begin
      xa_p_line[i] = xa_line_q[i];
      xa_p_llc[i]  = xa_llc_q[i];
    end
    n = xa_cnt_q;
    for (int q = 0; q < NLD; q++) begin
      if (xans_in_v[q] && (n < 4'(XAN))) begin
        xa_p_line[n[2:0]] = xans_in_line[q];
        xa_p_llc[n[2:0]]  = xans_in_llc[q];
        n = n + 4'd1;
      end
    end
    xa_p_cnt = n;
    xa_pop   = (xa_p_cnt != 4'd0);
  end

  // ---------------- 2. Generator 16->1 priority tournament (4-level binary tree) + step ----------------
  typedef struct packed {
    logic       v;
    logic [5:0] key;
    logic [3:0] idx;
  } gen_cand_t;

  function automatic gen_cand_t max_gen(input gen_cand_t a, input gen_cand_t b);
    // Left (lower index) wins ties, matching `key > best_key` scan order 0..15
    if (a.v && (!b.v || (a.key >= b.key))) return a;
    else                                   return b;
  endfunction

  logic       gen_act, gen_same_page, gen_step_sp, gen_step_xp;
  logic [3:0] best_m;
  logic [31:0] gen_t;

  always_comb begin
    gen_cand_t t0 [16], t1 [8], t2 [4], t3 [2];
    /* verilator lint_off UNUSEDSIGNAL */
    gen_cand_t t4;
    /* verilator lint_on UNUSEDSIGNAL */
    gen_act  = (gen_left_q != 4'd0) && (|gen_mask_q);
    for (int m = 0; m < 16; m++) begin
      t0[m] = '{v: gen_mask_q[m], key: {(gen_st_q[m] == 2'd1), gen_cov_q[m]}, idx: 4'(m)};
    end
    for (int i = 0; i < 8; i++) t1[i] = max_gen(t0[2*i], t0[2*i+1]);
    for (int i = 0; i < 4; i++) t2[i] = max_gen(t1[2*i], t1[2*i+1]);
    for (int i = 0; i < 2; i++) t3[i] = max_gen(t2[2*i], t2[2*i+1]);
    t4     = max_gen(t3[0], t3[1]);
    best_m = t4.v ? t4.idx : 4'd0;
    gen_t         = gen_vline_q + {{25{gen_d_q[best_m][6]}}, gen_d_q[best_m]};
    gen_same_page = (gen_t[31:6] == gen_vline_q[31:6]);
    gen_step_sp   = gen_act && gen_same_page && !xa_pop;
    gen_step_xp   = gen_act && !gen_same_page;

    if (xa_pop) begin
      push_en   = 1'b1;
      push_line = xa_p_line[0];
      push_llc  = xa_p_llc[0];
    end else if (gen_step_sp) begin
      push_en   = 1'b1;
      push_line = {gen_ppn_q, gen_t[5:0]};
      push_llc  = (gen_st_q[best_m] == 2'd2);
    end else begin
      push_en   = 1'b0;
      push_line = '0;
      push_llc  = 1'b0;
    end
  end

  // ---------------- 3. xq next state: pop xq_pop (0..NLD), dedup + push cross-page candidate ----------------
  logic [38:0]    xq_d_va [XQN];
  logic [XQN-1:0] xq_d_llc;
  logic [3:0]     xq_d_cnt;

  always_comb begin
    logic [38:0]    xp_va [XQN];
    logic [XQN-1:0] xp_llc;
    logic [3:0]     n_p;
    logic [38:0]    new_va;
    logic           new_llc, dup;

    n_p = (xq_cnt_q > {1'b0, xq_pop}) ? (xq_cnt_q - {1'b0, xq_pop}) : 4'd0;
    for (int i = 0; i < XQN; i++) begin
      logic [3:0] src;
      src = 4'(i) + {1'b0, xq_pop};
      xp_va[i]  = (src < 4'(XQN)) ? xq_va_q[src[2:0]] : 39'd0;
      xp_llc[i] = (src < 4'(XQN)) ? xq_llc_q[src[2:0]] : 1'b0;
    end

    new_va  = {gen_vaneg_q, gen_t, 6'b0};
    new_llc = (gen_st_q[best_m] == 2'd2);
    dup     = 1'b0;
    for (int i = 0; i < XQN; i++) begin
      if ((4'(i) < n_p) && (xp_va[i][38:6] == new_va[38:6])) dup = 1'b1;
    end

    for (int i = 0; i < XQN; i++) begin
      xq_d_va[i]  = xp_va[i];
      xq_d_llc[i] = xp_llc[i];
    end
    xq_d_cnt = n_p;
    if (gen_step_xp && !dup) begin
      if (n_p == 4'(XQN)) begin
        for (int i = 0; i < XQN - 1; i++) begin
          xq_d_va[i]  = xp_va[i + 1];
          xq_d_llc[i] = xp_llc[i + 1];
        end
        xq_d_va[XQN - 1]  = new_va;
        xq_d_llc[XQN - 1] = new_llc;
      end else begin
        xq_d_va[n_p[2:0]]  = new_va;
        xq_d_llc[n_p[2:0]] = new_llc;
        xq_d_cnt           = n_p + 4'd1;
      end
    end
  end

  // ---------------- 4. Registers ----------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      gen_mask_q <= '0;
      gen_left_q <= '0;
      xq_cnt_q   <= '0;
      xa_cnt_q   <= '0;
    end else begin
      // gen update: step first, then new trigger overrides
      if (trig_go) begin
        gen_mask_q  <= trig_mask;
        gen_left_q  <= 4'(DEG);
        gen_vline_q <= trig_vline;
        gen_ppn_q   <= trig_ppn;
        gen_vaneg_q <= trig_vaneg;
        for (int m = 0; m < 16; m++) begin
          gen_d_q[m]   <= trig_d[m];
          gen_st_q[m]  <= trig_st[m];
          gen_cov_q[m] <= trig_cov[m];
        end
      end else if (gen_step_sp || gen_step_xp) begin
        gen_mask_q[best_m] <= 1'b0;
        gen_left_q         <= gen_left_q - 4'd1;
      end

      // xq update
      xq_cnt_q <= xq_d_cnt;
      for (int i = 0; i < XQN; i++) begin
        xq_va_q[i]  <= xq_d_va[i];
        xq_llc_q[i] <= xq_d_llc[i];
      end

      // xans_q update (pop 1 if xa_pop)
      if (xa_pop) begin
        xa_cnt_q <= xa_p_cnt - 4'd1;
        for (int i = 0; i < XAN - 1; i++) begin
          xa_line_q[i] <= xa_p_line[i + 1];
          xa_llc_q[i]  <= xa_p_llc[i + 1];
        end
      end else begin
        xa_cnt_q <= xa_p_cnt;
        for (int i = 0; i < XAN; i++) begin
          xa_line_q[i] <= xa_p_line[i];
          xa_llc_q[i]  <= xa_p_llc[i];
        end
      end
    end
  end
endmodule

`default_nettype wire
