`default_nettype none
// Ref: MemSubSystem/RealDcache.cpp RealDcache; MSHR.cpp MSHR; WriteBuffer.cpp WriteBuffer; MemSubsystem.cpp
// DCache domain top: port adaptation and wiring only (docs/modules/dcache.md).  One clock edge per fast tick;
// `cpu_phase0` marks tick 0 of the CPU cycle (LSU requests are only presented, and the response only published,
// on that tick).
module dcache
  import dcache_pkg::*;
#(
  parameter bit PF_EN = 1'b1                   // L1D data prefetcher h1 (EXP-009); 0: no new state is used
)
(
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 cpu_phase0,
  // routed LSU request
  input  logic                 ld_req_valid  [NLD],
  input  logic [31:0]          ld_req_addr   [NLD],
  input  logic [31:0]          ld_req_id     [NLD],
  input  logic                 ld_req_replay [NLD],
  input  logic                 st_req_valid  [NST],
  input  logic [31:0]          st_req_addr   [NST],
  input  logic [31:0]          st_req_data   [NST],
  input  logic [3:0]           st_req_strb   [NST],
  input  logic [31:0]          st_req_id     [NST],
  input  logic [2:0]           icache_req,
  // AXI inputs
  input  logic                 mshr_req_accepted,
  input  logic [7:0]           mshr_req_accepted_id,
  input  logic                 mshr_resp_valid,
  input  logic [7:0]           mshr_resp_id,
  input  logic [31:0]          mshr_resp_data [WORDS],
  input  logic                 wb_req_accepted,
  input  logic                 wb_resp_valid,
  // published response
  output logic                 ld_resp_valid  [NLD],
  output logic [31:0]          ld_resp_data   [NLD],
  output logic [31:0]          ld_resp_id     [NLD],
  output logic                 ld_resp_retry  [NLD],
  output logic [1:0]           ld_resp_replay [NLD],
  output logic                 st_resp_valid  [NST],
  output logic [1:0]           st_resp_replay [NST],
  output logic [31:0]          st_resp_id     [NST],
  output logic                 mshr_fill,
  output logic [31:0]          mshr_fill_addr,
  // AXI outputs
  output logic                 mshr_req_valid,
  output logic [31:0]          mshr_req_addr,
  output logic [MSHR_IDW-1:0]  mshr_req_id,
  output logic                 mshr_resp_ready,
  output logic                 wb_req_valid,
  output logic [31:0]          wb_req_addr,
  output logic [31:0]          wb_req_data    [WORDS]
);

  // boundary 1-bit arrays <-> packed vectors
  logic [NLD-1:0] ld_req_v, pub_ld_valid, pub_ld_retry;
  logic [NST-1:0] st_req_v, pub_st_valid;
  for (genvar i = 0; i < NLD; i++) begin : g_bnd_ld
    assign ld_req_v[i]       = ld_req_valid[i];
    assign ld_resp_valid[i]  = pub_ld_valid[i];
    assign ld_resp_retry[i]  = pub_ld_retry[i];
  end
  for (genvar i = 0; i < NST; i++) begin : g_bnd_st
    assign st_req_v[i]       = st_req_valid[i];
    assign st_resp_valid[i]  = pub_st_valid[i];
  end

  // ------------------------------------------------------------ stage-1 registers
  logic [NSLOT-1:0]     slot_valid, slot_replayed, slot_granted, retry_issue, pend_valid;
  logic [31:0]          slot_addr [NSLOT], slot_id [NSLOT], slot_data [NST];
  logic [3:0]           slot_strb [NST];
  logic [2:0]           icache_req_s2;
  logic                 s2f_valid, s2f_dirty, s2f_pf, same_fill;
  logic [NLD-1:0]       slot_pf, slot_pf_llc, slot_perf_replay, slot_lsu;
  // verilator lint_off UNUSEDSIGNAL
  logic                 pf_head_valid, pf_head_llc, pf_taken, fr_pf, rel_event;   // unused with PF_EN = 0
  // verilator lint_on UNUSEDSIGNAL
  logic [LINE_W-1:0]    pf_head_line;
  logic [MSHR_IDW-1:0]  s2f_id;
  logic [LINE_W-1:0]    s2f_line;
  logic [LINE_BITS-1:0] s2f_data;
  assign slot_granted = slot_valid & ~slot_replayed;

  // per-slot views
  logic [LINE_W-1:0]    slot_line [NSLOT];
  logic [SET_W-1:0]     st_set    [NST];
  logic [WORD_W-1:0]    st_word   [NST], ld_word [NLD];
  logic [LINE_W-1:0]    ld_line   [NLD], st_line [NST];
  logic [31:0]          ld_addr   [NLD], st_addr [NST];
  for (genvar i = 0; i < NLD; i++) begin : g_ldv
    assign slot_line[i] = slot_addr[i][31:OFF_W];
    assign ld_line[i]   = slot_addr[i][31:OFF_W];
    assign ld_word[i]   = slot_addr[i][2 +: WORD_W];
    assign ld_addr[i]   = slot_addr[i];
  end
  for (genvar i = 0; i < NST; i++) begin : g_stv
    assign slot_line[NLD+i] = slot_addr[NLD+i][31:OFF_W];
    assign st_line[i]       = slot_addr[NLD+i][31:OFF_W];
    assign st_set[i]        = slot_addr[NLD+i][OFF_W +: SET_W];
    assign st_word[i]       = slot_addr[NLD+i][2 +: WORD_W];
    assign st_addr[i]       = slot_addr[NLD+i];
  end

  // ------------------------------------------------------------ MSHR / WB / fill request
  logic [CNT_W-1:0]     mshr_free, wb_free;
  logic [NSLOT-1:0]     mshr_find_hit;
  logic                 fr_valid, fr_dirty, frf_dirty;
  logic [MSHR_IDW-1:0]  fr_id;
  logic [LINE_W-1:0]    fr_line;
  logic [LINE_BITS-1:0] fr_data, frf_data;
  logic [NLD-1:0]       byp_hit;
  logic [31:0]          byp_data [NLD];
  logic [NST-1:0]       wb_mrg_ok, wb_mrg_busy;

  // ------------------------------------------------------------ arrays
  logic [WAYS-1:0]      rd_valid [NSLOT];
  logic [WAYS-1:0]      rd_pf    [NSLOT];
  logic [WAYS-1:0]      ld_rd_pf [NLD];
  logic [TAG_W-1:0]     rd_tag   [NSLOT][WAYS];
  logic [31:0]          rd_data  [NSLOT][WAYS];
  logic [WAYS-1:0]      fs_valid, fs_dirty;
  logic [2:0]           fs_plru;
  logic [TAG_W-1:0]     fs_tag   [WAYS];
  logic [LINE_BITS-1:0] fs_line  [WAYS];
  logic [WAYS-1:0]      ld_rd_valid [NLD], st_rd_valid [NST];
  logic [TAG_W-1:0]     ld_rd_tag   [NLD][WAYS], st_rd_tag [NST][WAYS];
  logic [31:0]          ld_rd_data  [NLD][WAYS];
  for (genvar i = 0; i < NLD; i++) begin : g_rdl
    assign ld_rd_valid[i] = rd_valid[i];
    assign ld_rd_pf[i]    = rd_pf[i];
    assign slot_lsu[i]    = !slot_id[i][31];
    assign ld_rd_tag[i]   = rd_tag[i];
    assign ld_rd_data[i]  = rd_data[i];
  end
  for (genvar i = 0; i < NST; i++) begin : g_rds
    assign st_rd_valid[i] = rd_valid[NLD+i];
    assign st_rd_tag[i]   = rd_tag[NLD+i];
  end

  // ------------------------------------------------------------ stage 2
  logic [NLD-1:0]       ld_mreq, ld_lu, s2ld_valid, s2ld_retry;
  logic [31:0]          s2ld_data [NLD];
  logic [1:0]           s2ld_replay [NLD], ld_lu_way [NLD];
  logic [CNT_W-1:0]     ld_alloc_cnt, st_alloc_cnt, pf_free;
  // verilator lint_off UNUSEDSIGNAL
  logic [NLD-1:0]       pf_cand, pf_ok, acc_valid, acc_miss, acc_pf_hit, pfc_en;   // training events: PF_EN only
  logic [LINE_W-1:0]    acc_line [NLD];
  // verilator lint_on UNUSEDSIGNAL
  logic [NLD-1:0]       ld_byp_and_hit;
  logic [NST-1:0]       st_mreq, st_pw, st_lu, st_mrg, s2st_valid;
  logic [1:0]           s2st_replay [NST], st_pw_way [NST];
  logic                 fill_valid, fill_dirty, fill_done, evict_valid;
  logic [1:0]           fill_way_tgt;
  logic [LINE_BITS-1:0] fill_data, evict_data;
  logic [MSHR_IDW-1:0]  fill_done_id;
  logic [LINE_W-1:0]    evict_line;
  logic [1:0]           lu_way_w [NSLOT];
  for (genvar i = 0; i < NLD; i++) begin : g_lw
    assign lu_way_w[i] = ld_lu_way[i];
  end
  for (genvar i = 0; i < NST; i++) begin : g_sw
    assign lu_way_w[NLD+i] = st_pw_way[i];
  end

  dcache_s1 u_s1 (
    .clk(clk), .rst_n(rst_n),
    .ld_req_valid(ld_req_v), .ld_req_addr(ld_req_addr), .ld_req_id(ld_req_id),
    .st_req_valid(st_req_v), .st_req_addr(st_req_addr), .st_req_data(st_req_data),
    .st_req_strb(st_req_strb), .st_req_id(st_req_id), .icache_req(icache_req),
    .ld_req_replay(ld_req_replay),
    .pf_head_valid(pf_head_valid), .pf_head_line(pf_head_line), .pf_head_llc(pf_head_llc), .pf_taken(pf_taken),
    .slot_pf(slot_pf), .slot_pf_llc(slot_pf_llc), .slot_perf_replay(slot_perf_replay),
    .fr_pf(fr_pf), .s2f_pf(s2f_pf),
    .blocked(pend_valid),
    .fr_valid(fr_valid), .fr_line(fr_line), .fr_id(fr_id), .fr_dirty(frf_dirty), .fr_data(frf_data),
    .s2_fill_valid(fill_valid),
    .mrg_en(st_mrg), .mrg_data(slot_data), .mrg_strb(slot_strb), .mrg_word(st_word),
    .slot_valid(slot_valid), .slot_replayed(slot_replayed), .slot_addr(slot_addr), .slot_id(slot_id),
    .slot_data(slot_data), .slot_strb(slot_strb), .icache_req_s2(icache_req_s2), .retry_issue(retry_issue),
    .s2f_valid(s2f_valid), .s2f_id(s2f_id), .s2f_dirty(s2f_dirty), .s2f_line(s2f_line), .s2f_data(s2f_data),
    .same_fill(same_fill)
  );

  dcache_arr u_arr (
    .clk(clk), .rst_n(rst_n),
    .rd_en(slot_granted), .rd_addr(slot_addr), .rd_valid(rd_valid), .rd_pf(rd_pf),
    .pfc_en(pfc_en), .pfc_way(ld_lu_way), .fw_pf(s2f_pf), .rd_tag(rd_tag), .rd_data(rd_data),
    .fs_en(s2f_valid), .fs_set(s2f_line[SET_W-1:0]), .fs_valid(fs_valid), .fs_dirty(fs_dirty), .fs_plru(fs_plru),
    .fs_tag(fs_tag), .fs_line(fs_line),
    .sw_en(st_pw), .sw_set(st_set), .sw_way(st_pw_way), .sw_word(st_word), .sw_data(slot_data), .sw_strb(slot_strb),
    .lu_en({st_lu, ld_lu}), .lu_way(lu_way_w),
    .fw_en(fill_valid), .fw_set(s2f_line[SET_W-1:0]), .fw_way(fill_way_tgt), .fw_tag(s2f_line[LINE_W-1:SET_W]),
    .fw_dirty(fill_dirty), .fw_data(fill_data)
  );

  dcache_s2_ld u_ld (
    .slot_pf(slot_pf), .slot_perf_replay(slot_perf_replay), .slot_lsu(slot_lsu), .rd_pf(ld_rd_pf),
    .s2f_valid(s2f_valid), .s2f_line(s2f_line), .fr_valid(fr_valid), .fr_line(fr_line),
    .pf_cand(pf_cand), .acc_valid(acc_valid), .acc_line(acc_line), .acc_miss(acc_miss), .acc_pf_hit(acc_pf_hit),
    .pfc_en(pfc_en),
    .slot_valid(slot_valid[NLD-1:0]), .slot_replayed(slot_replayed[NLD-1:0]), .slot_addr(ld_addr),
    .retry_issue(retry_issue[NLD-1:0]), .icache_req_s2(icache_req_s2),
    .rd_valid(ld_rd_valid), .rd_tag(ld_rd_tag), .rd_data(ld_rd_data),
    .byp_valid(byp_hit), .byp_data(byp_data), .find_hit(mshr_find_hit[NLD-1:0]), .free_in(mshr_free),
    .resp_valid(s2ld_valid), .resp_data(s2ld_data), .resp_retry(s2ld_retry), .resp_replay(s2ld_replay),
    .mreq_en(ld_mreq), .lu_en(ld_lu), .lu_way(ld_lu_way), .alloc_cnt(ld_alloc_cnt), .byp_and_hit(ld_byp_and_hit)
  );

  dcache_s2_st u_st (
    .slot_valid(slot_valid[NSLOT-1:NLD]), .slot_replayed(slot_replayed[NSLOT-1:NLD]), .slot_addr(st_addr),
    .retry_issue(retry_issue[NSLOT-1:NLD]),
    .rd_valid(st_rd_valid), .rd_tag(st_rd_tag), .wb_mrg_ok(wb_mrg_ok), .wb_mrg_busy(wb_mrg_busy),
    .find_hit(mshr_find_hit[NSLOT-1:NLD]), .free_rem(mshr_free - ld_alloc_cnt),
    .fr_valid(fr_valid), .fr_line(fr_line),
    .resp_valid(s2st_valid), .resp_replay(s2st_replay), .mreq_en(st_mreq), .pw_en(st_pw), .pw_way(st_pw_way),
    .lu_en(st_lu), .mrg_en(st_mrg), .alloc_cnt(st_alloc_cnt)
  );

  dcache_s2_fill u_fill (
    .s2f_valid(s2f_valid), .s2f_id(s2f_id), .s2f_dirty(s2f_dirty), .s2f_line(s2f_line), .s2f_data(s2f_data),
    .fs_valid(fs_valid), .fs_dirty(fs_dirty), .fs_tag(fs_tag), .fs_line(fs_line), .fs_plru(fs_plru),
    .wb_has_room(wb_free != '0),
    .fill_valid(fill_valid), .fill_way_tgt(fill_way_tgt), .fill_dirty(fill_dirty),
    .fill_data(fill_data), .fill_done(fill_done), .fill_done_id(fill_done_id),
    .evict_valid(evict_valid), .evict_line(evict_line), .evict_data(evict_data)
  );

  // ------------------------------------------------------------ prefetcher
  // probe allocation: lowest priority, MSHR entries left after the demand loads and stores (reserve 0)
  assign pf_free = mshr_free - ld_alloc_cnt - st_alloc_cnt;
  assign pf_ok   = pf_cand & {NLD{pf_free != '0}};
  if (PF_EN) begin : g_pf
    dcache_pf u_pf (
      .clk(clk), .rst_n(rst_n),
      .head_valid(pf_head_valid), .head_line(pf_head_line), .head_llc(pf_head_llc), .head_taken(pf_taken),
      .acc_valid(acc_valid), .acc_line(acc_line), .acc_miss(acc_miss), .acc_pf_hit(acc_pf_hit)
    );
  end else begin : g_nopf
    assign pf_head_valid = 1'b0;
    assign pf_head_line  = '0;
    assign pf_head_llc   = 1'b0;
  end

  // ------------------------------------------------------------ MSHR
  logic [LINE_BITS-1:0] mshr_resp_line;
  logic [LINE_W-1:0]    mshr_ax_line;
  for (genvar w = 0; w < WORDS; w++) begin : g_rsp
    assign mshr_resp_line[32*w +: 32] = mshr_resp_data[w];
  end
  dcache_mshr u_mshr (
    .clk(clk), .rst_n(rst_n),
    .ax_req_accepted(mshr_req_accepted), .ax_req_accepted_id(mshr_req_accepted_id),
    .ax_resp_valid(mshr_resp_valid), .ax_resp_id(mshr_resp_id), .ax_resp_data(mshr_resp_line),
    .find_en(slot_granted), .find_pf({{NST{1'b0}}, slot_pf}), .find_line(slot_line),
    .req_valid({st_mreq, ld_mreq | pf_ok}), .req_pf({{NST{1'b0}}, slot_pf}),
    .req_nofill({{NST{1'b0}}, slot_pf_llc & slot_pf}),
    .release_event(rel_event), .fr_pf(fr_pf), .req_line(slot_line),
    .req_word(st_word), .req_data(slot_data), .req_strb(slot_strb),
    .fill_done(fill_done), .fill_id(fill_done_id),
    .free(mshr_free), .find_hit(mshr_find_hit),
    .fr_valid(fr_valid), .fr_id(fr_id), .fr_line(fr_line), .fr_dirty(fr_dirty), .fr_data(fr_data),
    .ax_req_valid(mshr_req_valid), .ax_req_line(mshr_ax_line), .ax_req_id(mshr_req_id),
    .ax_resp_ready(mshr_resp_ready)
  );
  assign mshr_req_addr = {mshr_ax_line, {OFF_W{1'b0}}};

  // ------------------------------------------------------------ WriteBuffer
  logic [LINE_W-1:0]    wb_ax_line;
  logic [LINE_BITS-1:0] wb_ax_data;
  dcache_wb u_wb (
    .clk(clk), .rst_n(rst_n),
    .ax_req_accepted(wb_req_accepted), .ax_resp_valid(wb_resp_valid),
    .byp_en(slot_granted[NLD-1:0]), .byp_line(ld_line), .byp_word(ld_word),
    .mrg_en(slot_granted[NSLOT-1:NLD]), .mrg_line(st_line), .mrg_word(st_word), .mrg_data(slot_data),
    .mrg_strb(slot_strb),
    .push_valid(evict_valid), .push_line(evict_line), .push_data(evict_data),
    .free(wb_free), .byp_hit(byp_hit), .byp_data(byp_data), .mrg_ok(wb_mrg_ok), .mrg_busy(wb_mrg_busy),
    .ax_req_valid(wb_req_valid), .ax_req_line(wb_ax_line), .ax_req_data(wb_ax_data)
  );
  assign wb_req_addr = {wb_ax_line, {OFF_W{1'b0}}};
  for (genvar w = 0; w < WORDS; w++) begin : g_wbd
    assign wb_req_data[w] = wb_ax_data[32*w +: 32];
  end

  // ------------------------------------------------------------ response latch / forward / publish
  logic [31:0] ld_id_w [NLD], st_id_w [NST];
  for (genvar i = 0; i < NLD; i++) begin : g_ldid
    assign ld_id_w[i] = slot_id[i];
  end
  for (genvar i = 0; i < NST; i++) begin : g_stid
    assign st_id_w[i] = slot_id[NLD+i];
  end

  logic [LINE_W-1:0] pub_fill_line;
  dcache_resp u_resp (
    .clk(clk), .rst_n(rst_n), .phase0(cpu_phase0),
    .ld_valid(s2ld_valid), .ld_data(s2ld_data), .ld_id(ld_id_w), .ld_retry(s2ld_retry), .ld_replay(s2ld_replay),
    .st_valid(s2st_valid), .st_replay(s2st_replay), .st_id(st_id_w),
    .fill_valid(fill_valid), .rel_event(rel_event), .fill_line(s2f_line),
    .slot_addr(slot_addr), .slot_data(slot_data), .slot_strb(slot_strb),
    .fr_valid(fr_valid), .fr_line(fr_line), .fr_dirty(fr_dirty), .fr_data(fr_data),
    .frf_dirty(frf_dirty), .frf_data(frf_data), .pend_valid(pend_valid),
    .pub_ld_valid(pub_ld_valid), .pub_ld_data(ld_resp_data), .pub_ld_id(ld_resp_id),
    .pub_ld_retry(pub_ld_retry), .pub_ld_replay(ld_resp_replay),
    .pub_st_valid(pub_st_valid), .pub_st_replay(st_resp_replay), .pub_st_id(st_resp_id),
    .pub_fill(mshr_fill), .pub_fill_line(pub_fill_line)
  );
  assign mshr_fill_addr = {pub_fill_line, {OFF_W{1'b0}}};

`ifndef SYNTHESIS
  dcache_cover u_cover (
    .clk(clk), .rst_n(rst_n), .phase0(cpu_phase0), .mshr_free(mshr_free), .wb_free(wb_free),
    .slot_valid(slot_valid), .slot_replayed(slot_replayed), .slot_addr(slot_addr), .retry_issue(retry_issue),
    .pend_valid(pend_valid), .s2f_valid(s2f_valid), .same_fill(same_fill), .fill_valid(fill_valid),
    .evict_valid(evict_valid),
    .byp_hit(byp_hit), .wb_mrg_ok(wb_mrg_ok), .wb_mrg_busy(wb_mrg_busy), .mshr_find_hit(mshr_find_hit),
    .ld_mreq(ld_mreq), .st_mreq(st_mreq), .st_mrg(st_mrg),
    .s2ld_valid(s2ld_valid), .s2ld_replay(s2ld_replay), .s2st_valid(s2st_valid), .s2st_replay(s2st_replay),
    .ld_lu(ld_lu), .ld_byp_and_hit(ld_byp_and_hit), .st_pw(st_pw), .mshr_req_valid(mshr_req_valid),
    .mshr_resp_valid(mshr_resp_valid),
    .wb_req_valid(wb_req_valid), .wb_resp_valid(wb_resp_valid), .fr_valid(fr_valid)
  );
`endif

endmodule
`default_nettype wire
