`default_nettype none
// Ref: axi-interconnect-kit/axi_interconnect/AXI_LLC.cpp  bop_q / bingo_q (deduplicated push_back, pop_front when full)
// LLC prefetch candidate queue (BOP_Q = 8 in axi_llc_bop, BINGO_Q = 16 in axi_llc_bingo): an N-entry FIFO of line
// addresses, oldest at index 0, deduplicated (a candidate already in the queue is not pushed), drops the oldest entry
// when a new candidate arrives into a full queue.
//   * pop removes the head this cycle; the caller issues it only when the queue is not empty (!empty).
//   * up to NCAND candidate lines are presented; their duplicate checks against the post-pop queue run in parallel
//     (they do not wait for the selection), cand_sel picks the one that is pushed when push_v.
//   * RST_LINES = 1 also resets the line registers (BOP); 0 leaves them without reset (Bingo: read only below cnt).
module axi_llc_pfq #(
  parameter int N         = 8,
  parameter int NCAND     = 1,
  parameter int W         = 26,
  parameter bit RST_LINES = 1'b1,
  parameter int SELW      = (NCAND > 1) ? $clog2(NCAND) : 1   // derived: leave at the default
) (
  input  logic            clk,
  input  logic            rst_n,
  input  logic            pop,
  input  logic            push_v,
  input  logic [W-1:0]    cand_line [NCAND],
  input  logic [SELW-1:0] cand_sel,
  output logic            empty,
  output logic [W-1:0]    head
);
  localparam int CW = $clog2(N + 1);   // count 0..N
  localparam int IW = $clog2(N);

  logic [W-1:0]  q_line_q [N], q_p [N], q_d [N];
  logic [CW-1:0] q_cnt_q, cnt_p, cnt_d;
  logic [NCAND-1:0] dup_v;
  logic          q_push;

  assign empty = (q_cnt_q == '0);
  assign head  = q_line_q[0];

  always_comb begin
    for (int i = 0; i < N; i++) q_p[i] = (pop && (i + 1 < N)) ? q_line_q[i + 1] : q_line_q[i];
    cnt_p = pop ? (q_cnt_q - CW'(1)) : q_cnt_q;

    for (int c = 0; c < NCAND; c++) begin
      dup_v[c] = 1'b0;
      for (int i = 0; i < N; i++) if ((CW'(i) < cnt_p) && (q_p[i] == cand_line[c])) dup_v[c] = 1'b1;
    end
    q_push = push_v && !dup_v[cand_sel];

    for (int i = 0; i < N; i++) q_d[i] = q_p[i];
    cnt_d = cnt_p;
    if (q_push) begin
      if (cnt_p == CW'(N)) begin
        for (int i = 0; i < N - 1; i++) q_d[i] = q_p[i + 1];
        q_d[N - 1] = cand_line[cand_sel];
      end else begin
        q_d[cnt_p[IW-1:0]] = cand_line[cand_sel];
        cnt_d = cnt_p + CW'(1);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) q_cnt_q <= '0;
    else        q_cnt_q <= cnt_d;
  end

  if (RST_LINES) begin : g_rst
    always_ff @(posedge clk) begin
      if (!rst_n) for (int i = 0; i < N; i++) q_line_q[i] <= '0;
      else        for (int i = 0; i < N; i++) q_line_q[i] <= q_d[i];
    end
  end else begin : g_nrst
    always_ff @(posedge clk) begin
      for (int i = 0; i < N; i++) q_line_q[i] <= q_d[i];
    end
  end
endmodule
`default_nettype wire
