// SVA checker bound to ren_core (simulation/formal only; never included in synthesis)
`default_nettype none

module sva_ren
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N = DECODE_WIDTH,
  parameter int C = COMMIT_WIDTH
) (
  input logic         clk,
  input logic         rst_n,
  input preg_t        free_count,
  input logic [N-1:0] alloc_req,
  input logic [N-1:0] alloc_valid,
  input logic [N-1:0] fire,
  input logic [N-1:0] elim,
  input logic         walk_active,
  input logic         rob_flush,
  input logic         dec_mispred
);

  // ---- Core microarchitectural invariants ----
  a_ren_freecnt_bounds: assert property (@(posedge clk) disable iff (!rst_n)
    int'(free_count) <= PRF_NUM)
    else $error("[SVA_REN] free_count=%0d exceeds PRF_NUM=%0d", free_count, PRF_NUM);

  // Never fire normal rename while forward-walk recovery is active
  a_ren_no_fire_during_walk: assert property (@(posedge clk) disable iff (!rst_n)
    walk_active |-> (fire == '0))
    else $error("[SVA_REN] rename fire=%b while walk_active=1", fire);

  // Never allocate a free register for a slot that did not request one
  for (genvar i = 0; i < N; i++) begin : g_alloc
    a_ren_alloc_implies_req: assert property (@(posedge clk) disable iff (!rst_n)
      alloc_valid[i] |-> alloc_req[i])
      else $error("[SVA_REN] slot %0d alloc_valid=1 without alloc_req", i);
  end

  // ---- Functional coverage points ----
  c_ren_fire_full: cover property (@(posedge clk) disable iff (!rst_n) &fire);
  c_ren_walk:      cover property (@(posedge clk) disable iff (!rst_n) walk_active);
  c_ren_elim:      cover property (@(posedge clk) disable iff (!rst_n) |(fire & elim));
  c_ren_flush:     cover property (@(posedge clk) disable iff (!rst_n) rob_flush);
  c_ren_mispred:   cover property (@(posedge clk) disable iff (!rst_n) dec_mispred);

endmodule

`default_nettype wire
