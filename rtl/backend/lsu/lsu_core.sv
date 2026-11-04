// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (LSU core: LDQ/STQ entries, index queues, stage logic)
`default_nettype none

module lsu_core
  import lsu_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic [4:0] cm_amo_op [NCM],
  input  logic [SQW-1:0] cm_stq_idx [NCM],
  input  logic [4:0] cm_type [NCM],
  input  logic [NCM-1:0] cm_valid,
  input  logic [31:0] dcl_data [NLD],
  input  logic [1:0] dcl_replay [NLD],
  input  logic [31:0] dcl_req_id [NLD],
  input  logic [NLD-1:0] dcl_valid,
  input  logic [1:0] dcs_replay [NST],
  input  logic [31:0] dcs_req_id [NST],
  input  logic [NST-1:0] dcs_valid,
  input  logic [BRW-1:0] dec_br_mask,
  input  logic [BRW-1:0] dec_clear_mask,
  input  logic dec_mispred,
  input  logic [BRW-1:0] dis_ldq_br_mask [NDIS],
  input  logic [LQW-1:0] dis_ldq_idx [NDIS],
  input  logic [NDIS-1:0] dis_ldq_req,
  input  logic dis_ldq_rob_flag [NDIS],
  input  logic [ROBW-1:0] dis_ldq_rob_idx [NDIS],
  input  logic [BRW-1:0] dis_stq_br_mask [NDIS],
  input  logic [NDIS-1:0] dis_stq_req,
  input  logic dis_stq_rob_flag [NDIS],
  input  logic [ROBW-1:0] dis_stq_rob_idx [NDIS],
  input  logic [LINEW-1:0] fill_line,
  input  logic fill_valid,
  input  logic [4:0] ldu_amo_op [NLD],
  input  logic [PRFW-1:0] ldu_dest_preg [NLD],
  input  logic [2:0] ldu_func3 [NLD],
  input  logic [NLD-1:0] ldu_is_atomic,
  input  logic [LQW-1:0] ldu_ldq_idx [NLD],
  input  logic [31:0] ldu_result [NLD],
  input  logic ldu_rob_flag [NLD],
  input  logic [ROBW-1:0] ldu_rob_idx [NLD],
  input  logic ldu_stq_flag [NLD],
  input  logic [SQW-1:0] ldu_stq_idx [NLD],
  input  logic [NLD-1:0] ldu_valid,
  input  logic [LQW-1:0] mmu_ld_entry_idx [NLD],
  input  logic [31:0] mmu_ld_paddr [NLD],
  input  logic [1:0] mmu_ld_result [NLD],
  input  logic [NLD-1:0] mmu_ld_valid,
  input  logic [RIW-1:0] mmu_ld_wait_idx [NLD],
  input  logic [SQW-1:0] mmu_st_entry_idx [NST],
  input  logic [31:0] mmu_st_paddr [NST],
  input  logic [1:0] mmu_st_result [NST],
  input  logic [NST-1:0] mmu_st_valid,
  input  logic [RIW-1:0] mmu_st_wait_idx [NST],
  input  logic periph_resp_is_mmio,
  input  logic [31:0] periph_resp_rdata,
  input  logic periph_resp_ready,
  input  logic rb_flush,
  input  logic [ROBW-1:0] rb_head_rob_idx,
  input  logic rb_head_valid,
  input  logic [ROBW-1:0] rb_hi_rob_idx,
  input  logic rb_hi_valid,
  input  logic [31:0] sdu_result [NSDU],
  input  logic sdu_rob_flag [NSDU],
  input  logic [ROBW-1:0] sdu_rob_idx [NSDU],
  input  logic [SQW-1:0] sdu_stq_idx [NSDU],
  input  logic [NSDU-1:0] sdu_valid,
  input  logic [4:0] sta_amo_op [NST],
  input  logic [PRFW-1:0] sta_dest_preg [NST],
  input  logic [2:0] sta_func3 [NST],
  input  logic [NST-1:0] sta_is_atomic,
  input  logic [31:0] sta_result [NST],
  input  logic sta_rob_flag [NST],
  input  logic [ROBW-1:0] sta_rob_idx [NST],
  input  logic [SQW-1:0] sta_stq_idx [NST],
  input  logic [NST-1:0] sta_valid,
  output logic [31:0] dcl_req_addr [NLD],
  output logic [RIW+GENW-1:0] dcl_req_id_o [NLD],
  output logic [NLD-1:0] dcl_req_valid,
  output logic [31:0] dcs_req_addr [NST],
  output logic [31:0] dcs_req_data [NST],
  output logic [SQW-1:0] dcs_req_id_o [NST],
  output logic [4:0] dcs_req_strb [NST],
  output logic [NST-1:0] dcs_req_valid,
  output logic [RIW-1:0] lsu2dis_ldq_alloc_idx [NDIS],
  output logic [NDIS-1:0] lsu2dis_ldq_alloc_valid,
  output logic [RCW-1:0] lsu2dis_ldq_free,
  output logic [RCW-1:0] lsu2dis_stq_free,
  output logic [RIW-1:0] lsu2dis_stq_tail,
  output logic lsu2dis_stq_tail_flag,
  output logic lsu2rob_committed_store_pending,
  output logic [RIW-1:0] mmu_ld_req_entry_idx [NLD],
  output logic [31:0] mmu_ld_req_vaddr [NLD],
  output logic [NLD-1:0] mmu_ld_req_valid,
  output logic [RIW-1:0] mmu_ld_req_wait_idx [NLD],
  output logic [RIW-1:0] mmu_st_req_entry_idx [NLD],
  output logic [31:0] mmu_st_req_vaddr [NLD],
  output logic [NLD-1:0] mmu_st_req_valid,
  output logic [RIW-1:0] mmu_st_req_wait_idx [NLD],
  output logic [31:0] periph_req_addr,
  output logic [2:0] periph_req_fun3,
  output logic periph_req_is_mmio,
  output logic [31:0] periph_req_wdata,
  output logic periph_req_wen,
  output logic [BRW-1:0] sta_wb_br_mask [NST],
  output logic [NST-1:0] sta_wb_pf_store,
  output logic [ROBW-1:0] sta_wb_rob_idx [NST],
  output logic [31:0] sta_wb_vaddr [NST],
  output logic [NST-1:0] sta_wb_valid,
  output logic [BRW-1:0] wb_br_mask [NLD],
  output logic [NLD-1:0] wb_dest_en,
  output logic [PRFW-1:0] wb_dest_preg [NLD],
  output logic [31:0] wb_diag_val [NLD],
  output logic [NLD-1:0] wb_pf_load,
  output logic [NLD-1:0] wb_pf_store,
  output logic [31:0] wb_result [NLD],
  output logic [ROBW-1:0] wb_rob_idx [NLD],
  output logic [NLD-1:0] wb_valid
);

  // One cycle (BackTop::comb): B commit, C mmio resp, D/E dcache resp, F write-back, G exe in, H tlb req, I tlb resp,
  // J stlf, K alloc, L flush, M/N dcache req, O mmio req, P retire.  Stage logic gives per-entry events and queue ops.
  // ---- LDQ side: per-entry state views, fields, events ----
  ld_state_t   ld_st_q [LQ], ld_st_rsp [LQ], ld_st_agu [LQ], ld_st_tlb [LQ], ld_st_win [LQ], ld_st_fl [LQ];
  ldq_fld_t    ld_fld_q [LQ], ld_fld_e [LQ];
  logic [31:0] ld_result_f [LQ];
  ldq_mm_t     ld_mm [LQ];
  ldq_dc_t     ld_dc [LQ];
  ldq_agu_t    ld_agu [LQ];
  ldq_tr_t     ld_tr [LQ];
  ldq_tw_t     ld_tw [LQ];
  ldq_sf_t     ld_sf [LQ];
  ldq_al_t     ld_al [LQ];
  logic [LQ-1:0] ld_wb_go, ld_iss, ld_empty, ld_wait_tlb;
  logic [31:0]   ld_vaddr_e [LQ];

  for (genvar e = 0; e < LQ; e++) begin : g_ldq
    lsu_ldq_ent u_ent (
      .clk(clk), .rst_n(rst_n), .mm_ev(ld_mm[e]), .dc_ev(ld_dc[e]), .wb_go(ld_wb_go[e]), .agu_ev(ld_agu[e]),
      .tr_ev(ld_tr[e]), .tw_ev(ld_tw[e]), .sf_ev(ld_sf[e]), .al_ev(ld_al[e]), .flush(rb_flush),
      .mispred(dec_mispred), .dec_br_mask(dec_br_mask), .clear_mask(dec_clear_mask), .iss_go(ld_iss[e]),
      .st_cur(ld_st_q[e]), .st_rsp(ld_st_rsp[e]), .st_agu(ld_st_agu[e]), .st_tlb(ld_st_tlb[e]),
      .st_win(ld_st_win[e]), .st_fl(ld_st_fl[e]), .fld_cur(ld_fld_q[e]), .fld_e(ld_fld_e[e]),
      .result_f(ld_result_f[e]));
    assign ld_empty[e]    = ld_st_fl[e] == LD_EMPTY;
    assign ld_wait_tlb[e] = ld_st_agu[e] == LD_WAIT_TLB;
    assign ld_vaddr_e[e]  = ld_fld_e[e].vaddr;
  end
  // ---- STQ side ----
  st_state_t   st_q [SQ], st_dc [SQ], st_exe [SQ], st_tlb [SQ], st_win [SQ], st_al [SQ], st_nx [SQ];
  stq_fld_t    st_fld_q [SQ] /*verilator public_flat_rd*/, st_fld_e [SQ];
  logic [RWW-1:0] st_wait_dc [SQ], st_wait_n [SQ];
  logic [BRW-1:0] st_br_al [SQ];
  logic [SQ-1:0]  st_cm, st_mmgo, st_wk, st_clr_win, st_wdr, st_wait_tlb;
  stq_dc_t     st_dce [SQ];
  stq_wb_t     st_wbe [SQ];
  stq_ex_t     st_ex [SQ];
  stq_tr_t     st_tre [SQ];
  stq_tw_t     st_twe [SQ];
  stq_al_t     st_ale [SQ];
  stq_is_t     st_ise [SQ];
  logic [31:0] st_vaddr_e [SQ];

  for (genvar e = 0; e < SQ; e++) begin : g_stq
    lsu_stq_ent u_ent (
      .clk(clk), .rst_n(rst_n), .cm_go(st_cm[e]), .flush(rb_flush), .mm_go(st_mmgo[e]), .dc_ev(st_dce[e]),
      .wk_go(st_wk[e]), .wb_ev(st_wbe[e]), .ex_ev(st_ex[e]), .tr_ev(st_tre[e]), .tw_ev(st_twe[e]),
      .al_ev(st_ale[e]), .clr_win(st_clr_win[e]), .clear_mask(dec_clear_mask), .is_ev(st_ise[e]),
      .st_cur(st_q[e]), .st_dc(st_dc[e]), .st_exe(st_exe[e]), .st_tlb(st_tlb[e]), .st_win(st_win[e]),
      .st_al(st_al[e]), .st_nx(st_nx[e]), .fld_cur(st_fld_q[e]), .fld_e(st_fld_e[e]), .wait_dc(st_wait_dc[e]),
      .wait_n(st_wait_n[e]), .br_al(st_br_al[e]));
    assign st_wdr[e]      = st_q[e] == ST_WAIT_DCACHE_RESP;
    assign st_wait_tlb[e] = st_exe[e] == ST_WAIT_TLB;
    assign st_vaddr_e[e]  = st_fld_e[e].vaddr;
  end
  // ---- queues: operations per stage, views after each operation (see docs/analysis/lsu-structure.md section 3) ----
  // ring wires: X_oK = operation K of queue X (unused: NOP), X_vK = queue after K operations (v0 = registers)
  /* verilator lint_off UNUSEDSIGNAL */  // views after the last operation are not read
  lsu_rop_t  wmld_o0, wmld_o1, wmld_o2, wmld_o3;
  lsu_ring_t wmld_v0, wmld_v1, wmld_v2, wmld_v3, wmld_v4, wmld_v5, wmld_v6;
  lsu_rop_t  wmst_o0, wmst_o1, wmst_o2;
  lsu_ring_t wmst_v0, wmst_v1, wmst_v2, wmst_v3, wmst_v4, wmst_v5, wmst_v6;
  lsu_rop_t  mdone_o0, mdone_o1, mdone_o2, mdone_o3;
  lsu_ring_t mdone_v0, mdone_v1, mdone_v2, mdone_v3, mdone_v4, mdone_v5, mdone_v6;
  lsu_rop_t  fin_o0, fin_o1, fin_o2, fin_o3, fin_o4, fin_o5;
  lsu_ring_t fin_v0, fin_v1, fin_v2, fin_v3, fin_v4, fin_v5, fin_v6;
  lsu_rop_t  stlf_o0, stlf_o1, stlf_o2, stlf_o3;
  lsu_ring_t stlf_v0, stlf_v1, stlf_v2, stlf_v3, stlf_v4, stlf_v5, stlf_v6;
  lsu_rop_t  wdc_o0, wdc_o1, wdc_o2;
  lsu_ring_t wdc_v0, wdc_v1, wdc_v2, wdc_v3, wdc_v4, wdc_v5, wdc_v6;
  /* verilator lint_on UNUSEDSIGNAL */
  lsu_ring u_q_wmld (.clk(clk), .rst_n(rst_n),
    .op0(wmld_o0), .op1(wmld_o1), .op2(wmld_o2), .op3(wmld_o3), .op4(ROP_NOP), .op5(ROP_NOP),
    .view0(wmld_v0), .view1(wmld_v1), .view2(wmld_v2), .view3(wmld_v3),
    .view4(wmld_v4), .view5(wmld_v5), .view6(wmld_v6));
  lsu_ring u_q_wmst (.clk(clk), .rst_n(rst_n),
    .op0(wmst_o0), .op1(wmst_o1), .op2(wmst_o2), .op3(ROP_NOP), .op4(ROP_NOP), .op5(ROP_NOP),
    .view0(wmst_v0), .view1(wmst_v1), .view2(wmst_v2), .view3(wmst_v3),
    .view4(wmst_v4), .view5(wmst_v5), .view6(wmst_v6));
  lsu_ring u_q_mdone (.clk(clk), .rst_n(rst_n),
    .op0(mdone_o0), .op1(mdone_o1), .op2(mdone_o2), .op3(mdone_o3), .op4(ROP_NOP), .op5(ROP_NOP),
    .view0(mdone_v0), .view1(mdone_v1), .view2(mdone_v2), .view3(mdone_v3),
    .view4(mdone_v4), .view5(mdone_v5), .view6(mdone_v6));
  lsu_ring u_q_fin (.clk(clk), .rst_n(rst_n),
    .op0(fin_o0), .op1(fin_o1), .op2(fin_o2), .op3(fin_o3), .op4(fin_o4), .op5(fin_o5),
    .view0(fin_v0), .view1(fin_v1), .view2(fin_v2), .view3(fin_v3), .view4(fin_v4), .view5(fin_v5), .view6(fin_v6));
  lsu_ring u_q_stlf (.clk(clk), .rst_n(rst_n),
    .op0(stlf_o0), .op1(stlf_o1), .op2(stlf_o2), .op3(stlf_o3), .op4(ROP_NOP), .op5(ROP_NOP),
    .view0(stlf_v0), .view1(stlf_v1), .view2(stlf_v2), .view3(stlf_v3),
    .view4(stlf_v4), .view5(stlf_v5), .view6(stlf_v6));
  lsu_ring u_q_wdc (.clk(clk), .rst_n(rst_n),
    .op0(wdc_o0), .op1(wdc_o1), .op2(wdc_o2), .op3(ROP_NOP), .op4(ROP_NOP), .op5(ROP_NOP),
    .view0(wdc_v0), .view1(wdc_v1), .view2(wdc_v2), .view3(wdc_v3), .view4(wdc_v4), .view5(wdc_v5), .view6(wdc_v6));
  // ---- scalar state: STQ pointers, uncached unit, LR/SC reservation, wait_dcache slots ----
  logic [RIW-1:0] stq_head_q;
  logic           stq_head_flag_q;
  logic [RCW-1:0] stq_count_q, stq_ccount_q, ccount_cm, count_al, count_flushed, count_fl, ccount_fl;
  logic           unc_valid_q, unc_is_load_q, unc_valid_resp, unc_valid_pre_st, unc_valid_o, unc_is_load_o;
  logic [RIW-1:0] unc_idx_q;
  logic [31:0]    unc_addr_o, unc_wdata_o;
  logic [2:0]     unc_func3_o;
  /* verilator lint_off UNUSEDSIGNAL */  // the request index is only needed inside the unit (registered there)
  logic [RIW-1:0] unc_idx_o;
  /* verilator lint_on UNUSEDSIGNAL */
  logic           lrsc_valid_q, lrsc_valid_f1, lrsc_valid_f2, lrsc_clear_ld, lrsc_clear_st;
  logic [31:0]    lrsc_addr_q, lrsc_addr_f2;
  logic [BRW-1:0] lrsc_br_q, lrsc_br_f2;
  logic [RN-1:0]  wd_set, wd_clr, wd_dec, wd_gen_we;
  logic [RWW-1:0] wd_set_val [RN], wd_wait_q [RN], wd_wait_wk [RN];
  logic [GENW-1:0] wd_gen_wd [RN], wd_gen_q [RN], req_gen_q;
  logic [RCW-1:0] n_iss;

  lsu_cur_info u_cur (
    .ld_st_q(ld_st_q), .st_st_q(st_q), .stq_head_q(stq_head_q), .stq_head_flag_q(stq_head_flag_q),
    .stq_count_q(stq_count_q), .stq_ccount_q(stq_ccount_q), .wait_mmu_ldq_count_q(wmld_v0.count),
    .wait_mmu_stq_count_q(wmst_v0.count), .mmu_done_count_q(mdone_v0.count), .lsu2dis_stq_tail(lsu2dis_stq_tail),
    .lsu2dis_stq_tail_flag(lsu2dis_stq_tail_flag), .lsu2dis_stq_free(lsu2dis_stq_free),
    .lsu2dis_ldq_free(lsu2dis_ldq_free), .lsu2dis_ldq_alloc_valid(lsu2dis_ldq_alloc_valid),
    .lsu2dis_ldq_alloc_idx(lsu2dis_ldq_alloc_idx), .lsu2rob_committed_store_pending(lsu2rob_committed_store_pending));
  // ---- B: stq commit ----
  lsu_stq_commit u_commit (
    .cm_valid(cm_valid), .cm_type(cm_type), .cm_amo_op(cm_amo_op), .cm_stq_idx(cm_stq_idx),
    .stq_head(stq_head_q), .stq_ccount(stq_ccount_q), .st_q(st_q), .cm_go(st_cm), .ccount_cm(ccount_cm));
  // ---- C: mmio response ----
  lsu_mmio_in u_mmio_in (
    .resp_is_mmio(periph_resp_is_mmio), .resp_rdata(periph_resp_rdata), .unc_valid(unc_valid_q),
    .unc_is_load(unc_is_load_q), .unc_idx(unc_idx_q), .fin_count_q(fin_v0.count), .ld_st_q(ld_st_q), .st_st_q(st_q),
    .unc_valid_o(unc_valid_resp), .ld_mm(ld_mm), .st_mm(st_mmgo), .fin_op(fin_o0));
  // ---- D / E: dcache responses ----
  lsu_dc_resp_ld u_dc_resp_ld (
    .rsp_valid(dcl_valid), .rsp_req_id(dcl_req_id), .rsp_data(dcl_data), .rsp_replay(dcl_replay),
    .fill_valid(fill_valid), .fill_line(fill_line), .wdc_q(wdc_v0), .wd_gen_q(wd_gen_q), .wd_wait_q(wd_wait_q),
    .fin_count_c(fin_v1.count), .ld_st_q(ld_st_q), .ld_st_rsp(ld_st_rsp), .fld_q(ld_fld_q), .fld_e(ld_fld_e),
    .ev(ld_dc), .wd_set(wd_set), .wd_set_val(wd_set_val), .wd_clr(wd_clr), .wdc_op(wdc_o0), .fin_op(fin_o1));
  lsu_dc_resp_st u_dc_resp_st (
    .rsp_valid(dcs_valid), .rsp_req_id(dcs_req_id), .rsp_replay(dcs_replay), .fill_valid(fill_valid),
    .fill_line(fill_line), .stq_head(stq_head_q), .stq_count(stq_count_q), .stq_ccount(ccount_cm), .st_q(st_q),
    .st_dc(st_dc), .wait_dc(st_wait_dc), .fld_q(st_fld_q), .fld_e(st_fld_e), .ev(st_dce), .wk_go(st_wk));
  // ---- F: write-back (SC / STA first, loads take the remaining ports) ----
  logic [RCW-1:0]  n_sc;
  logic            sc_clear;
  logic [NLD-1:0]  sc_valid, sc_dest_en, sc_pf_store;
  logic [31:0]     sc_diag_val [NLD], sc_result [NLD];
  logic [PRFW-1:0] sc_dest_preg [NLD];
  logic [BRW-1:0]  sc_br_mask [NLD];
  logic [ROBW-1:0] sc_rob_idx [NLD];
  lsu_wb_stq u_wb_stq (
    .mdone_q(mdone_v0), .lrsc_valid_q(lrsc_valid_q), .lrsc_addr_q(lrsc_addr_q), .st_dc(st_dc), .fld_q(st_fld_q),
    .ev(st_wbe), .mdone_op(mdone_o0), .sc_clear(sc_clear), .n_sc(n_sc), .sc_valid(sc_valid),
    .sc_diag_val(sc_diag_val), .sc_result(sc_result), .sc_dest_preg(sc_dest_preg), .sc_br_mask(sc_br_mask),
    .sc_rob_idx(sc_rob_idx), .sc_dest_en(sc_dest_en), .sc_pf_store(sc_pf_store), .sta_valid(sta_wb_valid),
    .sta_vaddr(sta_wb_vaddr), .sta_br_mask(sta_wb_br_mask), .sta_rob_idx(sta_wb_rob_idx),
    .sta_pf_store(sta_wb_pf_store));
  assign lrsc_valid_f1 = lrsc_valid_q && !sc_clear;   // an SC consumed the reservation
  lsu_wb_ldq u_wb_ldq (
    .finish_d(fin_v2), .ld_st_rsp(ld_st_rsp), .fld_q(ld_fld_q), .result_f(ld_result_f), .n_sc(n_sc),
    .sc_valid(sc_valid), .sc_diag_val(sc_diag_val), .sc_result(sc_result), .sc_dest_preg(sc_dest_preg),
    .sc_br_mask(sc_br_mask), .sc_rob_idx(sc_rob_idx), .sc_dest_en(sc_dest_en), .sc_pf_store(sc_pf_store),
    .lrsc_valid_i(lrsc_valid_f1), .lrsc_addr_i(lrsc_addr_q), .lrsc_br_i(lrsc_br_q), .wb_go(ld_wb_go),
    .fin_op(fin_o2), .lrsc_valid_o(lrsc_valid_f2), .lrsc_addr_o(lrsc_addr_f2), .lrsc_br_o(lrsc_br_f2),
    .wb_valid(wb_valid), .wb_diag_val(wb_diag_val), .wb_result(wb_result), .wb_dest_preg(wb_dest_preg),
    .wb_br_mask(wb_br_mask), .wb_rob_idx(wb_rob_idx), .wb_dest_en(wb_dest_en), .wb_pf_load(wb_pf_load),
    .wb_pf_store(wb_pf_store));
  // ---- G: EXU requests ----
  lsu_exe_in_st u_exe_st (
    .sdu_valid(sdu_valid), .sdu_result(sdu_result), .sdu_rob_idx(sdu_rob_idx), .sdu_rob_flag(sdu_rob_flag),
    .sdu_stq_idx(sdu_stq_idx), .sta_valid(sta_valid), .sta_result(sta_result), .sta_dest_preg(sta_dest_preg),
    .sta_func3(sta_func3), .sta_is_atomic(sta_is_atomic), .sta_amo_op(sta_amo_op), .sta_rob_idx(sta_rob_idx),
    .sta_rob_flag(sta_rob_flag), .sta_stq_idx(sta_stq_idx), .st_dc(st_dc), .fld_q(st_fld_q), .ev(st_ex),
    .mdone_op(mdone_o1), .wmst_op(wmst_o0));
  lsu_exe_in_ld u_exe_ld (
    .req_valid(ldu_valid), .req_result(ldu_result), .req_dest_preg(ldu_dest_preg), .req_func3(ldu_func3),
    .req_is_atomic(ldu_is_atomic), .req_amo_op(ldu_amo_op), .req_rob_idx(ldu_rob_idx), .req_rob_flag(ldu_rob_flag),
    .req_stq_idx(ldu_stq_idx), .req_stq_flag(ldu_stq_flag), .req_ldq_idx(ldu_ldq_idx), .fld_q(ld_fld_q),
    .ev(ld_agu), .wmld_op(wmld_o0));
  // ---- H: MMU requests ----
  lsu_tlb_sel #(.NP(NLD)) u_tlb_ld (
    .wait_i(wmld_v1), .wait_tlb(ld_wait_tlb), .vaddr(ld_vaddr_e), .req_valid(mmu_ld_req_valid),
    .req_vaddr(mmu_ld_req_vaddr), .req_entry_idx(mmu_ld_req_entry_idx), .req_wait_idx(mmu_ld_req_wait_idx));
  lsu_tlb_sel #(.NP(NST)) u_tlb_st (
    .wait_i(wmst_v1), .wait_tlb(st_wait_tlb), .vaddr(st_vaddr_e), .req_valid(mmu_st_req_valid),
    .req_vaddr(mmu_st_req_vaddr), .req_entry_idx(mmu_st_req_entry_idx), .req_wait_idx(mmu_st_req_wait_idx));
  // ---- I: MMU responses ----
  lsu_tlb_resp_ld u_tlb_resp_ld (
    .rsp_valid(mmu_ld_valid), .rsp_paddr(mmu_ld_paddr), .rsp_result(mmu_ld_result), .rsp_entry_idx(mmu_ld_entry_idx),
    .rsp_wait_idx(mmu_ld_wait_idx), .wmld_g_valid(wmld_v1.valid), .wmld_g_idx(wmld_v1.idx), .wmld_k(wmld_v2),
    .stlf_count(stlf_v0.count), .fin_count(fin_v3.count),
    .ld_st_agu(ld_st_agu), .ld_st_tlb(ld_st_tlb), .tr_ev(ld_tr), .tw_ev(ld_tw), .wmld_kill_op(wmld_o1),
    .wmld_kp_op(wmld_o2), .stlf_op(stlf_o0), .fin_op(fin_o3), .lrsc_clear(lrsc_clear_ld));
  lsu_tlb_resp_st u_tlb_resp_st (
    .rsp_valid(mmu_st_valid), .rsp_paddr(mmu_st_paddr), .rsp_result(mmu_st_result), .rsp_entry_idx(mmu_st_entry_idx),
    .rsp_wait_idx(mmu_st_wait_idx), .wmst_g(wmst_v1), .st_exe(st_exe), .st_tlb(st_tlb), .tr_ev(st_tre),
    .tw_ev(st_twe), .wmst_op(wmst_o1), .mdone_op(mdone_o2), .lrsc_clear(lrsc_clear_st));
  // ---- J: store-to-load forwarding ----
  logic        unc_set_ld, unc_set_st;
  logic [31:0] unc_addr_ld, unc_addr_st, unc_wdata_st;
  logic [2:0]  unc_func3_ld, unc_func3_st;
  logic [RIW-1:0] unc_idx_ld, unc_idx_st;
  lsu_stlf u_stlf (
    .stlf_i(stlf_v1), .stlf_pk_count(stlf_v2.count), .wdc_count(wdc_v1.count),
    .fin_count(fin_v4.count), .unc_valid_i(unc_valid_resp),
    .rb_head_valid(rb_head_valid), .rb_head_rob_idx(rb_head_rob_idx), .rb_hi_valid(rb_hi_valid),
    .rb_hi_rob_idx(rb_hi_rob_idx), .ld_st_win(ld_st_win), .ld_fld(ld_fld_e), .stq_head(stq_head_q),
    .stq_head_flag(stq_head_flag_q), .st_st(st_win), .st_fld(st_fld_e), .ev(ld_sf), .stlf_pop_op(stlf_o1),
    .stlf_app_op(stlf_o2), .wdc_op(wdc_o1), .fin_op(fin_o4), .unc_set(unc_set_ld), .unc_addr(unc_addr_ld),
    .unc_func3(unc_func3_ld), .unc_idx(unc_idx_ld));
  // ---- K: dispatch allocation ----
  lsu_alloc u_alloc (
    .ldq_req(dis_ldq_req), .ldq_idx(dis_ldq_idx), .ldq_br_mask(dis_ldq_br_mask), .ldq_rob_idx(dis_ldq_rob_idx),
    .ldq_rob_flag(dis_ldq_rob_flag), .stq_req(dis_stq_req), .stq_br_mask(dis_stq_br_mask),
    .stq_rob_idx(dis_stq_rob_idx), .stq_rob_flag(dis_stq_rob_flag), .stq_head(stq_head_q), .stq_count(stq_count_q),
    .ld_ev(ld_al), .st_ev(st_ale), .stq_count_al(count_al));
  // ---- L: flush / mispredict / clear_mask (entries apply theirs themselves) ----
  lsu_stq_ptr u_ptr (
    .clk(clk), .rst_n(rst_n), .flush(rb_flush), .mispred(dec_mispred), .dec_br_mask(dec_br_mask),
    .ccount_cm(ccount_cm), .count_al(count_al), .br_al(st_br_al), .st_nx(st_nx), .head_q(stq_head_q),
    .head_flag_q(stq_head_flag_q), .count_q(stq_count_q), .ccount_q(stq_ccount_q), .count_flushed(count_flushed),
    .count_fl(count_fl), .ccount_fl(ccount_fl), .clr_win(st_clr_win));
  lsu_flush_ring_ld u_fl_wmld (.flush(rb_flush), .mispred(dec_mispred), .ring_idx(wmld_v3.idx), .ld_empty(ld_empty),
    .op(wmld_o3));
  lsu_flush_ring_ld u_fl_stlf (.flush(rb_flush), .mispred(dec_mispred), .ring_idx(stlf_v3.idx), .ld_empty(ld_empty),
    .op(stlf_o3));
  lsu_flush_ring_ld u_fl_fin  (.flush(rb_flush), .mispred(dec_mispred), .ring_idx(fin_v5.idx), .ld_empty(ld_empty),
    .op(fin_o5));
  lsu_flush_ring_ld u_fl_wdc  (.flush(rb_flush), .mispred(dec_mispred), .ring_idx(wdc_v2.idx), .ld_empty(ld_empty),
    .op(wdc_o2));
  lsu_flush_ring_st u_fl_wmst  (.flush(rb_flush), .mispred(dec_mispred), .ring_idx(wmst_v2.idx),
    .stq_head(stq_head_q),
    .stq_count(count_fl), .op(wmst_o2));
  lsu_flush_ring_st u_fl_mdone (.flush(rb_flush), .mispred(dec_mispred), .ring_idx(mdone_v3.idx),
    .stq_head(stq_head_q),
    .stq_count(count_fl), .op(mdone_o3));

  lsu_unc u_unc (
    .clk(clk), .rst_n(rst_n), .valid_post_resp(unc_valid_resp), .valid_q(unc_valid_q), .is_load_q(unc_is_load_q),
    .idx_q(unc_idx_q), .ld_set(unc_set_ld), .ld_addr(unc_addr_ld), .ld_func3(unc_func3_ld), .ld_idx(unc_idx_ld),
    .flush(rb_flush), .mispred(dec_mispred), .ld_empty(ld_empty), .st_st_pre_flush(st_al), .stq_head(stq_head_q),
    .count_flushed(count_flushed), .count_final(count_fl), .st_set(unc_set_st), .st_addr(unc_addr_st),
    .st_wdata(unc_wdata_st), .st_func3(unc_func3_st), .st_idx(unc_idx_st), .valid_pre_st(unc_valid_pre_st),
    .valid_o(unc_valid_o), .is_load_o(unc_is_load_o), .addr_o(unc_addr_o), .wdata_o(unc_wdata_o),
    .func3_o(unc_func3_o), .idx_o(unc_idx_o));
  lsu_lrsc u_lrsc (
    .clk(clk), .rst_n(rst_n), .valid_q(lrsc_valid_q), .addr_q(lrsc_addr_q), .br_q(lrsc_br_q), .valid_i(lrsc_valid_f2),
    .addr_i(lrsc_addr_f2), .br_i(lrsc_br_f2), .pf_clear(lrsc_clear_ld || lrsc_clear_st), .mispred(dec_mispred),
    .dec_br_mask(dec_br_mask), .clear_mask(dec_clear_mask));
  // ---- M / N: DCache requests ----
  lsu_dc_req_ld u_dc_req_ld (
    .wdc_i(wdc_v3), .wd_wait(wd_wait_wk), .req_gen_q(req_gen_q), .ld_st_fl(ld_st_fl), .ld_fld(ld_fld_e),
    .req_valid(dcl_req_valid), .req_addr(dcl_req_addr), .req_id(dcl_req_id_o), .iss_go(ld_iss), .wd_dec(wd_dec),
    .gen_we(wd_gen_we), .gen_wd(wd_gen_wd), .n_iss_total(n_iss));
  lsu_wd_slot u_wd_slot (
    .clk(clk), .rst_n(rst_n), .set(wd_set), .set_val(wd_set_val), .clr(wd_clr), .dec(wd_dec), .gen_we(wd_gen_we),
    .gen_wd(wd_gen_wd), .n_iss(n_iss), .wait_q(wd_wait_q), .wait_wk(wd_wait_wk), .gen_q(wd_gen_q),
    .req_gen_q(req_gen_q));
  lsu_dc_req_st u_dc_req_st (
    .stq_head(stq_head_q), .stq_ccount(ccount_fl), .unc_valid(unc_valid_pre_st), .st_wdr_q(st_wdr), .st_al(st_al),
    .st_wait(st_wait_n), .st_fld(st_fld_e), .req_valid(dcs_req_valid), .req_addr(dcs_req_addr),
    .req_data(dcs_req_data), .req_strb(dcs_req_strb), .req_id(dcs_req_id_o), .ev(st_ise), .unc_set(unc_set_st),
    .unc_addr(unc_addr_st), .unc_wdata(unc_wdata_st), .unc_func3(unc_func3_st), .unc_idx(unc_idx_st));
  // ---- O: MMIO request ----
  lsu_mmio_out u_mmio_out (
    .peripheral_ready(periph_resp_ready), .unc_valid(unc_valid_o), .unc_is_load(unc_is_load_o), .unc_addr(unc_addr_o),
    .unc_wdata(unc_wdata_o), .unc_func3(unc_func3_o), .req_is_mmio(periph_req_is_mmio), .req_wen(periph_req_wen),
    .req_addr(periph_req_addr), .req_wdata(periph_req_wdata), .req_fun3(periph_req_fun3));

endmodule

`default_nettype wire
