// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_lsu2exe part 2: finish window -> load write-back, LR reservation)
`default_nettype none

module lsu_wb_ldq
  import lsu_pkg::*;
(
  input  lsu_ring_t        finish_i,
  input  ld_state_t        ld_st_i     [LQ],
  input  logic [31:0]      ld_vaddr    [LQ],
  input  logic [31:0]      ld_paddr    [LQ],
  input  logic [31:0]      ld_result   [LQ],
  input  logic [6:0]       ld_dest     [LQ],
  input  logic [BRW-1:0]   ld_br_mask  [LQ],
  input  logic [6:0]       ld_rob_idx  [LQ],
  input  logic [LQ-1:0]    ld_pf,
  input  logic [LQ-1:0]    ld_lrsc,
  input  logic [RCW-1:0]   n_sc,
  input  logic [NLD-1:0]   sc_valid,
  input  logic [31:0]      sc_diag_val   [NLD],
  input  logic [31:0]      sc_result     [NLD],
  input  logic [6:0]       sc_dest_preg  [NLD],
  input  logic [BRW-1:0]   sc_br_mask    [NLD],
  input  logic [6:0]       sc_rob_idx    [NLD],
  input  logic [NLD-1:0]   sc_dest_en,
  input  logic [NLD-1:0]   sc_pf_store,
  input  logic             lrsc_valid_i,
  input  logic [31:0]      lrsc_addr_i,
  input  logic [BRW-1:0]   lrsc_br_i,
  output lsu_ring_t        finish_o,
  output ld_state_t        ld_st_o     [LQ],
  output logic             lrsc_valid_o,
  output logic [31:0]      lrsc_addr_o,
  output logic [BRW-1:0]   lrsc_br_o,
  // merged write-back ports: wb_req[0 .. n_sc-1] = SC, then the finished loads
  output logic [NLD-1:0]   wb_valid,
  output logic [31:0]      wb_diag_val   [NLD],
  output logic [31:0]      wb_result     [NLD],
  output logic [6:0]       wb_dest_preg  [NLD],
  output logic [BRW-1:0]   wb_br_mask    [NLD],
  output logic [6:0]       wb_rob_idx    [NLD],
  output logic [NLD-1:0]   wb_dest_en,
  output logic [NLD-1:0]   wb_pf_load,
  output logic [NLD-1:0]   wb_pf_store
);

  logic [WIN-1:0] valid_w, cand, acc, lr_p;
  logic [RIW-1:0] idx_w [WIN];
  logic [RCW-1:0] rank [WIN];

  lsu_ring_win u_win (.ring(finish_i), .valid_w(valid_w), .idx_w(idx_w));

  for (genvar p = 0; p < WIN; p++) begin : g_pos
    assign cand[p] = valid_w[p] && (ld_st_i[idx_w[p]] == LD_READY_TO_WB || ld_st_i[idx_w[p]] == LD_PAGE_FAULT);
  end
  lsu_rank #(.N(WIN), .CW(RCW)) u_rank (.bits(cand), .rank(rank));
  for (genvar p = 0; p < WIN; p++) begin : g_acc
    assign acc[p]  = cand[p] && rank[p] + n_sc < RCW'(NLD);
    assign lr_p[p] = acc[p] && ld_lrsc[idx_w[p]] && !ld_pf[idx_w[p]];
  end

  always_comb begin
    for (int k = 0; k < NLD; k++) begin
      wb_valid[k]     = sc_valid[k];
      wb_diag_val[k]  = sc_diag_val[k];
      wb_result[k]    = sc_result[k];
      wb_dest_preg[k] = sc_dest_preg[k];
      wb_br_mask[k]   = sc_br_mask[k];
      wb_rob_idx[k]   = sc_rob_idx[k];
      wb_dest_en[k]   = sc_dest_en[k];
      wb_pf_load[k]   = 1'b0;
      wb_pf_store[k]  = sc_pf_store[k];
      for (int p = 0; p < WIN; p++) begin
        if (acc[p] && rank[p] + n_sc == RCW'(k)) begin
          wb_valid[k]     = 1'b1;
          wb_diag_val[k]  = ld_vaddr[idx_w[p]];
          wb_result[k]    = ld_pf[idx_w[p]] ? ld_vaddr[idx_w[p]] : ld_result[idx_w[p]];
          wb_dest_preg[k] = ld_dest[idx_w[p]];
          wb_br_mask[k]   = ld_br_mask[idx_w[p]];
          wb_rob_idx[k]   = ld_rob_idx[idx_w[p]];
          wb_dest_en[k]   = ld_dest[idx_w[p]] != 7'd0;
          wb_pf_load[k]   = ld_pf[idx_w[p]];
          wb_pf_store[k]  = 1'b0;
        end
      end
    end
  end

  // an LR written back (without page fault) arms the reservation; the youngest window position wins
  always_comb begin
    lrsc_valid_o = lrsc_valid_i || (|lr_p);
    lrsc_addr_o  = lrsc_addr_i;
    lrsc_br_o    = lrsc_br_i;
    for (int p = 0; p < WIN; p++) begin
      if (lr_p[p]) begin
        lrsc_addr_o = ld_paddr[idx_w[p]];
        lrsc_br_o   = ld_br_mask[idx_w[p]];
      end
    end
  end

  for (genvar e = 0; e < LQ; e++) begin : g_entry
    logic [WIN-1:0] by_pos;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign by_pos[p] = acc[p] && idx_w[p] == RIW'(e);
    end
    assign ld_st_o[e] = (|by_pos) ? LD_EMPTY : ld_st_i[e];
  end

  lsu_ring_kill_pop u_pop (.ring_i(finish_i), .keep_w(valid_w & ~acc), .ring_o(finish_o));

endmodule

`default_nettype wire
