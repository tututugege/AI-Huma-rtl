// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_lsu2exe, part 1: mmu_done_stq window -> STA / SC write-back)
`default_nettype none

// F: the first NLD SC and the first NST STA entries of the mmu_done window are written back; each moves to WaitCommit.
// An SC (not faulting) takes its verdict from the reservation as it was at the start of the cycle.
module lsu_wb_stq
  import lsu_pkg::*;
(
  input  lsu_ring_t        mdone_q,
  input  logic             lrsc_valid_q,
  input  logic [31:0]      lrsc_addr_q,
  input  st_state_t        st_dc      [SQ],
  input  stq_fld_t         fld_q      [SQ],
  output stq_wb_t          ev         [SQ],
  output lsu_rop_t         mdone_op,
  output logic             sc_clear,            // a (non-faulting) SC consumed the reservation
  output logic [RCW-1:0]   n_sc,                // SC write-backs use wb_req[0 .. n_sc-1]
  // SC write-back (shares the load write-back ports)
  output logic [NLD-1:0]   sc_valid,
  output logic [31:0]      sc_diag_val   [NLD],
  output logic [31:0]      sc_result     [NLD],
  output logic [PRFW-1:0]  sc_dest_preg  [NLD],
  output logic [BRW-1:0]   sc_br_mask    [NLD],
  output logic [ROBW-1:0]  sc_rob_idx    [NLD],
  output logic [NLD-1:0]   sc_dest_en,
  output logic [NLD-1:0]   sc_pf_store,
  // STA write-back
  output logic [NST-1:0]   sta_valid,
  output logic [31:0]      sta_vaddr     [NST],
  output logic [BRW-1:0]   sta_br_mask   [NST],
  output logic [ROBW-1:0]  sta_rob_idx   [NST],
  output logic [NST-1:0]   sta_pf_store
);

  logic [WIN-1:0] valid_w, cand, is_sc, is_sta, acc_sc, acc_sta, pf_p, sc_pass_p, acc_any;
  logic [RIW-1:0] idx_w [WIN];
  logic [RCW-1:0] rank_sc [WIN], rank_sta [WIN];
  logic [31:0]    sc_result_p [WIN];
  stq_fld_t       f_p [WIN];                  // fields of the entry at each window position

  lsu_ring_win u_win (.ring(mdone_q), .valid_w(valid_w), .idx_w(idx_w));
  for (genvar p = 0; p < WIN; p++) begin : g_pos
    assign f_p[p]         = fld_q[idx_w[p]];
    assign cand[p]        = valid_w[p] && (st_dc[idx_w[p]] == ST_READY || st_dc[idx_w[p]] == ST_PAGE_FAULT);
    assign is_sc[p]       = cand[p] && f_p[p].lrsc;
    assign is_sta[p]      = cand[p] && !f_p[p].lrsc;
    assign pf_p[p]        = f_p[p].pf;
    assign sc_pass_p[p]   = lrsc_valid_q && lrsc_addr_q == f_p[p].paddr;
    assign sc_result_p[p] = pf_p[p] ? f_p[p].vaddr : (sc_pass_p[p] ? 32'd0 : 32'd1);
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
  assign mdone_op = rop_kp(valid_w & ~acc_any);

  // ---- write-back port k takes the k-th accepted SC / STA ----
  always_comb begin
    for (int k = 0; k < NLD; k++) begin
      sc_valid[k]     = 1'b0;
      sc_diag_val[k]  = '0;
      sc_result[k]    = '0;
      sc_dest_preg[k] = '0;
      sc_br_mask[k]   = '0;
      sc_rob_idx[k]   = '0;
      sc_dest_en[k]   = 1'b0;
      sc_pf_store[k]  = 1'b0;
      for (int p = 0; p < WIN; p++) begin
        if (acc_sc[p] && rank_sc[p] == RCW'(k)) begin
          sc_valid[k]     = 1'b1;
          sc_diag_val[k]  = f_p[p].vaddr;
          sc_result[k]    = sc_result_p[p];
          sc_dest_preg[k] = pf_p[p] ? '0 : f_p[p].dest;
          sc_br_mask[k]   = f_p[p].br_mask;
          sc_rob_idx[k]   = f_p[p].rob_idx;
          sc_dest_en[k]   = !pf_p[p] && f_p[p].dest != '0;
          sc_pf_store[k]  = pf_p[p];
        end
      end
    end
  end
  always_comb begin
    for (int k = 0; k < NST; k++) begin
      sta_valid[k]    = 1'b0;
      sta_vaddr[k]    = '0;
      sta_br_mask[k]  = '0;
      sta_rob_idx[k]  = '0;
      sta_pf_store[k] = 1'b0;
      for (int p = 0; p < WIN; p++) begin
        if (acc_sta[p] && rank_sta[p] == RCW'(k)) begin
          sta_valid[k]    = 1'b1;
          sta_vaddr[k]    = f_p[p].vaddr;
          sta_br_mask[k]  = f_p[p].br_mask;
          sta_rob_idx[k]  = f_p[p].rob_idx;
          sta_pf_store[k] = pf_p[p];
        end
      end
    end
  end

  // ---- per-entry events ----
  for (genvar e = 0; e < SQ; e++) begin : g_entry
    logic [WIN-1:0] by_pos, sc_by_pos;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign by_pos[p]    = acc_any[p] && idx_w[p] == RIW'(e);
      assign sc_by_pos[p] = acc_sc[p] && !pf_p[p] && idx_w[p] == RIW'(e);
    end
    assign ev[e].go     = |by_pos;
    assign ev[e].sc_upd = |sc_by_pos;
    assign ev[e].pass   = |(sc_by_pos & sc_pass_p);
  end

endmodule

`default_nettype wire
