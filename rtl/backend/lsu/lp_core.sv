// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (staged LSU: wiring of L1 / L2 / write-back / replay / drain, docs/anal
`default_nettype none

module lp_core
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic                clk,
  input  logic                rst_n,
  // ROB / IDU broadcasts, commit
  input  logic [NCM-1:0]      cm_valid,
  input  logic [4:0]          cm_type [NCM],
  input  logic [4:0]          cm_amo_op [NCM],
  input  logic [SQW-1:0]      cm_stq_idx [NCM],
  input  logic                rb_flush,
  input  logic                rb_head_valid,
  input  logic [ROBW-1:0]     rb_head_rob_idx,
  input  logic                rb_hi_valid,
  input  logic [ROBW-1:0]     rb_hi_rob_idx,
  input  logic                dec_mispred,
  input  logic [BRW-1:0]      dec_br_mask,
  input  logic [BRW-1:0]      dec_clear_mask,
  // dispatch, EXU
  input  lp_dis_ld_t          dis_ld [NDIS],
  input  lp_dis_st_t          dis_st [NDIS],
  input  lp_std_t             sdw [NSD],
  input  lp_agu_ld_t          agl [NLD],
  input  lp_agu_st_t          ags [NST],
  // peripheral response
  input  logic                periph_is_mmio,
  input  logic [31:0]         periph_rdata,
  // DCache
  input  logic [NLD-1:0]      dcl_valid,
  input  logic [31:0]         dcl_req_id [NLD],
  input  logic [31:0]         dcl_data [NLD],
  input  logic [1:0]          dcl_replay [NLD],
  input  logic [NST-1:0]      dcs_valid,
  input  logic [31:0]         dcs_req_id [NST],
  input  logic [1:0]          dcs_replay [NST],
  input  logic                fill_valid,
  input  logic [LINEW-1:0]    fill_line,
  input  logic [NLD-1:0]      ld_retry_busy,
  input  logic [NST-1:0]      st_retry_busy,
  // MMU
  input  logic [NLD-1:0]      mmu_l_valid,
  input  logic [31:0]         mmu_l_paddr [NLD],
  input  logic [1:0]          mmu_l_result [NLD],
  input  logic [LQW-1:0]      mmu_l_entry [NLD],
  input  logic [NST-1:0]      mmu_s_valid,
  input  logic [31:0]         mmu_s_paddr [NST],
  input  logic [1:0]          mmu_s_result [NST],
  input  logic [SQW-1:0]      mmu_s_entry [NST],
  // outputs
  output logic [SQW-1:0]      o_stq_tail,
  output logic                o_stq_tail_flag,
  output logic [CNTW-1:0]     o_stq_free,
  output logic [CNTW-1:0]     o_ldq_free,
  output logic [NDIS-1:0]     o_ldq_alloc_valid,
  output logic [LQW-1:0]      o_ldq_alloc_idx [NDIS],
  output logic                o_committed_store_pending,
  // LP_L2 wake-ups of the load consumers: [p] L2 speculative, [NLD+p] L3 register; cancel of a wrong one
  output logic [2*NLD-1:0]    o_wk_valid,
  output logic [PRFW-1:0]     o_wk_preg [2*NLD],
  output logic [NLD-1:0]      o_cn_valid,
  output logic [PRFW-1:0]     o_cn_preg [NLD],
  output logic [NLD-1:0]      wb_valid,
  output logic [31:0]         wb_diag [NLD],
  output logic [31:0]         wb_result [NLD],
  output logic [PRFW-1:0]     wb_dest [NLD],
  output logic [BRW-1:0]      wb_br [NLD],
  output logic [ROBW-1:0]     wb_rob [NLD],
  output logic [NLD-1:0]      wb_dest_en,
  output logic [NLD-1:0]      wb_pf_load,
  output logic [NLD-1:0]      wb_pf_store,
  output logic [NLD-1:0]      wb_defer,
  output logic [NLD-1:0]      wb_flushp,
  output logic [NST-1:0]      sta_valid,
  output logic [31:0]         sta_vaddr [NST],
  output logic [BRW-1:0]      sta_br [NST],
  output logic [ROBW-1:0]     sta_rob [NST],
  output logic [NST-1:0]      sta_pf,
  output logic                per_is_mmio,
  output logic                per_wen,
  output logic [31:0]         per_addr,
  output logic [31:0]         per_wdata,
  output logic [2:0]          per_func3,
  input  logic                periph_ready,
  output logic [NLD-1:0]      dcl_req_valid,
  output logic [NLD-1:0]      dcl_req_replay,
  output logic [31:0]         dcl_req_addr [NLD],
  output logic [30:0]         dcl_req_id_o [NLD],
  output logic [NST-1:0]      dcs_req_valid,
  output logic [31:0]         dcs_req_addr [NST],
  output logic [31:0]         dcs_req_data [NST],
  output logic [4:0]          dcs_req_strb [NST],
  output logic [39:0]         dcs_req_l2 [NST],  // merged store {strb2, word2, data2}; strb2 == 0: none
  output logic [SQW-1:0]      dcs_req_id_o [NST],
  output logic [NLD-1:0]      mmu_l_req_valid,
  output logic [31:0]         mmu_l_req_vaddr [NLD],
  output logic [LQW-1:0]      mmu_l_req_idx [NLD],
  output logic [NST-1:0]      mmu_s_req_valid,
  output logic [31:0]         mmu_s_req_vaddr [NST],
  output logic [SQW-1:0]      mmu_s_req_idx [NST]
);
  // ------------------------------------------------------------------ registers outside the queues
  lp_pl12_t        pl12_q [NLD];
  logic [NRP-1:0]  rp_v_q;
  logic [LQW-1:0]  rp_ldq_q [NRP];
  logic            srp_v_q;
  logic [SQW-1:0]  srp_stq_q;

  // ------------------------------------------------------------------ queue state / views
  lp_ldq_t         ldq_q [LQ];
  lp_stq_t         sq [SQ];
  logic [LQ-1:0]   empty_w, l2_ok, rs_ok, wbp3, wbp_m, pipe_r, wb3_r, wbp_r, pipe5, pipe8, empty8, dead_r, rdy9;
  logic [31:0]     res_v [LQ];
  logic [EPW-1:0]  epoch_nx [LQ];
  logic [NLD-1:0]  ag_acc;
  logic            mi_v;
  logic [LQW-1:0]  mi_idx;
  logic [31:0]     mi_addr;
  logic [2:0]      mi_func3;
  logic [SQW-1:0]  head_q;
  logic            head_flag_q;
  logic [CNTW-1:0] count_q, ccount_q, count_flushed;
  logic [SQ-1:0]   alive_w, win4, win13, alive_post, alive_fl, cm_go, al_v, ev_ret, done_q_v;
  logic [SQ-1:0][NDIS-1:0] al_slot;
  logic [SQ-1:0]   cv_va, done_v, trp_v, d_elig, d_rdy, sd_acc;
  logic [11:0]     cv_voff [SQ];
  logic [2:0]      cv_f3 [SQ];
  lp_sta_info_t    vw [SQ];
  logic [NST-1:0]  sa_acc;

  // ------------------------------------------------------------------ uncached unit, reservation
  logic            unc_valid_q, unc_is_load_q, unc_valid_post_resp, unc_valid_pre_st, unc_valid_o, unc_is_load_o;
  logic [SQW-1:0]  unc_idx_q;
  logic [31:0]     unc_addr_o, unc_wdata_o;
  logic [2:0]      unc_func3_o;
  logic            rsv_valid_q;
  logic [31:0]     rsv_addr_q;
  logic            resp_fire;
  assign resp_fire = periph_is_mmio && unc_valid_q;

  // ------------------------------------------------------------------ L2 and DCache responses (P3)
  lp_l2dec_t       l2_dec [NLD];
  logic [31:0]     fwd_data [NLD];
  logic [NLD-1:0]  wbd_l2, rs_dir, wbd_v, wbd_hasdata;
  logic [LQW-1:0]  rs_idx [NLD], wbd_idx [NLD];
  logic [31:0]     wbd_data [NLD];
  lp_l2 u_l2 (.pl12(pl12_q), .sq(sq), .alive_w(alive_w), .dec(l2_dec), .fwd_data(fwd_data));

  always_comb begin
    for (int p = 0; p < NLD; p++) begin
      rs_idx[p] = dcl_req_id[p][LQW-1:0];
      wbd_l2[p] = l2_dec[p].act == L2_WBD && l2_ok[pl12_q[p].ldq];
      rs_dir[p] = dcl_valid[p] && !dcl_req_id[p][31] && rs_ok[rs_idx[p]] && dcl_replay[p] == RT_HIT && !wbd_l2[p];
      wbd_v[p] = wbd_l2[p] || rs_dir[p];
      wbd_idx[p] = wbd_l2[p] ? pl12_q[p].ldq : rs_idx[p];
      wbd_hasdata[p] = wbd_l2[p] ? (pl12_q[p].tlb != TLB_PF) : 1'b1;
      wbd_data[p] = wbd_l2[p] ? fwd_data[p]
                              : lsu_pkg::extract_data(dcl_data[p], ldq_q[rs_idx[p]].paddr[1:0], ldq_q[rs_idx[p]].func3);
    end
  end

  // ------------------------------------------------------------------ L3 register (LP_L2[0])
  logic [NLD-1:0]  wbw_v, wbw_hd;
  logic [LQW-1:0]  wbw_idx [NLD];
  logic [31:0]     wbw_data [NLD];
  lp_l3 u_l3 (.clk(clk), .rst_n(rst_n), .wbd_v(wbd_v), .wbd_idx(wbd_idx), .wbd_hasdata(wbd_hasdata),
              .wbd_data(wbd_data), .wb3_r(wb3_r), .wbw_v(wbw_v), .wbw_idx(wbw_idx), .wbw_hd(wbw_hd),
              .wbw_data(wbw_data));
  lp_wake u_wake (.clk(clk), .rst_n(rst_n), .flush(rb_flush), .mispred(dec_mispred), .dec_br_mask(dec_br_mask),
                  .pl12(pl12_q), .l2_ok(l2_ok), .ldq_q(ldq_q), .wbd_v(wbd_v), .wbd_idx(wbd_idx), .wbw_v(wbw_v),
                  .wbw_idx(wbw_idx), .wk_valid(o_wk_valid), .wk_preg(o_wk_preg), .cn_valid(o_cn_valid),
                  .cn_preg(o_cn_preg));

  // ------------------------------------------------------------------ write-back (P5)
  logic [LQ-1:0]   wb_go, wb_go_d;
  logic [SQ-1:0]   wb_go_s, sc_go;
  logic            lr1_v, sc_clr, lr2_v;
  logic [31:0]     lr1_addr, lr2_addr;
  logic [BRW-1:0]  lr1_br, lr2_br;

  logic [LQ-1:0]   wbp_sel, pipe8_sel;
  assign pipe8_sel = ((LP_CUT & 65536) != 0) ? ~dead_r : pipe8;
  assign wbp_sel = ((LP_CUT & 8) != 0) ? (((LP_CUT & 131072) != 0) ? (wbp_r | wbp_m) : wbp_r) : wbp3;  // F, FM
  lp_wb u_wb (
    .wbd_v(wbw_v), .wbd_idx(wbw_idx), .wbd_hasdata(wbw_hd), .wbd_data(wbw_data),
    .ldq_q(ldq_q), .ldq_res(res_v), .wbp_vec(wbp_sel), .sq(sq), .alive_w(alive_w), .head_q(head_q),
    .rsv_valid(rsv_valid_q), .rsv_addr(rsv_addr_q), .wb_go(wb_go), .wb_go_d(wb_go_d), .wb_go_s(wb_go_s),
    .sc_go(sc_go),
    .wb_valid(wb_valid), .wb_diag(wb_diag), .wb_result(wb_result), .wb_dest(wb_dest), .wb_br(wb_br),
    .wb_rob(wb_rob), .wb_dest_en(wb_dest_en), .wb_pf_load(wb_pf_load), .wb_pf_store(wb_pf_store),
    .wb_defer(wb_defer), .wb_flushp(wb_flushp),
    .sta_valid(sta_valid), .sta_vaddr(sta_vaddr), .sta_br(sta_br), .sta_rob(sta_rob), .sta_pf(sta_pf),
    .lr1_v(lr1_v), .lr1_addr(lr1_addr), .lr1_br(lr1_br), .sc_clr(sc_clr),
    .lr2_v(lr2_v), .lr2_addr(lr2_addr), .lr2_br(lr2_br));

  // ------------------------------------------------------------------ L1 (P6 .. P9, P12)
  lp_l1in_t        l1 [NLD];
  lp_tl_t          tl_l [NLD], tl_s [NST];
  logic [1:0]      l_tlb [NLD];
  logic            l_hit [NLD], l_mmio [NLD];
  logic [31:0]     l_paddr [NLD];
  logic [NRP-1:0]  rp_cons, rp_pipe;
  lp_ldq_t         rp_f [NRP];
  logic [NST-1:0]  s1_v, s1_replay, tl_s_miss;
  logic [SQW-1:0]  s1_stq [NST];
  logic            srp_cons, srp_ok, pf_any;

  always_comb begin
    for (int r = 0; r < NRP; r++) begin
      rp_f[r] = ldq_q[rp_ldq_q[r]];
      rp_pipe[r] = ((LP_CUT & 32) != 0) ? pipe_r[rp_ldq_q[r]] : pipe5[rp_ldq_q[r]];
    end
    srp_ok = alive_w[srp_stq_q] && sq[srp_stq_q].va_v && !sq[srp_stq_q].pa_v && !sq[srp_stq_q].pf;
  end

  lp_l1 u_l1 (
    .ag(agl), .ag_acc(ag_acc), .sa(ags), .sa_acc(sa_acc),
    .rp_v(rp_v_q), .rp_ldq(rp_ldq_q), .rp_pipe(rp_pipe), .rp_f(rp_f),
    .srp_v(srp_v_q), .srp_stq(srp_stq_q), .srp_ok(srp_ok), .srp_vaddr(sq[srp_stq_q].vaddr),
    .mmu_l_valid(mmu_l_valid), .mmu_l_paddr(mmu_l_paddr), .mmu_l_result(mmu_l_result), .mmu_l_entry(mmu_l_entry),
    .mmu_s_valid(mmu_s_valid), .mmu_s_paddr(mmu_s_paddr), .mmu_s_result(mmu_s_result), .mmu_s_entry(mmu_s_entry),
    .mmu_l_req_valid(mmu_l_req_valid), .mmu_l_req_vaddr(mmu_l_req_vaddr), .mmu_l_req_idx(mmu_l_req_idx),
    .mmu_s_req_valid(mmu_s_req_valid), .mmu_s_req_vaddr(mmu_s_req_vaddr), .mmu_s_req_idx(mmu_s_req_idx),
    .l1(l1), .tl_l(tl_l), .l_tlb(l_tlb), .l_hit(l_hit), .l_paddr(l_paddr), .l_mmio(l_mmio), .rp_cons(rp_cons),
    .s1_v(s1_v), .s1_replay(s1_replay), .s1_stq(s1_stq), .tl_s(tl_s), .tl_s_miss(tl_s_miss),
    .srp_cons(srp_cons), .pf_any(pf_any));

  // memory speculation (LSU_MEMSPEC): store-queue views, wait table, per-slot permission to pass unknown stores
  logic [NLD-1:0]  l1_launch, cam_en, cam_unk, spec_ok;
  logic            unk_any;
  logic [SQW-1:0]  unk_rank, sa_rank [NST];
  logic [11:0]     sa_voff [NST];
  logic [2:0]      sa_f3 [NST];
  logic [LQ-1:0]   vio_new;
  lp_dis_ld_t      dis_ldw [NDIS];
  lp_ms u_ms (.clk(clk), .rst_n(rst_n), .sq(sq), .head_q(head_q), .ags(ags), .dis_ld(dis_ld), .vio_new(vio_new),
              .empty_w(empty_w), .ldq_q(ldq_q), .l1(l1), .unk_any(unk_any), .unk_rank(unk_rank),
              .sa_rank(sa_rank), .sa_voff(sa_voff), .sa_f3(sa_f3), .dis_ldw(dis_ldw), .spec_ok(spec_ok));
  lp_l1b u_l1b (.clk(clk), .l1(l1), .l_hit(l_hit), .l_mmio(l_mmio), .l_paddr(l_paddr), .l_tlb(l_tlb),
                .ld_retry_busy(ld_retry_busy), .pipe8(pipe8_sel), .epoch_nx(epoch_nx), .head_q(head_q),
                .head_flag_q(head_flag_q), .count_q(count_q), .cv_va(cv_va), .cv_voff(cv_voff), .cv_f3(cv_f3), .sq(sq),
                .spec_ok(spec_ok), .cam_en(cam_en), .cam_unk(cam_unk), .l1_launch(l1_launch),
                .dcl_req_valid(dcl_req_valid), .dcl_req_addr(dcl_req_addr),
                .dcl_req_id_o(dcl_req_id_o), .pl12_q(pl12_q));

  for (genvar k = 0; k < NLD; k++) begin : g_rpl  // EXP-009 filter: last DCache response of the entry was not HIT
    assign dcl_req_replay[k] = dcl_req_valid[k] && (ldq_q[l1[k].ldq].rtype != RT_HIT); end

  // ------------------------------------------------------------------ STA events broadcast to the wake-up (P13)
  lp_sta_info_t sta_info [NST];
  logic [SQ-1:0] ev_sta, ev_sc;
  always_comb begin
    ev_sta = '0;
    for (int k = 0; k < NST; k++) begin
      sta_info[k] = vw[s1_stq[k]];
      sta_info[k].v = s1_v[k] && (!s1_replay[k] || tl_s[k].hit || tl_s[k].pf);
      sta_info[k].stq = s1_stq[k];
      if (sta_info[k].v) ev_sta[s1_stq[k]] = 1'b1;
    end
  end
  assign ev_sc = sc_go;

  // ------------------------------------------------------------------ queues
  logic [LQ-1:0] rp_pick;
  logic [BRW-1:0] br_al [SQ];
  logic [SQ-1:0] srp_take;
  always_comb begin
    for (int j = 0; j < SQ; j++) begin
      br_al[j] = sq[j].br_mask;
      for (int i = 0; i < NDIS; i++) if (al_slot[j][i]) br_al[j] = dis_st[i].br_mask;
    end
  end

  logic [NDIS-1:0] st_al_req;
  always_comb begin
    for (int i = 0; i < NDIS; i++) st_al_req[i] = dis_st[i].v;
  end

  logic [SQ-1:0] wbd_vec;
  always_comb begin
    for (int j = 0; j < SQ; j++) wbd_vec[j] = sq[j].wbd;
  end

  for (genvar j = 0; j < SQ; j++) begin : g_dq
    assign done_q_v[j] = sq[j].done;
  end
  lp_ptr u_ptr (
    .clk(clk), .rst_n(rst_n), .flush(rb_flush), .mispred(dec_mispred), .dec_br_mask(dec_br_mask),
    .cm_valid(cm_valid), .cm_type(cm_type), .cm_amo_op(cm_amo_op), .cm_stq_idx(cm_stq_idx), .wbd_vec(wbd_vec),
    .cm_go(cm_go), .al_req(st_al_req), .al_v(al_v), .al_slot(al_slot), .br_al(br_al), .done_vec(done_v),
    .done_q_vec(done_q_v),
    .ev_ret(ev_ret), .head_q(head_q), .head_flag_q(head_flag_q), .count_q(count_q), .ccount_q(ccount_q),
    .alive_w(alive_w), .win4(win4), .win13(win13), .alive_post(alive_post),
    .count_flushed(count_flushed), .alive_fl(alive_fl));

  logic [SQ-1:0] dr_pick, dr_mmio, dr_fol, wb_mark, wbi_v;  logic [SQW-1:0] dr_ml [SQ];
  logic [SQ-1:0] alive_flushed;
  logic fill_en;
  assign fill_en = fill_valid && LSU_WAIT_MSHR_FILL != 0;

  lp_stq u_stq (
    .clk(clk), .rst_n(rst_n), .rb_flush(rb_flush), .clear_mask(dec_clear_mask), .head_q(head_q), .alive_w(alive_w),
    .win4(win4), .win13(win13), .cm_go(cm_go),
    .mm_done(resp_fire && !unc_is_load_q), .mm_idx(unc_idx_q),
    .dcs_valid(dcs_valid), .dcs_req_id(dcs_req_id), .dcs_replay(dcs_replay), .fill_v(fill_en), .fill_line(fill_line),
    .wb_go_s(wb_go_s), .sc_go(sc_go), .rsv_valid(rsv_valid_q), .rsv_addr(rsv_addr_q),
    .sdw(sdw), .ags(ags), .s1_v(s1_v), .s1_stq(s1_stq), .tl_s_miss(tl_s_miss), .tl_s(tl_s),
    .al_v(al_v), .al_slot(al_slot), .dis_st(dis_st),
    .dr_pick(dr_pick), .dr_fol(dr_fol), .dr_ml(dr_ml), .dr_mmio(dr_mmio), .srp_take(srp_take),
    .wb_mark(wb_mark), .wbi_v(wbi_v),
    .sq(sq), .cv_va(cv_va), .cv_voff(cv_voff), .cv_f3(cv_f3), .vw(vw), .done_v(done_v), .trp_v(trp_v),
    .d_elig(d_elig), .d_rdy(d_rdy), .sd_acc(sd_acc), .sa_acc(sa_acc));

  lp_ldq u_ldq (
    .clk(clk), .rst_n(rst_n), .flush(rb_flush), .mispred(dec_mispred), .dec_br_mask(dec_br_mask),
    .clear_mask(dec_clear_mask),
    .mm_go(resp_fire && unc_is_load_q), .mm_idx(unc_idx_q), .mm_data(periph_rdata),
    .pl12(pl12_q), .l2_dec(l2_dec), .dcl_valid(dcl_valid), .dcl_req_id(dcl_req_id), .dcl_data(dcl_data),
    .dcl_replay(dcl_replay), .rs_busy(wbd_l2),
    .wb_go(wb_go), .wb_go_d(wb_go_d), .wbd_v(wbw_v), .wbd_idx(wbw_idx), .wbd_data(wbw_data), .agl(agl), .l1(l1),
    .tl_l(tl_l), .l1_launch(l1_launch),
    .head_tag({head_flag_q, head_q}), .count_q(count_q), .unk_any(unk_any), .unk_rank(unk_rank), .sa_v(sa_acc),
    .sa_rank(sa_rank), .sa_voff(sa_voff), .sa_f3(sa_f3), .cam_en(cam_en), .cam_unk(cam_unk), .vio_new(vio_new),
    .rb_hi_valid(rb_hi_valid), .rb_hi_rob_idx(rb_hi_rob_idx), .rb_head_valid(rb_head_valid),
    .rb_head_rob_idx(rb_head_rob_idx), .stq_head_tag({head_flag_q, head_q}), .unc_busy(unc_valid_post_resp),
    .dis(dis_ldw),
    .ev_sta(ev_sta), .ev_data(sd_acc), .ev_ret(ev_ret), .ev_sc(ev_sc),
    .alive_post(((LP_CUT & 1) != 0) ? alive_w : alive_post),
    .sta_info(sta_info), .sdw(sdw), .fill_v(fill_en), .fill_line(fill_line),
    .rp_pick(rp_pick),
    .q_o(ldq_q), .empty_w(empty_w), .l2_ok(l2_ok), .rs_ok(rs_ok), .res_v(res_v), .wbp3(wbp3),
    .pipe_r(pipe_r), .wb3_r(wb3_r), .wbp_r(wbp_r), .wbp_m(wbp_m),
    .ag_acc(ag_acc), .pipe5(pipe5), .pipe8(pipe8), .dead_r(dead_r), .empty8(empty8), .epoch_nx(epoch_nx), .rdy9(rdy9),
    .mi_v(mi_v), .mi_idx(mi_idx), .mi_addr(mi_addr), .mi_func3(mi_func3));

  // ------------------------------------------------------------------ store drain (P13), uncached unit, reservation
  logic [NST-1:0] dcs_busy_in;
  logic           st_set;
  logic [31:0]    st_addr, st_wdata;
  logic [2:0]     st_func3;
  logic [SQW-1:0] st_idx;
  logic [SQ-1:0]  st_mmw;
  always_comb begin
    for (int j = 0; j < SQ; j++) st_mmw[j] = sq[j].mmw;
    dcs_busy_in = st_retry_busy;
  end

  lp_drain u_drain (
    .clk(clk), .rst_n(rst_n), .sq(sq), .d_rdy(d_rdy), .d_elig(d_elig), .wbi_v(wbi_v), .head_q(head_q),
    .retry_busy(dcs_busy_in), .unc_busy(unc_valid_pre_st), .dcs_valid(dcs_valid), .dcs_req_id(dcs_req_id),
    .dcs_replay(dcs_replay), .wb_mark(wb_mark), .dr_pick(dr_pick), .dr_fol(dr_fol), .dr_ml(dr_ml), .dr_mmio(dr_mmio),
    .req_valid(dcs_req_valid), .req_addr(dcs_req_addr), .req_data(dcs_req_data), .req_strb(dcs_req_strb),
    .req_l2(dcs_req_l2), .req_id(dcs_req_id_o), .st_set(st_set), .st_addr(st_addr), .st_wdata(st_wdata),
    .st_func3(st_func3), .st_idx(st_idx));

  lp_unc u_unc (
    .clk(clk), .rst_n(rst_n), .resp_fire(resp_fire), .valid_q(unc_valid_q), .is_load_q(unc_is_load_q),
    .idx_q(unc_idx_q), .valid_post_resp(unc_valid_post_resp),
    .ld_set(mi_v && !unc_valid_post_resp), .ld_addr(mi_addr), .ld_func3(mi_func3), .ld_idx(mi_idx),
    .flush(rb_flush), .mispred(dec_mispred), .ld_empty(((LP_CUT & 16384) != 0) ? dead_r : empty8),
    .st_mmw(st_mmw), .alive_flushed(alive_flushed),
    .alive_final(alive_fl), .st_set(st_set), .st_addr(st_addr), .st_wdata(st_wdata), .st_func3(st_func3),
    .st_idx(st_idx), .valid_pre_st(unc_valid_pre_st), .valid_o(unc_valid_o), .is_load_o(unc_is_load_o),
    .addr_o(unc_addr_o), .wdata_o(unc_wdata_o), .func3_o(unc_func3_o));

  // alive_flushed: window after the rob-flush step only (keep = min(ccount, count))
  logic [SQ-1:0] flushed_mask;
  always_comb begin
    flushed_mask = (count_flushed >= CNTW'(SQ)) ? '1 : ~('1 << count_flushed[SQW-1:0]);
    alive_flushed = SQ'(rotl64(64'(flushed_mask), head_q));
  end

  assign per_is_mmio = periph_ready && unc_valid_o;
  assign per_wen = periph_ready && unc_valid_o && !unc_is_load_o;
  assign per_addr = unc_addr_o;
  assign per_wdata = unc_wdata_o;
  assign per_func3 = unc_func3_o;

  lp_rsv u_rsvm (.clk(clk), .rst_n(rst_n), .lr1_v(lr1_v), .lr1_addr(lr1_addr), .lr1_br(lr1_br), .sc_clr(sc_clr),
                 .lr2_v(lr2_v), .lr2_addr(lr2_addr), .lr2_br(lr2_br), .pf_any(pf_any), .mispred(dec_mispred),
                 .dec_br_mask(dec_br_mask), .clear_mask(dec_clear_mask), .rsv_valid_q(rsv_valid_q),
                 .rsv_addr_q(rsv_addr_q));

  lp_rp u_rp (.clk(clk), .rst_n(rst_n), .rdy9(rdy9),
              .empty8(((LP_CUT & 128) != 0) ? dead_r : empty8), .rp_cons(rp_cons), .srp_cons(srp_cons),
              .trp_v(trp_v), .alive_post(alive_post), .alive_fl(alive_fl), .rp_v_q(rp_v_q),
              .rp_ldq_q(rp_ldq_q), .rp_pick(rp_pick), .srp_v_q(srp_v_q), .srp_stq_q(srp_stq_q), .srp_take(srp_take));

  // outputs to dispatch / ROB
  lp_out u_out (.empty_w(empty_w), .head_q(head_q), .head_flag_q(head_flag_q), .count_q(count_q), .ccount_q(ccount_q),
                .o_stq_tail(o_stq_tail), .o_stq_tail_flag(o_stq_tail_flag), .o_stq_free(o_stq_free),
                .o_ldq_free(o_ldq_free), .o_ldq_alloc_valid(o_ldq_alloc_valid), .o_ldq_alloc_idx(o_ldq_alloc_idx),
                .o_committed_store_pending(o_committed_store_pending));
endmodule

`default_nettype wire
