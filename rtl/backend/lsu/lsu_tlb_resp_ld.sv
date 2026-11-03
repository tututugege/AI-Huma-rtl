// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_tlb_in_ldq: MMU responses for loads, then the wait_mmu_ldq window)
`default_nettype none

// I: (1) MMU responses -> tr events (the wait_mmu slot must still hold the entry, the entry must still be WaitTlb;
// otherwise the slot is invalidated); (2) window over the still valid wait_mmu_ldq entries: WaitSTLF enters the STLF
// queue, WaitFinish enters the finish queue, WaitTlbRetry asks the MMU again.
module lsu_tlb_resp_ld
  import lsu_pkg::*;
(
  input  logic [NLD-1:0]   rsp_valid,
  input  logic [31:0]      rsp_paddr     [NLD],
  input  logic [1:0]       rsp_result    [NLD],
  input  logic [LQW-1:0]   rsp_entry_idx [NLD],
  input  logic [RIW-1:0]   rsp_wait_idx  [NLD],
  input  logic [RN-1:0]    wmld_g_valid,          // wait_mmu_ldq after the AGU appends
  input  logic [RN-1:0][RIW-1:0] wmld_g_idx,
  input  lsu_ring_t        wmld_k,                // ... after the stale-slot kills of this stage
  input  logic [RCW-1:0]   stlf_count,
  input  logic [RCW-1:0]   fin_count,             // finish queue count after the write-back pops
  input  ld_state_t        ld_st_agu     [LQ],
  input  ld_state_t        ld_st_tlb     [LQ],    // state after the responses (window scan)
  output ldq_tr_t          tr_ev         [LQ],
  output ldq_tw_t          tw_ev         [LQ],
  output lsu_rop_t         wmld_kill_op,
  output lsu_rop_t         wmld_kp_op,
  output lsu_rop_t         stlf_op,
  output lsu_rop_t         fin_op,
  output logic             lrsc_clear
);

  // ---- 1. responses ----
  logic [NLD-1:0] slot_ok, act, kill_slot_port, pf_port;
  for (genvar i = 0; i < NLD; i++) begin : g_port
    assign slot_ok[i]        = rsp_valid[i] && wmld_g_valid[rsp_wait_idx[i]] &&
                               wmld_g_idx[rsp_wait_idx[i]] == rsp_entry_idx[i];
    assign act[i]            = slot_ok[i] && ld_st_agu[rsp_entry_idx[i]] == LD_WAIT_TLB;
    assign kill_slot_port[i] = slot_ok[i] && ld_st_agu[rsp_entry_idx[i]] != LD_WAIT_TLB;
    assign pf_port[i]        = rsp_result[i] == MMU_PAGE_FAULT;
  end
  assign lrsc_clear = |(act & pf_port);

  logic [RN-1:0] kill_slot;
  for (genvar s = 0; s < RN; s++) begin : g_kill
    logic [NLD-1:0] by_port;
    for (genvar i = 0; i < NLD; i++) begin : g_p
      assign by_port[i] = kill_slot_port[i] && rsp_wait_idx[i] == RIW'(s);
    end
    assign kill_slot[s] = |by_port;
  end
  assign wmld_kill_op = '{kill_slot: kill_slot, default: '0};

  for (genvar e = 0; e < LQ; e++) begin : g_tr
    logic [NLD-1:0] sel;
    for (genvar i = 0; i < NLD; i++) begin : g_p
      assign sel[i] = act[i] && rsp_entry_idx[i] == LQW'(e);
    end
    always_comb begin
      tr_ev[e] = '0;
      for (int i = NLD - 1; i >= 0; i--) begin
        if (sel[i]) begin
          tr_ev[e].go    = 1'b1;
          tr_ev[e].res   = rsp_result[i];
          tr_ev[e].paddr = rsp_paddr[i];
        end
      end
    end
  end

  // ---- 2. window over the (still valid) wait_mmu_ldq entries ----
  logic [WIN-1:0] valid_w, cand_stlf, cand_fin, acc_stlf, acc_fin, is_retry;
  logic [RIW-1:0] idx_w [WIN];
  logic [RCW-1:0] rank_stlf [WIN], rank_fin [WIN];

  lsu_ring_win u_win (.ring(wmld_k), .valid_w(valid_w), .idx_w(idx_w));
  for (genvar p = 0; p < WIN; p++) begin : g_cand
    assign cand_stlf[p] = valid_w[p] && ld_st_tlb[idx_w[p]] == LD_WAIT_STLF;
    assign cand_fin[p]  = valid_w[p] && ld_st_tlb[idx_w[p]] == LD_WAIT_FINISH;
    assign is_retry[p]  = valid_w[p] && ld_st_tlb[idx_w[p]] == LD_WAIT_TLB_RETRY;
  end
  lsu_rank #(.N(WIN), .CW(RCW)) u_rank_stlf (.bits(cand_stlf), .rank(rank_stlf));
  lsu_rank #(.N(WIN), .CW(RCW)) u_rank_fin  (.bits(cand_fin),  .rank(rank_fin));
  for (genvar p = 0; p < WIN; p++) begin : g_acc
    assign acc_stlf[p] = cand_stlf[p] && rank_stlf[p] < RCW'(NLD) && stlf_count + rank_stlf[p] < RCW'(LQ);
    assign acc_fin[p]  = cand_fin[p]  && rank_fin[p]  < RCW'(NLD) && fin_count + rank_fin[p] < RCW'(LQ);
  end

  for (genvar e = 0; e < LQ; e++) begin : g_tw
    logic [WIN-1:0] to_stlf, to_fin, to_retry;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign to_stlf[p]  = acc_stlf[p] && idx_w[p] == RIW'(e);
      assign to_fin[p]   = acc_fin[p]  && idx_w[p] == RIW'(e);
      assign to_retry[p] = is_retry[p] && idx_w[p] == RIW'(e);
    end
    assign tw_ev[e].stlf  = |to_stlf;
    assign tw_ev[e].fin   = |to_fin;
    assign tw_ev[e].retry = |to_retry;
  end

  logic [WIN-1:0][RIW-1:0] idx_pk;
  for (genvar p = 0; p < WIN; p++) begin : g_pk
    assign idx_pk[p] = idx_w[p];
  end
  assign stlf_op    = rop_app(acc_stlf, idx_pk);
  assign fin_op     = rop_app(acc_fin, idx_pk);
  assign wmld_kp_op = rop_kp(valid_w & ~(acc_stlf | acc_fin));

endmodule

`default_nettype wire
