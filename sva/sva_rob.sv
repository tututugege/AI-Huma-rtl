// SVA checker bound to rob_core (simulation/formal only; never included in synthesis)
`default_nettype none

module sva_rob
  import ttg_cfg_pkg::*;
  import rob_pkg::*;
(
  input logic                     clk,
  input logic                     rst_n,
  input logic [ROB_IDX_WIDTH:0]   count_q,
  input logic [ROB_LINE_NUM-1:0]  head_oh_q,
  input logic [ROB_BANK_NUM-1:0]  hb_oh_q,
  input logic                     rob2dis_empty,
  input logic [ROB_IDX_WIDTH:0]   rob2dis_free,
  input logic [ROB_BANK_NUM-1:0]  commit_valid,
  input logic                     bcast_flush,
  input logic                     bcast_exception,
  input logic                     bcast_interrupt,
  input logic                     dec_mispred
);

  // ---- Core microarchitectural invariants ----
  a_rob_count_bounds: assert property (@(posedge clk) disable iff (!rst_n)
    count_q <= (ROB_IDX_WIDTH+1)'(ROB_NUM))
    else $error("[SVA_ROB] count_q=%0d exceeds ROB_NUM=%0d", count_q, ROB_NUM);

  a_rob_empty_match: assert property (@(posedge clk) disable iff (!rst_n)
    rob2dis_empty == (count_q == '0))
    else $error("[SVA_ROB] rob2dis_empty=%0b disagrees with count_q=%0d", rob2dis_empty, count_q);

  a_rob_free_match: assert property (@(posedge clk) disable iff (!rst_n)
    rob2dis_free == ((ROB_IDX_WIDTH+1)'(ROB_NUM) - count_q))
    else $error("[SVA_ROB] rob2dis_free=%0d != ROB_NUM - count_q (%0d)", rob2dis_free, count_q);

  a_rob_head_oh: assert property (@(posedge clk) disable iff (!rst_n)
    $onehot(head_oh_q))
    else $error("[SVA_ROB] head_oh_q=%b is not one-hot", head_oh_q);

  a_rob_hb_oh: assert property (@(posedge clk) disable iff (!rst_n)
    $onehot(hb_oh_q))
    else $error("[SVA_ROB] hb_oh_q=%b is not one-hot", hb_oh_q);

  // commit_valid must be a contiguous prefix from slot 0 (no holes)
  for (genvar k = 1; k < ROB_BANK_NUM; k++) begin : g_prefix
    a_rob_commit_prefix: assert property (@(posedge clk) disable iff (!rst_n)
      commit_valid[k] |-> commit_valid[k-1])
      else $error("[SVA_ROB] commit_valid=%b has hole at slot %0d", commit_valid, k);
  end

  // Flush / exception / interrupt must retire at most slot 0 (no younger instruction retires in same cycle)
  a_rob_single_trap: assert property (@(posedge clk) disable iff (!rst_n)
    (bcast_flush || bcast_exception || bcast_interrupt) |-> (commit_valid[ROB_BANK_NUM-1:1] == '0))
    else $error("[SVA_ROB] multi-commit %b during flush=%0b exc=%0b irq=%0b",
                commit_valid, bcast_flush, bcast_exception, bcast_interrupt);

  // ---- Functional coverage points ----
  c_rob_full:     cover property (@(posedge clk) disable iff (!rst_n) count_q == (ROB_IDX_WIDTH+1)'(ROB_NUM));
  c_rob_commit8:  cover property (@(posedge clk) disable iff (!rst_n) &commit_valid);
  c_rob_flush:    cover property (@(posedge clk) disable iff (!rst_n) bcast_flush);
  c_rob_mispred:  cover property (@(posedge clk) disable iff (!rst_n) dec_mispred);
  c_rob_irq:      cover property (@(posedge clk) disable iff (!rst_n) bcast_interrupt);

endmodule

`default_nettype wire
