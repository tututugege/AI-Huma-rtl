// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_cal, comb_lsu2dis, comb_lsu2rob: start-of-cycle view for Dispatch/ROB)
`default_nettype none

module lsu_cur_info
  import lsu_pkg::*;
(
  input  ld_state_t        ld_st_q [LQ],
  input  st_state_t        st_st_q [SQ],
  input  logic [RIW-1:0]   stq_head_q,
  input  logic             stq_head_flag_q,
  input  logic [RCW-1:0]   stq_count_q,
  input  logic [RCW-1:0]   stq_ccount_q,
  input  logic [RCW-1:0]   wait_mmu_ldq_count_q,
  input  logic [RCW-1:0]   wait_mmu_stq_count_q,
  input  logic [RCW-1:0]   mmu_done_count_q,
  output logic [RIW-1:0]   lsu2dis_stq_tail,
  output logic             lsu2dis_stq_tail_flag,
  output logic [RCW-1:0]   lsu2dis_stq_free,
  output logic [RCW-1:0]   lsu2dis_ldq_free,
  output logic [NDIS-1:0]  lsu2dis_ldq_alloc_valid,
  output logic [RIW-1:0]   lsu2dis_ldq_alloc_idx [NDIS],
  output logic             lsu2rob_committed_store_pending
);

  localparam int AW = RCW + 2;   // room for count sums

  logic [LQ-1:0]  ld_is_alloc, ld_is_empty;
  logic [SQ-1:0]  st_is_alloc_slot, st_is_alloc_pos, st_alloc_in_win;
  logic [RCW-1:0] ldq_alloc_cnt, ldq_empty_cnt, stq_alloc_cnt;
  logic [RCW-1:0] empty_rank [LQ];
  logic [RCW-1:0] done_or_wait;
  logic [AW-1:0]  ldq_busy, stq_busy;
  logic [RCW-1:0] ldq_free_by_busy, stq_free_by_busy, stq_free_by_count;
  logic [RIW:0]   tail_sum;

  for (genvar i = 0; i < LQ; i++) begin : g_ld
    assign ld_is_alloc[i] = ld_st_q[i] == LD_ALLOCATED;
    assign ld_is_empty[i] = ld_st_q[i] == LD_EMPTY;
  end
  for (genvar i = 0; i < SQ; i++) begin : g_st
    assign st_is_alloc_slot[i] = st_st_q[i] == ST_ALLOCATED;
  end
  assign st_is_alloc_pos = rotr_rn(st_is_alloc_slot, stq_head_q);

  ttg_popcount #(.N(LQ), .CW(RCW)) u_alloc_cnt (.bits(ld_is_alloc), .count(ldq_alloc_cnt));
  lsu_rank #(.N(LQ), .CW(RCW)) u_empty_rank (.bits(ld_is_empty), .rank(empty_rank));
  ttg_popcount #(.N(LQ), .CW(RCW)) u_empty_cnt (.bits(ld_is_empty), .count(ldq_empty_cnt));

  // Allocated entries inside [head, head + count)
  for (genvar p = 0; p < SQ; p++) begin : g_inwin
    assign st_alloc_in_win[p] = st_is_alloc_pos[p] && stq_count_q > RCW'(p);
  end
  ttg_popcount #(.N(SQ), .CW(RCW)) u_stq_alloc (.bits(st_alloc_in_win), .count(stq_alloc_cnt));

  // C++: uint32 free = SIZE - allocated - wait_mmu_count; free = min(free, other).  The subtraction wraps for
  // allocated + wait_mmu_count > SIZE (wait_mmu counts include holes): then the other operand wins.
  assign done_or_wait = wait_mmu_stq_count_q > mmu_done_count_q ? wait_mmu_stq_count_q : mmu_done_count_q;
  assign ldq_busy = AW'(ldq_alloc_cnt) + AW'(wait_mmu_ldq_count_q);
  assign stq_busy = AW'(stq_alloc_cnt) + AW'(done_or_wait);
  assign ldq_free_by_busy  = RCW'(AW'(LQ) - ldq_busy);
  assign stq_free_by_busy  = RCW'(AW'(SQ) - stq_busy);
  assign stq_free_by_count = RCW'(SQ) - stq_count_q;

  always_comb begin
    lsu2dis_ldq_free = ldq_empty_cnt;
    if (ldq_busy <= AW'(LQ) && ldq_free_by_busy < ldq_empty_cnt) lsu2dis_ldq_free = ldq_free_by_busy;
    lsu2dis_stq_free = stq_free_by_count;
    if (stq_busy <= AW'(SQ) && stq_free_by_busy < stq_free_by_count) lsu2dis_stq_free = stq_free_by_busy;
  end

  // the k-th Empty LDQ entry, offered to Dispatch while k < ldq_free
  always_comb begin
    for (int k = 0; k < NDIS; k++) begin
      lsu2dis_ldq_alloc_valid[k] = RCW'(k) < lsu2dis_ldq_free;
      lsu2dis_ldq_alloc_idx[k]   = '0;
      for (int i = 0; i < LQ; i++)
        if (ld_is_empty[i] && empty_rank[i] == RCW'(k)) lsu2dis_ldq_alloc_idx[k] = RIW'(i);
    end
  end

  assign tail_sum                        = {1'b0, stq_head_q} + stq_count_q[RIW:0];
  assign lsu2dis_stq_tail                = tail_sum[RIW-1:0];
  assign lsu2dis_stq_tail_flag           = tail_sum[RIW] ? !stq_head_flag_q : stq_head_flag_q;
  assign lsu2rob_committed_store_pending = stq_ccount_q != '0;

endmodule

`default_nettype wire
