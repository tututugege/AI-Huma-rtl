// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_tlb_in_stq: MMU responses for stores, then the wait_mmu_stq window)
`default_nettype none

module lsu_tlb_resp_st
  import lsu_pkg::*;
(
  input  logic [NST-1:0]   rsp_valid,
  input  logic [31:0]      rsp_paddr     [NST],
  input  logic [1:0]       rsp_result    [NST],
  input  logic [SQW-1:0]   rsp_entry_idx [NST],
  input  logic [RIW-1:0]   rsp_wait_idx  [NST],
  input  lsu_ring_t        wmst_i,
  input  lsu_ring_t        mdone_i,
  input  st_state_t        st_st_i    [SQ],
  input  logic [SQ-1:0]    st_data_valid,
  input  logic [SQ-1:0]    st_paddr_valid_i,
  input  logic [31:0]      st_paddr_i [SQ],
  input  logic [SQ-1:0]    st_mmio_i,
  input  logic [SQ-1:0]    st_pf_i,
  output lsu_ring_t        wmst_o,
  output lsu_ring_t        mdone_o,
  output st_state_t        st_st_o    [SQ],
  output logic [SQ-1:0]    st_paddr_valid_o,
  output logic [31:0]      st_paddr_o [SQ],
  output logic [SQ-1:0]    st_mmio_o,
  output logic [SQ-1:0]    st_pf_o,
  output logic             lrsc_clear
);

  // ---- 1. responses (only entries still in WaitTlb whose wait_mmu slot is intact are touched) ----
  logic [NST-1:0] act, pf_port;
  for (genvar i = 0; i < NST; i++) begin : g_port
    assign act[i]     = rsp_valid[i] && wmst_i.valid[rsp_wait_idx[i]] &&
                        wmst_i.idx[rsp_wait_idx[i]] == rsp_entry_idx[i] && st_st_i[rsp_entry_idx[i]] == ST_WAIT_TLB;
    assign pf_port[i] = rsp_result[i] == MMU_PAGE_FAULT;
  end
  assign lrsc_clear = |(act & pf_port);

  st_state_t st_v1 [SQ];
  for (genvar e = 0; e < SQ; e++) begin : g_v1
    logic [NST-1:0] sel;
    for (genvar i = 0; i < NST; i++) begin : g_p
      assign sel[i] = act[i] && rsp_entry_idx[i] == SQW'(e);
    end
    always_comb begin
      st_v1[e]            = st_st_i[e];
      st_paddr_valid_o[e] = st_paddr_valid_i[e];
      st_paddr_o[e]       = st_paddr_i[e];
      st_mmio_o[e]        = st_mmio_i[e];
      st_pf_o[e]          = st_pf_i[e];
      for (int i = NST - 1; i >= 0; i--) begin
        if (sel[i]) begin
          case (rsp_result[i])
            MMU_HIT: begin
              st_paddr_valid_o[e] = 1'b1;
              st_paddr_o[e]       = rsp_paddr[i];
              st_mmio_o[e]        = is_mmio_addr(rsp_paddr[i]);
              st_v1[e]            = st_data_valid[e] ? ST_WAIT_DONE : ST_WAIT_DATA;
            end
            MMU_PAGE_FAULT: begin
              st_pf_o[e] = 1'b1;
              st_v1[e]   = ST_WAIT_DONE;
            end
            MMU_MISS: st_v1[e] = ST_WAIT_TLB_RETRY;
            default:  st_v1[e] = st_st_i[e];
          endcase
        end
      end
    end
  end

  // ---- 2. window over wait_mmu_stq ----
  logic [WIN-1:0] valid_w, is_done, is_data, is_retry, keep;
  logic [RIW-1:0] idx_w [WIN];

  lsu_ring_win u_win (.ring(wmst_i), .valid_w(valid_w), .idx_w(idx_w));
  for (genvar p = 0; p < WIN; p++) begin : g_cand
    assign is_done[p]  = valid_w[p] && st_v1[idx_w[p]] == ST_WAIT_DONE;
    assign is_data[p]  = valid_w[p] && st_v1[idx_w[p]] == ST_WAIT_DATA;
    assign is_retry[p] = valid_w[p] && st_v1[idx_w[p]] == ST_WAIT_TLB_RETRY;
  end
  assign keep = valid_w & ~(is_done | is_data);

  for (genvar e = 0; e < SQ; e++) begin : g_v2
    logic [WIN-1:0] to_done, to_retry;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign to_done[p]  = is_done[p]  && idx_w[p] == RIW'(e);
      assign to_retry[p] = is_retry[p] && idx_w[p] == RIW'(e);
    end
    assign st_st_o[e] = (|to_done) ? (st_pf_o[e] ? ST_PAGE_FAULT : ST_READY) : (|to_retry) ? ST_WAIT_TLB : st_v1[e];
  end

  lsu_ring_app #(.NA(WIN)) u_mdone (.ring_i(mdone_i), .app_en(is_done), .app_idx(idx_w), .ring_o(mdone_o));
  lsu_ring_kill_pop u_pop (.ring_i(wmst_i), .keep_w(keep), .ring_o(wmst_o));

endmodule

`default_nettype wire
