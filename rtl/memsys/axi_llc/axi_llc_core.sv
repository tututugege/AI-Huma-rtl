`default_nettype none
// Ref: AXI_LLC.cpp  class AXI_LLC (comb() final call of a tick + seq())
// The LLC core on packed ports: instantiates the units and wires their narrow interfaces.  One tick, in the order
// the C++ evaluates it (each step only sees what the earlier steps of the tick decided):
//   1 read responses leave        (axi_llc_rq)
//   2 write path                  (axi_llc_victim response / load, axi_llc_wport, axi_llc_wsched)
//   3 lookup resolution           (axi_llc_resolve)      -> table write, MSHR, response, victim, write context
//   4 memory read path            (axi_llc_mshr response / issue, axi_llc_refill)
//   5 lookup launch and accept    (axi_llc_wsched, axi_llc_rdacc, axi_llc_lookup)
// Design note: docs/modules/axi_llc.md
module axi_llc_core
  import axi_llc_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic [NR-1:0] rd_v,
  input  logic [NR-1:0] rd_byp,
  input  logic [NR-1:0] rd_ready,
  input  logic [NR-1:0][31:0] rd_addr,
  input  logic [NR-1:0][7:0] rd_size,
  input  logic [NR-1:0][3:0] rd_id,
  input  logic [NW-1:0] wr_v,
  input  logic [NW-1:0] wr_byp,
  input  logic [NW-1:0] wr_ready,
  input  logic [NW-1:0][31:0] wr_addr,
  input  logic [NW-1:0][7:0] wr_size,
  input  logic [NW-1:0][3:0] wr_id,
  input  logic [NW-1:0][511:0] wr_data,
  input  logic [NW-1:0][63:0] wr_strb,
  input  logic mrd_ready,
  input  logic mrr_v,
  input  logic [511:0] mrr_data,
  input  logic [3:0] mrr_id,
  input  logic mwr_ready,
  input  logic mwr_resp_v,
  output logic [NR-1:0] rd_rdy,
  output logic [NR-1:0] rr_valid,
  output logic [NR-1:0][3:0] rr_id,
  output logic [NR-1:0][511:0] rr_data,
  output logic [NW-1:0] wr_rdy,
  output logic [NW-1:0] wr_resp_valid,
  output logic [NW-1:0][3:0] wr_resp_id,
  output logic mrd_v,
  output logic [31:0] mrd_addr,
  output logic [7:0] mrd_size,
  output logic [3:0] mrd_id,
  output logic mwr_v,
  output logic [31:0] mwr_addr,
  output logic [511:0] mwr_data,
  // registers read by the interconnect (hazard / id-conflict checks)
  output logic hz_lk_valid,
  output logic hz_lk_is_write,
  output logic [31:0] hz_lk_addr,
  output logic [1:0] hz_lk_master,
  output logic [3:0] hz_lk_id,
  output logic [NR-1:0] hz_rr_fresh,
  output logic [NMSHR-1:0] hz_ms_valid,
  output logic [NMSHR-1:0][1:0] hz_ms_master,
  output logic [NMSHR-1:0][3:0] hz_ms_id,
  output logic [NMSHR-1:0][31:0] hz_ms_line,
  output logic [NW-1:0] hz_wc_valid,
  output logic [NW-1:0][31:0] hz_wc_line,
  output logic [NW-1:0][31:0] hz_wr_line
);
  // ---------------- signals between the units ----------------
  // tables: one write per tick, from stage 2 (victim write-back done), 3 (lookup) or 4 (refill)
  logic t_ok;
  logic [WAYS-1:0] t_v, t_d;
  logic [WAYS-1:0][TAGW-1:0] t_t;
  logic [WAYS-1:0][511:0] t_line;
  logic [WB-1:0] t_repl;
  tw_t tw, tw_commit, tw_lookup, tw_refill;
  logic busy2, busy3;                          // a table write happened in stage 2 / up to stage 3
  // lookup engine
  logic lk_valid, lk_issued, lk_is_write, lk_bypass, lk_free, lk_ms_hit, issue, act;
  addr_t lk_addr;
  logic [7:0] lk_size;
  logic [1:0] lk_master;
  logic [3:0] lk_id;
  // lookup resolution
  logic rs_done, rs_retry, rs_enq_v, rs_vu_go, rs_cdone, rs_cpend, rs_forw, rs_alloc, rs_vdirty, rs_bad;
  line_t rs_enq_data, rs_vu_data, rs_vict_data;
  addr_t rs_vict_addr;
  logic [WB-1:0] rs_vu_way, rs_way;
  // read response units
  logic [NR-1:0][2:0] rq_v, rq_acc;
  logic [NR-1:0][2:0][3:0] rq_id;
  logic [NR-1:0][2:0][511:0] rq_data;
  logic [NR-1:0] rq_valid_d, rq_valid_cur;
  // write ports
  logic [NW-1:0] wp_free, wp_cand, wp_cpend_q, wp_cpend_s2, wp_cpend_d, wp_ctx_valid;
  logic [NW-1:0] acc_w, fill_blocked, launch_w;
  logic launch_any, bad_bypass;
  logic [$clog2(NW)-1:0] launch_idx;
  logic [NW-1:0][31:0] wp_head, wp_commit_addr, wp_vaddr, wp_vaddr_d, wp_ctx_line, wp_resp_line, wp_l_addr;
  logic [NW-1:0][WB-1:0] wp_commit_way;
  logic [NW-1:0][511:0] wp_commit_line, wp_ctx_data;
  logic [NW-1:0][63:0] wp_ctx_strb;
  logic [NW-1:0][7:0] wp_ctx_size, wp_l_size;
  logic [NW-1:0][3:0] wp_l_id;
  logic [NW-1:0][WAYS-1:0] wp_rsv;
  logic [NW-1:0][WQD:0] wp_wl_vld;
  logic [NW-1:0][WQD:0][31:0] wp_wl_line;
  // victim unit
  logic v_resp_forw, v_resp_wm, v_busy2, v_busy3, v_full2, v_bad_orphan, v_bad_owner;
  logic [VQD:0] v_vld_q, v_vld_d, v_pr_vld;
  logic [VQD:0][31:0] v_addr_q, v_addr_d, v_pr_addr;
  // MSHR table
  logic ms_free_q, ms_free_d, ms_resp_want, ms_resp_acc, ms_bad_resp, cs_v, e_bypass, e_rcomm, e_vdirty;
  logic [1:0] ms_resp_master, e_master;
  logic [3:0] ms_resp_eid, e_id;
  logic [MIDW-1:0] cs_idx;
  addr_t e_addr, e_vaddr;
  logic [WB-1:0] e_way;
  line_t e_rdata, e_vdata;
  logic [WAYS-1:0] ms_rsv;
  logic [NMSHR-1:0] ms_vh_cur, ms_vh_d, ml_vld_cur, ml_vld_d;
  logic [NMSHR-1:0][31:0] ms_vh_addr_q, ms_vh_addr_d, ml_line_cur, ml_line_d;
  logic [NR-1:0] ms_has_d;
  // refill engine
  logic rf_park, rf_rcomm, rf_free, rf_enq_v, rf_acc;
  line_t rf_enq_data;
  // read accept
  logic acc_r_any, acc_r_byp;
  logic [1:0] acc_r_master;
  addr_t acc_r_addr;
  logic [7:0] acc_r_size;
  logic [3:0] acc_r_id;
  // hazard lists
  logic [NVL-1:0] vl_vld_cur, vl_vld_d;
  logic [NVL-1:0][31:0] vl_addr_cur, vl_addr_d;
  logic [NW+NMSHR-1:0] fl_vld;
  logic [NW+NMSHR-1:0][31:0] fl_addr;
  logic [NW*(WQD+1)-1:0] wl_vld_d;
  logic [NW*(WQD+1)-1:0][31:0] wl_line_d;
  logic bad_any;

  // victim-holder lists: index 0 = write-back slot, then queue, write contexts, MSHR snapshots
  always_comb begin
    vl_vld_cur = {ms_vh_cur, wp_cpend_q, v_vld_q};
    vl_addr_cur = {ms_vh_addr_q, wp_vaddr, v_addr_q};
    vl_vld_d = {ms_vh_d, wp_cpend_d, v_vld_d};
    vl_addr_d = {ms_vh_addr_d, wp_vaddr_d, v_addr_d};
    fl_vld = {ms_vh_cur, wp_cpend_s2};
    fl_addr = {ms_vh_addr_q, wp_vaddr};
    for (int w = 0; w < NW; w++) begin
      for (int e = 0; e <= WQD; e++) begin
        wl_vld_d[w * (WQD + 1) + e] = wp_wl_vld[w][e];
        wl_line_d[w * (WQD + 1) + e] = wp_wl_line[w][e];
      end
    end
  end

  // ---------------- table write: stage 2 commit > stage 3 > stage 4 (mutually exclusive by the busy checks) -----
  always_comb begin
    tw_commit = '0;
    tw_commit.line_en = v_resp_forw;
    tw_commit.repl_en = v_resp_forw;
    tw_commit.set = set_of(wp_commit_addr[v_resp_wm]);
    tw_commit.way = wp_commit_way[v_resp_wm];
    tw_commit.data = wp_commit_line[v_resp_wm];
    tw_commit.tag = tag_of(wp_commit_addr[v_resp_wm]);
    tw_commit.dirty = 1'b1;
    tw_commit.repl = next_way(wp_commit_way[v_resp_wm]);
    busy2 = tw_commit.line_en;
    busy3 = busy2 || tw_lookup.line_en || tw_lookup.repl_en;
    if (busy2) tw = tw_commit;
    else if (busy3) tw = tw_lookup;
    else tw = tw_refill;
  end

  axi_llc_tables u_tables (
    .clk(clk), .rst_n(rst_n), .rd_req(issue), .rd_set(set_of(lk_addr)), .tw(tw),
    .lk_ok(t_ok), .lk_v(t_v), .lk_d(t_d), .lk_t(t_t), .lk_line(t_line), .lk_repl(t_repl)
  );

  // ---------------- lookup engine ----------------
  axi_llc_lookup u_lookup (
    .clk(clk), .rst_n(rst_n), .done(rs_done), .retry(rs_retry), .issue(issue),
    .w_launch(launch_any), .w_addr(wp_l_addr[launch_idx]), .w_size(wp_l_size[launch_idx]),
    .w_id(wp_l_id[launch_idx]), .w_master(2'(launch_idx)),
    .r_launch(acc_r_any), .r_addr(acc_r_addr), .r_size(acc_r_size), .r_id(acc_r_id), .r_master(acc_r_master),
    .r_bypass(acc_r_byp),
    .valid_q(lk_valid), .issued_q(lk_issued), .is_write_q(lk_is_write), .bypass_q(lk_bypass), .addr_q(lk_addr),
    .size_q(lk_size), .master_q(lk_master), .id_q(lk_id), .free_s3(lk_free)
  );

  assign act = lk_valid && lk_issued && t_ok;

  // ---------------- stage 3: lookup resolution ----------------
  logic [WAYS-1:0] reserved;
  logic acc_a;
  assign reserved = ms_rsv | wp_rsv[0] | wp_rsv[1];
  assign acc_a = rq_acc[lk_master][0];
  axi_llc_linecam #(.N(NMSHR)) u_lk_ms (.vld(ml_vld_cur), .addr(ml_line_cur), .line(line_of(lk_addr)), .hit(lk_ms_hit));

  axi_llc_resolve u_resolve (
    .act(act), .is_write(lk_is_write), .bypass(lk_bypass), .laddr(lk_addr),
    .lk_v(t_v), .lk_d(t_d), .lk_t(t_t), .lk_line(t_line), .lk_repl(t_repl),
    .wdata(wp_ctx_data[lk_master[0]]), .wstrb(wp_ctx_strb[lk_master[0]]), .wsize(wp_ctx_size[lk_master[0]]),
    .tbl_busy2(busy2), .vwb_busy2(v_busy2), .acc_a(acc_a), .mshr_free(ms_free_q), .mshr_line_hit(lk_ms_hit),
    .reserved(reserved),
    .done(rs_done), .retry(rs_retry), .tw(tw_lookup), .enq_v(rs_enq_v), .enq_data(rs_enq_data),
    .vu_go(rs_vu_go), .vu_way(rs_vu_way), .vu_data(rs_vu_data), .cdone_set(rs_cdone), .cpend_set(rs_cpend),
    .vict_addr(rs_vict_addr), .pick_way(rs_way), .vict_data(rs_vict_data), .forw_go(rs_forw), .alloc_go(rs_alloc),
    .alloc_vdirty(rs_vdirty), .bad_partial(rs_bad)
  );

  // ---------------- read response units: producers 0 lookup hit, 1 bypass memory response, 2 MSHR completion ----
  assign ms_resp_acc = rq_acc[ms_resp_master][1];
  assign rf_acc = rq_acc[e_master][2];
  always_comb begin
    for (int m = 0; m < NR; m++) begin
      rq_v[m] = {rf_enq_v && e_master == 2'(m), ms_resp_want && ms_resp_master == 2'(m),
                 rs_enq_v && lk_master == 2'(m)};
      rq_id[m] = {e_id, ms_resp_eid, lk_id};
      rq_data[m] = {rf_enq_data, mrr_data, rs_enq_data};
    end
  end

  for (genvar m = 0; m < NR; m++) begin : g_rq
    axi_llc_rq u_rq (
      .clk(clk), .rst_n(rst_n), .ready(rd_ready[m]), .enq_v(rq_v[m]), .enq_id(rq_id[m]), .enq_data(rq_data[m]),
      .enq_acc(rq_acc[m]), .valid_cur(rr_valid[m]), .fresh_q(hz_rr_fresh[m]), .id_cur(rr_id[m]), .data_cur(rr_data[m]),
      .valid_d(rq_valid_d[m])
    );
  end
  assign rq_valid_cur = rr_valid;

  // ---------------- stage 2: victim write-back slot and the write path ----------------
  logic [NW-1:0] commit_w, s3_cdone_w, s3_cpend_w;
  always_comb begin
    for (int w = 0; w < NW; w++) begin
      commit_w[w] = v_resp_forw && v_resp_wm == 1'(w);
      s3_cdone_w[w] = rs_cdone && lk_master[0] == 1'(w);
      s3_cpend_w[w] = rs_cpend && lk_master[0] == 1'(w);
    end
  end

  axi_llc_victim u_victim (
    .clk(clk), .rst_n(rst_n), .mwr_resp_v(mwr_resp_v), .mwr_ready(mwr_ready),
    .forw_go(rs_forw), .forw_wm(lk_master[0]), .forw_addr(rs_vict_addr), .forw_data(rs_vict_data),
    .park_go(rf_park), .park_own(cs_idx), .park_addr(e_vaddr), .park_data(e_vdata),
    .own_clr(rf_free), .own_clr_id(cs_idx),
    .mwr_v(mwr_v), .mwr_addr(mwr_addr), .mwr_data(mwr_data), .resp_forw(v_resp_forw), .resp_wm(v_resp_wm),
    .busy_s2(v_busy2), .busy_s3(v_busy3), .rvq_full_s2(v_full2),
    .vl_vld_cur(v_vld_q), .vl_addr_cur(v_addr_q), .vl_vld_d(v_vld_d), .vl_addr_d(v_addr_d),
    .pr_vld_s2(v_pr_vld), .pr_addr_s2(v_pr_addr), .bad_orphan(v_bad_orphan), .bad_owner(v_bad_owner)
  );

  for (genvar w = 0; w < NW; w++) begin : g_wp
    axi_llc_wport u_wp (
      .clk(clk), .rst_n(rst_n), .resp_ready(wr_ready[w]),
      .enq(acc_w[w]), .enq_id(wr_id[w]), .enq_size(wr_size[w]), .enq_addr(wr_addr[w]), .enq_data(wr_data[w]),
      .enq_strb(wr_strb[w]), .wq_free(wp_free[w]),
      .fill_en(!v_busy2), .fill_blocked(fill_blocked[w]), .head_addr(wp_head[w]),
      .commit(commit_w[w]), .commit_addr(wp_commit_addr[w]), .commit_way(wp_commit_way[w]),
      .commit_line(wp_commit_line[w]),
      .launch(launch_w[w]), .launch_cand(wp_cand[w]), .launch_addr(wp_l_addr[w]), .launch_size(wp_l_size[w]),
      .launch_id(wp_l_id[w]),
      .s3_cdone(s3_cdone_w[w]), .s3_cpend(s3_cpend_w[w]), .s3_vaddr(rs_vict_addr), .s3_way(rs_way),
      .s3_line(wp_ctx_data[w]), .ctx_data(wp_ctx_data[w]), .ctx_strb(wp_ctx_strb[w]), .ctx_size(wp_ctx_size[w]),
      .rsv_set(set_of(lk_addr)), .rsv_line(line_of(lk_addr)), .rsv_mask(wp_rsv[w]),
      .cpend_q(wp_cpend_q[w]), .cpend_s2(wp_cpend_s2[w]), .cpend_d(wp_cpend_d[w]),
      .vaddr_cur(wp_vaddr[w]), .vaddr_d(wp_vaddr_d[w]),
      .ctx_line(wp_ctx_line[w]), .wl_vld_d(wp_wl_vld[w]), .wl_line_d(wp_wl_line[w]),
      .ctx_valid_q(wp_ctx_valid[w]), .resp_valid_q(wr_resp_valid[w]), .resp_id_q(wr_resp_id[w]),
      .resp_line_q(wp_resp_line[w])
    );
  end

  axi_llc_wsched u_wsched (
    .clk(clk), .rst_n(rst_n), .wr_v(wr_v), .wr_byp(wr_byp), .wr_addr(wr_addr), .wq_free(wp_free),
    .path_en(!v_busy2), .vl_vld_cur(vl_vld_cur), .vl_addr_cur(vl_addr_cur), .head_addr(wp_head), .fl_vld(fl_vld),
    .fl_addr(fl_addr), .launch_cand(wp_cand), .lookup_free(lk_free), .acc_grant(acc_w),
    .fill_blocked(fill_blocked), .launch_grant(launch_w), .launch_any(launch_any), .launch_idx(launch_idx),
    .bad_bypass(bad_bypass)
  );
  assign wr_rdy = acc_w;

  // ---------------- stage 4: memory read path ----------------
  axi_llc_mshr u_mshr (
    .clk(clk), .rst_n(rst_n),
    .alloc_go(rs_alloc), .a_bypass(lk_bypass), .a_addr(lk_addr), .a_way(rs_way), .a_size(lk_size),
    .a_master(lk_master), .a_id(lk_id), .a_vdirty(rs_vdirty), .a_vaddr(rs_vict_addr), .a_vdata(rs_vict_data),
    .free_any_cur(ms_free_q),
    .lk_set(set_of(lk_addr)), .lk_line(line_of(lk_addr)), .vu_go(rs_vu_go), .vu_way(rs_vu_way),
    .vu_data(rs_vu_data), .rsv_mask(ms_rsv),
    .mrr_v(mrr_v), .mrr_id(mrr_id), .mrr_data(mrr_data), .resp_acc(ms_resp_acc), .resp_want(ms_resp_want),
    .resp_master(ms_resp_master), .resp_eid(ms_resp_eid), .bad_resp(ms_bad_resp),
    .mrd_ready(mrd_ready), .mrd_v(mrd_v), .mrd_addr(mrd_addr), .mrd_size(mrd_size), .mrd_id(mrd_id),
    .rcomm_go(rf_rcomm), .free_go(rf_free), .cs_v(cs_v), .cs_idx(cs_idx), .e_bypass(e_bypass), .e_rcomm(e_rcomm),
    .e_addr(e_addr), .e_way(e_way), .e_master(e_master), .e_id(e_id), .e_rdata(e_rdata), .e_vdirty(e_vdirty),
    .e_vaddr(e_vaddr), .e_vdata(e_vdata),
    .vh_cur(ms_vh_cur), .vh_addr_cur(ms_vh_addr_q), .vh_d(ms_vh_d), .vh_addr_d(ms_vh_addr_d),
    .ml_vld_cur(ml_vld_cur), .ml_line_cur(ml_line_cur), .ml_vld_d(ml_vld_d), .ml_line_d(ml_line_d),
    .free_any_d(ms_free_d), .has_master_d(ms_has_d),
    .hz_valid(hz_ms_valid), .hz_master(hz_ms_master), .hz_id(hz_ms_id), .hz_line(hz_ms_line)
  );

  axi_llc_refill u_refill (
    .cs_v(cs_v), .e_bypass(e_bypass), .e_rcomm(e_rcomm), .e_addr(e_addr), .e_way(e_way), .e_rdata(e_rdata),
    .e_vdirty(e_vdirty), .e_vaddr(e_vaddr), .tbl_busy3(busy3), .vwb_busy3(v_busy3), .rvq_full_s2(v_full2),
    .pr_vld(v_pr_vld), .pr_addr(v_pr_addr),
    .lk_active_w(lk_valid && lk_is_write && lk_issued && !lk_bypass), .lk_line(line_of(lk_addr)),
    .wc_cpend(wp_cpend_q), .wc_line(wp_ctx_line), .acc_c(rf_acc),
    .park_go(rf_park), .rcomm_go(rf_rcomm), .free_go(rf_free), .tw(tw_refill), .enq_v(rf_enq_v),
    .enq_data(rf_enq_data)
  );

  // ---------------- stage 5: read accept and table read issue ----------------
  axi_llc_rdacc u_rdacc (
    .clk(clk), .rst_n(rst_n), .rd_v(rd_v), .rd_byp(rd_byp), .rd_addr(rd_addr), .rd_size(rd_size), .rd_id(rd_id),
    .wr_v(wr_v), .wr_byp(wr_byp), .wr_addr(wr_addr), .slot_q(rq_valid_cur), .slot_d(rq_valid_d),
    .lookup_free(lk_free && !launch_any), .vl_vld_d(vl_vld_d), .vl_addr_d(vl_addr_d), .wl_vld_d(wl_vld_d),
    .wl_line_d(wl_line_d), .ml_vld_d(ml_vld_d), .ml_line_d(ml_line_d), .has_master_d(ms_has_d),
    .free_any_d(ms_free_d), .lk_valid_q(lk_valid), .lk_issued_q(lk_issued), .lk_addr_q(lk_addr),
    .tbl_busy(busy3 || tw_refill.line_en), .issue(issue), .acc_grant(rd_rdy), .acc_master(acc_r_master),
    .acc_any(acc_r_any), .acc_addr(acc_r_addr), .acc_size(acc_r_size), .acc_id(acc_r_id), .acc_bypass(acc_r_byp)
  );

  // ---------------- registers read by the interconnect ----------------
  always_comb begin
    hz_lk_valid = lk_valid;
    hz_lk_is_write = lk_is_write;
    hz_lk_addr = lk_addr;
    hz_lk_master = lk_master;
    hz_lk_id = lk_id;
    hz_wc_valid = wp_ctx_valid;
    hz_wc_line = wp_ctx_line;
    hz_wr_line = wp_resp_line;
  end

  assign bad_any = v_bad_orphan || v_bad_owner || ms_bad_resp || bad_bypass || rs_bad;

`ifndef SYNTHESIS
  // C++ paths the coverage analysis showed unreachable (docs/modules/axi_llc.md section 2)
  assert property (@(posedge clk) disable iff (!rst_n) !bad_any)
    else $error("axi_llc: unreachable path taken");
  // the table-write sources are mutually exclusive by construction
  assert property (@(posedge clk) disable iff (!rst_n) !(tw_commit.line_en && (tw_lookup.line_en || tw_lookup.repl_en)))
    else $error("axi_llc: two table writes in one tick");
`endif
  // elaboration-time geometry checks
  if ((WAYS & (WAYS - 1)) != 0 || NMSHR != 8) begin : g_geometry
    $error("axi_llc: WAYS must be a power of two and NMSHR must be 8");
  end
endmodule

`default_nettype wire
