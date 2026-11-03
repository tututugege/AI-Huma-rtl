// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_tlb_in_ldq: MMU responses for loads, then the wait_mmu_ldq window)
`default_nettype none

module lsu_tlb_resp_ld
  import lsu_pkg::*;
(
  input  logic [NLD-1:0]   rsp_valid,
  input  logic [31:0]      rsp_paddr     [NLD],
  input  logic [1:0]       rsp_result    [NLD],
  input  logic [LQW-1:0]   rsp_entry_idx [NLD],
  input  logic [RIW-1:0]   rsp_wait_idx  [NLD],
  input  lsu_ring_t        wmld_i,
  input  lsu_ring_t        stlf_i,
  input  lsu_ring_t        finish_i,
  input  ld_state_t        ld_st_i    [LQ],
  input  logic [31:0]      ld_paddr_i [LQ],
  input  logic [LQ-1:0]    ld_mmio_i,
  input  logic [LQ-1:0]    ld_pf_i,
  output lsu_ring_t        wmld_o,
  output lsu_ring_t        stlf_o,
  output lsu_ring_t        finish_o,
  output ld_state_t        ld_st_o    [LQ],
  output logic [31:0]      ld_paddr_o [LQ],
  output logic [LQ-1:0]    ld_mmio_o,
  output logic [LQ-1:0]    ld_pf_o,
  output logic             lrsc_clear
);

  // ---- 1. responses: the wait_mmu slot must still hold this entry; the entry must still wait for the TLB ----
  logic [NLD-1:0] slot_ok, act, kill_slot_port;
  for (genvar i = 0; i < NLD; i++) begin : g_port
    assign slot_ok[i]        = rsp_valid[i] && wmld_i.valid[rsp_wait_idx[i]] &&
                               wmld_i.idx[rsp_wait_idx[i]] == rsp_entry_idx[i];
    assign act[i]            = slot_ok[i] && ld_st_i[rsp_entry_idx[i]] == LD_WAIT_TLB;
    assign kill_slot_port[i] = slot_ok[i] && ld_st_i[rsp_entry_idx[i]] != LD_WAIT_TLB;
  end
  logic [NLD-1:0] pf_port;
  for (genvar i = 0; i < NLD; i++) begin : g_pf
    assign pf_port[i] = rsp_result[i] == MMU_PAGE_FAULT;
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

  ld_state_t ld_st_v1 [LQ];
  for (genvar e = 0; e < LQ; e++) begin : g_v1
    logic [NLD-1:0] sel;
    for (genvar i = 0; i < NLD; i++) begin : g_p
      assign sel[i] = act[i] && rsp_entry_idx[i] == LQW'(e);
    end
    always_comb begin
      ld_st_v1[e]    = ld_st_i[e];
      ld_paddr_o[e]  = ld_paddr_i[e];
      ld_mmio_o[e]   = ld_mmio_i[e];
      ld_pf_o[e]     = ld_pf_i[e];
      for (int i = NLD - 1; i >= 0; i--) begin
        if (sel[i]) begin
          case (rsp_result[i])
            MMU_HIT: begin
              ld_paddr_o[e] = rsp_paddr[i];
              ld_mmio_o[e]  = is_mmio_addr(rsp_paddr[i]);
              ld_st_v1[e]   = LD_WAIT_STLF;
            end
            MMU_PAGE_FAULT: begin
              ld_pf_o[e]  = 1'b1;
              ld_st_v1[e] = LD_WAIT_FINISH;
            end
            MMU_MISS: ld_st_v1[e] = LD_WAIT_TLB_RETRY;
            default:  ld_st_v1[e] = ld_st_i[e];
          endcase
        end
      end
    end
  end

  // ---- 2. window over the (still valid) wait_mmu_ldq entries ----
  lsu_ring_t      ring_v1;
  logic [WIN-1:0] valid_w, cand_stlf, cand_fin, acc_stlf, acc_fin, is_retry;
  logic [RIW-1:0] idx_w [WIN];
  logic [RCW-1:0] rank_stlf [WIN], rank_fin [WIN];

  always_comb begin
    ring_v1       = wmld_i;
    ring_v1.valid = wmld_i.valid & ~kill_slot;
  end
  lsu_ring_win u_win (.ring(ring_v1), .valid_w(valid_w), .idx_w(idx_w));

  for (genvar p = 0; p < WIN; p++) begin : g_cand
    assign cand_stlf[p] = valid_w[p] && ld_st_v1[idx_w[p]] == LD_WAIT_STLF;
    assign cand_fin[p]  = valid_w[p] && ld_st_v1[idx_w[p]] == LD_WAIT_FINISH;
    assign is_retry[p]  = valid_w[p] && ld_st_v1[idx_w[p]] == LD_WAIT_TLB_RETRY;
  end
  lsu_rank #(.N(WIN), .CW(RCW)) u_rank_stlf (.bits(cand_stlf), .rank(rank_stlf));
  lsu_rank #(.N(WIN), .CW(RCW)) u_rank_fin  (.bits(cand_fin),  .rank(rank_fin));
  for (genvar p = 0; p < WIN; p++) begin : g_acc
    assign acc_stlf[p] = cand_stlf[p] && rank_stlf[p] < RCW'(NLD) && stlf_i.count + rank_stlf[p] < RCW'(LQ);
    assign acc_fin[p]  = cand_fin[p]  && rank_fin[p]  < RCW'(NLD) && finish_i.count + rank_fin[p] < RCW'(LQ);
  end

  for (genvar e = 0; e < LQ; e++) begin : g_v2
    logic [WIN-1:0] to_stlf, to_fin, to_retry;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign to_stlf[p]  = acc_stlf[p] && idx_w[p] == RIW'(e);
      assign to_fin[p]   = acc_fin[p]  && idx_w[p] == RIW'(e);
      assign to_retry[p] = is_retry[p] && idx_w[p] == RIW'(e);
    end
    assign ld_st_o[e] = (|to_stlf)  ? LD_CHECK_STLF :
                        (|to_fin)   ? LD_PAGE_FAULT :
                        (|to_retry) ? LD_WAIT_TLB : ld_st_v1[e];
  end

  lsu_ring_app #(.NA(WIN)) u_stlf (.ring_i(stlf_i),   .app_en(acc_stlf), .app_idx(idx_w), .ring_o(stlf_o));
  lsu_ring_app #(.NA(WIN)) u_fin  (.ring_i(finish_i), .app_en(acc_fin),  .app_idx(idx_w), .ring_o(finish_o));
  lsu_ring_kill_pop u_pop (.ring_i(ring_v1), .keep_w(valid_w & ~(acc_stlf | acc_fin)), .ring_o(wmld_o));

endmodule

`default_nettype wire
