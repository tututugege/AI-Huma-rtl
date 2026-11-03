// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_lsu2exe part 2: finish window -> load write-back, LR reservation)
`default_nettype none

// F: the finish-queue window (ReadyToWb / PageFault loads) takes the write-back ports left over by the SCs.
// An LR written back (no page fault) arms the reservation (youngest window position wins).
module lsu_wb_ldq
  import lsu_pkg::*;
(
  input  lsu_ring_t        finish_d,                // finish queue after the C and D appends
  input  ld_state_t        ld_st_rsp   [LQ],
  input  ldq_fld_t         fld_q       [LQ],
  input  logic [31:0]      result_f    [LQ],
  input  logic [RCW-1:0]   n_sc,
  input  logic [NLD-1:0]   sc_valid,
  input  logic [31:0]      sc_diag_val   [NLD],
  input  logic [31:0]      sc_result     [NLD],
  input  logic [PRFW-1:0]  sc_dest_preg  [NLD],
  input  logic [BRW-1:0]   sc_br_mask    [NLD],
  input  logic [ROBW-1:0]  sc_rob_idx    [NLD],
  input  logic [NLD-1:0]   sc_dest_en,
  input  logic [NLD-1:0]   sc_pf_store,
  input  logic             lrsc_valid_i,
  input  logic [31:0]      lrsc_addr_i,
  input  logic [BRW-1:0]   lrsc_br_i,
  output logic [LQ-1:0]    wb_go,
  output lsu_rop_t         fin_op,
  output logic             lrsc_valid_o,
  output logic [31:0]      lrsc_addr_o,
  output logic [BRW-1:0]   lrsc_br_o,
  // merged write-back ports: wb_req[0 .. n_sc-1] = SC, then the finished loads
  output logic [NLD-1:0]   wb_valid,
  output logic [31:0]      wb_diag_val   [NLD],
  output logic [31:0]      wb_result     [NLD],
  output logic [PRFW-1:0]  wb_dest_preg  [NLD],
  output logic [BRW-1:0]   wb_br_mask    [NLD],
  output logic [ROBW-1:0]  wb_rob_idx    [NLD],
  output logic [NLD-1:0]   wb_dest_en,
  output logic [NLD-1:0]   wb_pf_load,
  output logic [NLD-1:0]   wb_pf_store
);

  logic [WIN-1:0] valid_w, cand, acc, lr_p;
  logic [RIW-1:0] idx_w [WIN];
  logic [RCW-1:0] rank [WIN];
  ldq_fld_t       f_p [WIN];
  logic [31:0]    res_p [WIN];

  lsu_ring_win u_win (.ring(finish_d), .valid_w(valid_w), .idx_w(idx_w));
  for (genvar p = 0; p < WIN; p++) begin : g_pos
    assign f_p[p]   = fld_q[idx_w[p]];
    assign res_p[p] = result_f[idx_w[p]];
    assign cand[p]  = valid_w[p] && (ld_st_rsp[idx_w[p]] == LD_READY_TO_WB || ld_st_rsp[idx_w[p]] == LD_PAGE_FAULT);
  end
  lsu_rank #(.N(WIN), .CW(RCW)) u_rank (.bits(cand), .rank(rank));
  for (genvar p = 0; p < WIN; p++) begin : g_acc
    assign acc[p]  = cand[p] && rank[p] + n_sc < RCW'(NLD);
    assign lr_p[p] = acc[p] && f_p[p].lrsc && !f_p[p].pf;
  end
  assign fin_op = rop_kp(valid_w & ~acc);

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
          wb_diag_val[k]  = f_p[p].vaddr;
          wb_result[k]    = f_p[p].pf ? f_p[p].vaddr : res_p[p];
          wb_dest_preg[k] = f_p[p].dest;
          wb_br_mask[k]   = f_p[p].br_mask;
          wb_rob_idx[k]   = f_p[p].rob_idx;
          wb_dest_en[k]   = f_p[p].dest != '0;
          wb_pf_load[k]   = f_p[p].pf;
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
        lrsc_addr_o = f_p[p].paddr;
        lrsc_br_o   = f_p[p].br_mask;
      end
    end
  end

  for (genvar e = 0; e < LQ; e++) begin : g_entry
    logic [WIN-1:0] by_pos;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign by_pos[p] = acc[p] && idx_w[p] == RIW'(e);
    end
    assign wb_go[e] = |by_pos;
  end

endmodule

`default_nettype wire
