// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_lsu2exe, part 1: mmu_done_stq window -> STA / SC write-back)
`default_nettype none

module lsu_wb_stq
  import lsu_pkg::*;
(
  input  lsu_ring_t        mdone_i,
  input  logic             lrsc_valid_q,        // cur.lrsc_unit: SC verdict uses the cycle-start reservation
  input  logic [31:0]      lrsc_addr_q,
  input  st_state_t        st_st_i       [SQ],
  input  logic [SQ-1:0]    st_is_lrsc,
  input  logic [SQ-1:0]    st_pf,
  input  logic [31:0]      st_vaddr      [SQ],
  input  logic [31:0]      st_paddr      [SQ],
  input  logic [6:0]       st_dest       [SQ],
  input  logic [BRW-1:0]   st_br_mask    [SQ],
  input  logic [6:0]       st_rob_idx    [SQ],
  input  logic [SQ-1:0]    st_sc_pass_i,
  input  logic [SQ-1:0]    st_suppress_i,
  output lsu_ring_t        mdone_o,
  output st_state_t        st_st_o       [SQ],
  output logic [SQ-1:0]    st_sc_pass_o,
  output logic [SQ-1:0]    st_suppress_o,
  output logic             sc_clear,            // a (non-faulting) SC consumed the reservation
  output logic [RCW-1:0]   n_sc,                // SC write-backs use wb_req[0 .. n_sc-1]
  // SC write-back (shares the load write-back ports)
  output logic [NLD-1:0]   sc_valid,
  output logic [31:0]      sc_diag_val   [NLD],
  output logic [31:0]      sc_result     [NLD],
  output logic [6:0]       sc_dest_preg  [NLD],
  output logic [BRW-1:0]   sc_br_mask    [NLD],
  output logic [6:0]       sc_rob_idx    [NLD],
  output logic [NLD-1:0]   sc_dest_en,
  output logic [NLD-1:0]   sc_pf_store,
  // STA write-back
  output logic [NST-1:0]   sta_valid,
  output logic [31:0]      sta_vaddr     [NST],
  output logic [BRW-1:0]   sta_br_mask   [NST],
  output logic [6:0]       sta_rob_idx   [NST],
  output logic [NST-1:0]   sta_pf_store
);

  logic [WIN-1:0] valid_w, cand, is_sc, is_sta, acc_sc, acc_sta, pf_p, sc_pass_p, acc_any;
  logic [RIW-1:0] idx_w [WIN];
  logic [RCW-1:0] rank_sc [WIN], rank_sta [WIN];
  logic [31:0]    vaddr_p [WIN];
  logic [31:0]    sc_result_p [WIN];
  logic [6:0]     dest_p [WIN], rob_p [WIN];
  logic [BRW-1:0] br_p [WIN];

  lsu_ring_win u_win (.ring(mdone_i), .valid_w(valid_w), .idx_w(idx_w));

  for (genvar p = 0; p < WIN; p++) begin : g_pos
    assign cand[p]      = valid_w[p] && (st_st_i[idx_w[p]] == ST_READY || st_st_i[idx_w[p]] == ST_PAGE_FAULT);
    assign is_sc[p]     = cand[p] && st_is_lrsc[idx_w[p]];
    assign is_sta[p]    = cand[p] && !st_is_lrsc[idx_w[p]];
    assign pf_p[p]      = st_pf[idx_w[p]];
    assign vaddr_p[p]   = st_vaddr[idx_w[p]];
    assign dest_p[p]    = st_dest[idx_w[p]];
    assign rob_p[p]     = st_rob_idx[idx_w[p]];
    assign br_p[p]      = st_br_mask[idx_w[p]];
    assign sc_pass_p[p] = lrsc_valid_q && lrsc_addr_q == st_paddr[idx_w[p]];
    assign sc_result_p[p] = pf_p[p] ? vaddr_p[p] : (sc_pass_p[p] ? 32'd0 : 32'd1);
  end
  lsu_rank #(.N(WIN), .CW(RCW)) u_rank_sc  (.bits(is_sc),  .rank(rank_sc));
  lsu_rank #(.N(WIN), .CW(RCW)) u_rank_sta (.bits(is_sta), .rank(rank_sta));
  for (genvar p = 0; p < WIN; p++) begin : g_acc
    assign acc_sc[p]  = is_sc[p]  && rank_sc[p]  < RCW'(NLD);
    assign acc_sta[p] = is_sta[p] && rank_sta[p] < RCW'(NST);
  end
  assign acc_any  = acc_sc | acc_sta;
  assign sc_clear = |(acc_sc & ~pf_p);
  ttg_popcount #(.N(WIN), .CW(RCW)) u_nsc (.bits(acc_sc), .count(n_sc));

  // ---- write-back port k takes the k-th accepted SC / STA ----
  always_comb begin
    for (int k = 0; k < NLD; k++) begin
      sc_valid[k]    = 1'b0;
      sc_diag_val[k] = '0;
      sc_result[k]   = '0;
      sc_dest_preg[k] = '0;
      sc_br_mask[k]  = '0;
      sc_rob_idx[k]  = '0;
      sc_dest_en[k]  = 1'b0;
      sc_pf_store[k] = 1'b0;
      for (int p = 0; p < WIN; p++) begin
        if (acc_sc[p] && rank_sc[p] == RCW'(k)) begin
          sc_valid[k]     = 1'b1;
          sc_diag_val[k]  = vaddr_p[p];
          sc_result[k]    = sc_result_p[p];
          sc_dest_preg[k] = pf_p[p] ? 7'd0 : dest_p[p];
          sc_br_mask[k]   = br_p[p];
          sc_rob_idx[k]   = rob_p[p];
          sc_dest_en[k]   = !pf_p[p] && dest_p[p] != 7'd0;
          sc_pf_store[k]  = pf_p[p];
        end
      end
    end
    for (int k = 0; k < NST; k++) begin
      sta_valid[k]    = 1'b0;
      sta_vaddr[k]    = '0;
      sta_br_mask[k]  = '0;
      sta_rob_idx[k]  = '0;
      sta_pf_store[k] = 1'b0;
      for (int p = 0; p < WIN; p++) begin
        if (acc_sta[p] && rank_sta[p] == RCW'(k)) begin
          sta_valid[k]    = 1'b1;
          sta_vaddr[k]    = vaddr_p[p];
          sta_br_mask[k]  = br_p[p];
          sta_rob_idx[k]  = rob_p[p];
          sta_pf_store[k] = pf_p[p];
        end
      end
    end
  end

  // ---- STQ entry updates: WaitCommit; an SC records its verdict (a failed SC suppresses the write) ----
  for (genvar e = 0; e < SQ; e++) begin : g_entry
    logic [WIN-1:0] by_pos, sc_by_pos;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign by_pos[p]    = acc_any[p] && idx_w[p] == RIW'(e);
      assign sc_by_pos[p] = acc_sc[p] && !pf_p[p] && idx_w[p] == RIW'(e);
    end
    assign st_st_o[e]       = (|by_pos) ? ST_WAIT_COMMIT : st_st_i[e];
    assign st_sc_pass_o[e]  = (|sc_by_pos) ? lrsc_valid_q && lrsc_addr_q == st_paddr[e] : st_sc_pass_i[e];
    assign st_suppress_o[e] = (|sc_by_pos) ? !(lrsc_valid_q && lrsc_addr_q == st_paddr[e]) : st_suppress_i[e];
  end

  lsu_ring_kill_pop u_pop (.ring_i(mdone_i), .keep_w(valid_w & ~acc_any), .ring_o(mdone_o));

endmodule

`default_nettype wire
