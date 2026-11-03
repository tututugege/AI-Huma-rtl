// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_tlb_in_stq: MMU responses for stores, then the wait_mmu_stq window)
`default_nettype none

// I: (1) MMU responses (only entries still in WaitTlb whose wait_mmu slot is intact are touched);
// (2) window over wait_mmu_stq: WaitDone enters mmu_done, WaitData just leaves the queue, WaitTlbRetry asks again.
module lsu_tlb_resp_st
  import lsu_pkg::*;
(
  input  logic [NST-1:0]   rsp_valid,
  input  logic [31:0]      rsp_paddr     [NST],
  input  logic [1:0]       rsp_result    [NST],
  input  logic [SQW-1:0]   rsp_entry_idx [NST],
  input  logic [RIW-1:0]   rsp_wait_idx  [NST],
  input  lsu_ring_t        wmst_g,                // wait_mmu_stq after the STA appends
  input  st_state_t        st_exe        [SQ],
  input  st_state_t        st_tlb        [SQ],    // state after the responses (window scan)
  output stq_tr_t          tr_ev         [SQ],
  output stq_tw_t          tw_ev         [SQ],
  output lsu_rop_t         wmst_op,
  output lsu_rop_t         mdone_op,
  output logic             lrsc_clear
);

  logic [NST-1:0] act, pf_port;
  for (genvar i = 0; i < NST; i++) begin : g_port
    assign act[i]     = rsp_valid[i] && wmst_g.valid[rsp_wait_idx[i]] &&
                        wmst_g.idx[rsp_wait_idx[i]] == rsp_entry_idx[i] && st_exe[rsp_entry_idx[i]] == ST_WAIT_TLB;
    assign pf_port[i] = rsp_result[i] == MMU_PAGE_FAULT;
  end
  assign lrsc_clear = |(act & pf_port);
  for (genvar e = 0; e < SQ; e++) begin : g_tr
    logic [NST-1:0] sel;
    for (genvar i = 0; i < NST; i++) begin : g_p
      assign sel[i] = act[i] && rsp_entry_idx[i] == SQW'(e);
    end
    always_comb begin
      tr_ev[e] = '0;
      for (int i = NST - 1; i >= 0; i--) begin
        if (sel[i]) begin
          tr_ev[e].go    = 1'b1;
          tr_ev[e].res   = rsp_result[i];
          tr_ev[e].paddr = rsp_paddr[i];
        end
      end
    end
  end

  // ---- window over wait_mmu_stq ----
  logic [WIN-1:0] valid_w, is_done, is_data, is_retry;
  logic [RIW-1:0] idx_w [WIN];

  lsu_ring_win u_win (.ring(wmst_g), .valid_w(valid_w), .idx_w(idx_w));
  for (genvar p = 0; p < WIN; p++) begin : g_cand
    assign is_done[p]  = valid_w[p] && st_tlb[idx_w[p]] == ST_WAIT_DONE;
    assign is_data[p]  = valid_w[p] && st_tlb[idx_w[p]] == ST_WAIT_DATA;
    assign is_retry[p] = valid_w[p] && st_tlb[idx_w[p]] == ST_WAIT_TLB_RETRY;
  end
  for (genvar e = 0; e < SQ; e++) begin : g_tw
    logic [WIN-1:0] to_done, to_retry;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign to_done[p]  = is_done[p]  && idx_w[p] == RIW'(e);
      assign to_retry[p] = is_retry[p] && idx_w[p] == RIW'(e);
    end
    assign tw_ev[e].done  = |to_done;
    assign tw_ev[e].retry = |to_retry;
  end
  logic [WIN-1:0][RIW-1:0] idx_pk;
  for (genvar p = 0; p < WIN; p++) begin : g_pk
    assign idx_pk[p] = idx_w[p];
  end
  assign mdone_op = rop_app(is_done, idx_pk);
  assign wmst_op  = rop_kp(valid_w & ~(is_done | is_data));

endmodule

`default_nettype wire
