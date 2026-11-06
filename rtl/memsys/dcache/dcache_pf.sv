`default_nettype none
// Ref: MemSubSystem/include/DataPrefetcher.h  DataPrefetcher (trace-model exp/prefetch-h1), docs/modules/dcache_pf.md
// L1D data prefetcher h1: single global stride entry, stride burst generator (degree 8, distance 2, in-page), LLC-only
// next-line generator, 8-entry request FIFO.  Everything is registered; the FIFO head is the tag-probe candidate of
// dcache_s1.  One DataPrefetcher::seq() per clock: pop, stride generator, LLC generator, training of last cycle's
// events, selection of this cycle's events.
module dcache_pf
  import dcache_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,
  // FIFO head (probe candidate)
  output logic                 head_valid,
  output logic [LINE_W-1:0]    head_line,
  output logic                 head_llc,
  input  logic                 head_taken,
  // access events of this cycle (stage 2 of the load ports)
  input  logic [NLD-1:0]       acc_valid,
  input  logic [LINE_W-1:0]    acc_line  [NLD],
  input  logic [NLD-1:0]       acc_miss,
  input  logic [NLD-1:0]       acc_pf_hit
);

  localparam int QD      = 8;
  localparam int QW      = 3;
  localparam int SB      = 8;     // stride bits
  localparam int DEGREE  = 8;
  localparam int DIST    = 2;
  localparam int NTR     = 2;     // training events per cycle
  localparam int PG_W    = LINE_W - 6;

  // ---------------------------------------------------------------- state
  logic [LINE_W-1:0] q_line_q [QD];
  logic [QD-1:0]     q_llc_q;
  logic [QW-1:0]     q_head_q;
  logic [QW:0]       q_cnt_q;

  logic              st_valid_q;
  logic [LINE_W-1:0] st_last_q;
  logic [SB-1:0]     st_stride_q;
  logic [1:0]        st_conf_q;

  logic              g_valid_q;
  logic [LINE_W-1:0] g_next_q, g_base_q;
  logic [SB-1:0]     g_stride_q;
  logic [3:0]        g_left_q;

  logic              g2_valid_q;
  logic [LINE_W-1:0] g2_next_q, g2_base_q;     // one line per trigger: left is implicitly 1

  logic [NTR-1:0]    in_valid_q, in_miss_q;
  logic [LINE_W-1:0] in_line_q [NTR];

  assign head_valid = q_cnt_q != '0;
  assign head_line  = q_line_q[q_head_q];
  assign head_llc   = q_llc_q[q_head_q];

  function automatic logic [LINE_W-1:0] sx(input logic [SB-1:0] s);
    return {{(LINE_W - SB){s[SB-1]}}, s};
  endfunction

  // ---------------------------------------------------------------- next state
  logic [QW:0]       cnt_a;       // after the pop
  logic [QW-1:0]     head_a;
  logic              push_en, push_llc;
  logic [LINE_W-1:0] push_line;
  logic              dup;

  logic              g_valid_d, g2_valid_d, st_valid_d;
  logic [LINE_W-1:0] g_next_d, g_base_d, g2_next_d, g2_base_d, st_last_d;
  logic [SB-1:0]     g_stride_d, st_stride_d;
  logic [3:0]        g_left_d;
  logic [1:0]        st_conf_d;
  logic              port_used;
  logic              g_valid_s, g2_valid_s;
  logic [LINE_W-1:0] g_next_s, g_base_s, g2_next_s, g2_base_s;
  logic [SB-1:0]     g_stride_s;
  logic [3:0]        g_left_s;

  always_comb begin
    cnt_a  = q_cnt_q - (QW+1)'(head_taken);
    head_a = q_head_q + QW'(head_taken);
    g_valid_s = g_valid_q;  g_next_s = g_next_q;  g_base_s = g_base_q;  g_stride_s = g_stride_q;  g_left_s = g_left_q;
    g2_valid_s = g2_valid_q; g2_next_s = g2_next_q; g2_base_s = g2_base_q;
    push_en = 1'b0; push_line = '0; push_llc = 1'b0;
    port_used = 1'b0;

    // 1. stride generator: one candidate per cycle, in the page of its base, de-duplicated against the FIFO
    if (g_valid_q) begin
      port_used = 1'b1;
      if (g_next_q[LINE_W-1:6] != g_base_q[LINE_W-1:6]) begin
        g_valid_s = 1'b0;
      end else begin
        push_en   = 1'b1;
        push_line = g_next_q;
        push_llc  = 1'b0;
        g_next_s  = g_next_q + sx(g_stride_q);
        g_left_s  = g_left_q - 4'd1;
        if (g_left_q == 4'd1) g_valid_s = 1'b0;
      end
    end
    // 2. LLC next-line generator uses the FIFO write port only when the stride generator did not
    if (!port_used && g2_valid_q) begin
      if (g2_next_q[LINE_W-1:6] != g2_base_q[LINE_W-1:6]) begin
        g2_valid_s = 1'b0;
      end else begin
        push_en    = 1'b1;
        push_line  = g2_next_q;
        push_llc   = 1'b1;
        g2_valid_s = 1'b0;                   // left was 1
      end
    end
  end

  always_comb begin
    // duplicate: line already in the FIFO (entries after the pop)
    dup = 1'b0;
    for (int e = 0; e < QD; e++) begin
      logic [QW-1:0] pos;
      pos = QW'(e) - head_a;
      if ((QW+1)'(pos) < cnt_a && q_line_q[e] == push_line) dup = 1'b1;
    end

  end

  // 3. training of the events registered last cycle (sequential over the NTR events, after the generator steps)
  always_comb begin
    g_valid_d = g_valid_s; g_next_d = g_next_s; g_base_d = g_base_s; g_stride_d = g_stride_s; g_left_d = g_left_s;
    g2_valid_d = g2_valid_s; g2_next_d = g2_next_s; g2_base_d = g2_base_s;
    st_valid_d = st_valid_q; st_last_d = st_last_q; st_stride_d = st_stride_q; st_conf_d = st_conf_q;
    for (int k = 0; k < NTR; k++) begin
      if (in_valid_q[k]) begin
        logic [LINE_W-1:0] line, d;
        logic              in_range;
        logic signed [LINE_W-1:0] ds;
        logic [SB-1:0]     cur;
        line = in_line_q[k];
        if (in_miss_q[k]) begin
          g2_valid_d = 1'b1; g2_base_d = line; g2_next_d = line + LINE_W'(1);
        end
        if (!st_valid_d) begin
          st_valid_d = 1'b1; st_last_d = line; st_stride_d = '0; st_conf_d = '0;
        end else begin
          d  = line - st_last_d;
          ds = $signed(d);
          if (d != '0) begin
            in_range = (ds >= -(1 <<< (SB-1))) && (ds < (1 <<< (SB-1)));
            cur = st_stride_d;
            if (in_range && d[SB-1:0] == cur) begin
              if (st_conf_d != 2'd3) st_conf_d = st_conf_d + 2'd1;
            end else if (st_conf_d != 2'd0) begin
              st_conf_d = st_conf_d - 2'd1;
              if (st_conf_d == 2'd0 && in_range) st_stride_d = d[SB-1:0];
            end else begin
              st_stride_d = in_range ? d[SB-1:0] : '0;
            end
            st_last_d = line;
            if (st_conf_d >= 2'd2 && st_stride_d != '0) begin
              g_valid_d  = 1'b1;
              g_base_d   = line;
              g_stride_d = st_stride_d;
              g_next_d   = line + {sx(st_stride_d)[LINE_W-2:0], 1'b0};   // DIST = 2
              g_left_d   = 4'(DEGREE);
            end
          end
        end
      end
    end
  end

  // 4. event selection: the first NTR load ports whose access is a miss or the first use of a prefetched line
  logic [NTR-1:0]    sel_valid, sel_miss;
  logic [LINE_W-1:0] sel_line [NTR];
  always_comb begin
    int n;
    n = 0;
    sel_valid = '0; sel_miss = '0;
    for (int k = 0; k < NTR; k++) sel_line[k] = '0;
    for (int i = 0; i < NLD; i++) begin
      if (acc_valid[i] && (acc_miss[i] || acc_pf_hit[i]) && n < NTR) begin
        sel_valid[n] = 1'b1;
        sel_miss[n]  = acc_miss[i];
        sel_line[n]  = acc_line[i];
        n++;
      end
    end
  end

  // ---------------------------------------------------------------- registers
  logic do_push;
  assign do_push = push_en && !dup && cnt_a != (QW+1)'(QD);
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      q_head_q <= '0; q_cnt_q <= '0; q_llc_q <= '0;
      st_valid_q <= 1'b0; g_valid_q <= 1'b0; g2_valid_q <= 1'b0; in_valid_q <= '0;
    end else begin
      q_head_q   <= head_a;
      q_cnt_q    <= cnt_a + (QW+1)'(do_push);
      st_valid_q <= st_valid_d;
      g_valid_q  <= g_valid_d;
      g2_valid_q <= g2_valid_d;
      in_valid_q <= sel_valid;
    end
    if (do_push) begin
      q_line_q[QW'(head_a + QW'(cnt_a))] <= push_line;
      q_llc_q[QW'(head_a + QW'(cnt_a))]  <= push_llc;
    end
    st_last_q <= st_last_d; st_stride_q <= st_stride_d; st_conf_q <= st_conf_d;
    g_next_q <= g_next_d; g_base_q <= g_base_d; g_stride_q <= g_stride_d; g_left_q <= g_left_d;
    g2_next_q <= g2_next_d; g2_base_q <= g2_base_d;
    in_miss_q <= sel_miss;
    for (int k = 0; k < NTR; k++) in_line_q[k] <= sel_line[k];
  end

endmodule
`default_nettype wire
