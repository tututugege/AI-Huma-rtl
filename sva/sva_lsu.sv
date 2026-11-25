// SVA checker bound to lp_core (LSU pipeline; simulation/formal only)
`default_nettype none

module sva_lsu
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input logic            clk,
  input logic            rst_n,
  input logic [CNTW-1:0] count_q,
  input logic [CNTW-1:0] ccount_q,
  input logic [CNTW-1:0] o_stq_free,
  input logic [CNTW-1:0] o_ldq_free,
  input logic            o_committed_store_pending,
  input logic            unc_valid_q,
  input logic            rsv_valid_q
);

  // ---- Core microarchitectural invariants ----
  a_lsu_stq_bounds: assert property (@(posedge clk) disable iff (!rst_n)
    int'(count_q) <= SQ)
    else $error("[SVA_LSU] STQ count_q=%0d exceeds SQ=%0d", count_q, SQ);

  a_lsu_ccount_le_count: assert property (@(posedge clk) disable iff (!rst_n)
    ccount_q <= count_q)
    else $error("[SVA_LSU] STQ committed count ccount_q=%0d > count_q=%0d", ccount_q, count_q);

  a_lsu_stq_free_bounds: assert property (@(posedge clk) disable iff (!rst_n)
    int'(o_stq_free) <= SQ)
    else $error("[SVA_LSU] o_stq_free=%0d exceeds SQ=%0d", o_stq_free, SQ);

  a_lsu_ldq_free_bounds: assert property (@(posedge clk) disable iff (!rst_n)
    int'(o_ldq_free) <= LQ)
    else $error("[SVA_LSU] o_ldq_free=%0d exceeds LQ=%0d", o_ldq_free, LQ);

  a_lsu_cmt_pending_match: assert property (@(posedge clk) disable iff (!rst_n)
    o_committed_store_pending == (ccount_q != '0))
    else $error("[SVA_LSU] o_committed_store_pending=%0b disagrees with ccount_q=%0d",
                o_committed_store_pending, ccount_q);

  // ---- Functional coverage points ----
  c_lsu_stq_full:    cover property (@(posedge clk) disable iff (!rst_n) int'(count_q) == SQ);
  c_lsu_ldq_full:    cover property (@(posedge clk) disable iff (!rst_n) o_ldq_free == '0);
  c_lsu_cmt_pending: cover property (@(posedge clk) disable iff (!rst_n) o_committed_store_pending);
  c_lsu_mmio_active: cover property (@(posedge clk) disable iff (!rst_n) unc_valid_q);
  c_lsu_lrsc_rsv:    cover property (@(posedge clk) disable iff (!rst_n) rsv_valid_q);

endmodule

`default_nettype wire
