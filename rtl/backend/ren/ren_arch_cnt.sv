// Ref: back-end/Ren.cpp  class Ren  arch_cnt, Ren::comb_fire (commit part with move elimination)
`default_nettype none

// Move elimination: how many architectural RAT entries name each physical register. A commit slot adds one for its
// dest_preg and removes one from its old_dest_preg; the old register goes back to the free list when its count
// reaches zero. Slots are processed in order within a cycle (an older slot's increment/decrement is visible to a
// younger slot), so "slot k frees its old register" means: the count of old_preg[k] after slots 0..k is zero.
// (An old register is never re-referenced after it reaches zero within the same cycle: a younger move would have had
// to read it from the speculative RAT after the older overwrite, and it reads the overwriter's register instead.)
module ren_arch_cnt
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int C  = COMMIT_WIDTH,
  parameter int CW = $clog2(C + 1)
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic [C-1:0]  reclaim,          // slot retires a destination (no exception, no interrupt)
  input  preg_t         dest_preg [C],
  input  preg_t         old_preg [C],
  output logic [C-1:0]  free              // slot returns its old register to the free list
);

  localparam int AW = CNT_W + CW + 1;

  cnt_t cnt_q [PRF_NUM];
  cnt_t cnt_d [PRF_NUM];

  // ---- which slots free their old register ----
  for (genvar k = 0; k < C; k++) begin : g_slot
    logic [C-1:0]  inc_hit, dec_hit;
    logic [CW-1:0] n_inc, n_dec;
    logic [AW-1:0] after;
    for (genvar j = 0; j < C; j++) begin : g_older
      if (j <= k) begin : g_yes
        assign inc_hit[j] = reclaim[j] & (dest_preg[j] == old_preg[k]);
        assign dec_hit[j] = reclaim[j] & (old_preg[j] == old_preg[k]);
      end else begin : g_no
        assign inc_hit[j] = 1'b0;
        assign dec_hit[j] = 1'b0;
      end
    end
    ttg_popcount #(.N(C)) u_inc (.bits(inc_hit), .count(n_inc));
    ttg_popcount #(.N(C)) u_dec (.bits(dec_hit), .count(n_dec));
    assign after = AW'(cnt_q[old_preg[k]]) + AW'(n_inc) - AW'(n_dec);
    assign free[k] = reclaim[k] & (after == '0);
  end

  // ---- counters ----
  for (genvar p = 0; p < PRF_NUM; p++) begin : g_cnt
    logic [C-1:0]  inc_p, dec_p;
    logic [CW-1:0] n_inc, n_dec;
    for (genvar k = 0; k < C; k++) begin : g_hit
      assign inc_p[k] = reclaim[k] & (dest_preg[k] == preg_t'(p));
      assign dec_p[k] = reclaim[k] & (old_preg[k] == preg_t'(p));
    end
    ttg_popcount #(.N(C)) u_inc (.bits(inc_p), .count(n_inc));
    ttg_popcount #(.N(C)) u_dec (.bits(dec_p), .count(n_dec));
    assign cnt_d[p] = cnt_t'(AW'(cnt_q[p]) + AW'(n_inc) - AW'(n_dec));
  end

  always_ff @(posedge clk) begin
    for (int p = 0; p < PRF_NUM; p++) begin
      if (!rst_n) cnt_q[p] <= (p < RAT_NUM) ? cnt_t'(1) : cnt_t'(0);
      else        cnt_q[p] <= cnt_d[p];
    end
  end

endmodule

`default_nettype wire
