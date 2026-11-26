// Ref: front-end/icache/icache_top.cpp  ICacheTop (comb/seq, 4-bank fetch_second, 2-port ITLB peek, 2-slot FDIP)
`default_nettype none

// Front-end instruction cache with 2-port read-only peek ITLB, 4-bank 1R1W arrays (parallel Block B read), and
// S2-confirmed 2-slot real-AXI FDIP (txids 8..9 on MASTER_ICACHE).
module icache import ttg_cfg_pkg::*; import icache_pkg::*; import tlb_mmu_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  input  logic refetch,
  input  logic itlb_flush,
  input  logic fence_i,
  input  logic invalidate,
  input  logic req_valid,
  input  logic [XLEN_BITS-1:0] fetch_address,
  // Paired Block B parallel lookup (driven by front_fetch_buf from matching FetchPair on read_complete)
  input  logic                 b_req_valid,
  input  logic [XLEN_BITS-1:0] b_req_addr,
  input  logic [3:0]           b_req_nwords,
  // Next-cycle VIPT set indices for strict 1-cycle synchronous L1I Data SRAM pre-launch
  input  logic [IC_IDX_W-1:0]  next_fa_idx,
  input  logic [IC_IDX_W-1:0]  next_b_idx,
  // S2-confirmed FDIP enqueue (driven by front_pred_path)
  input  logic                 fdip_s2_en,
  input  logic [XLEN_BITS-1:0] fdip_s2_va,
  input  logic                 fdip_s2_clear,
  input  logic [XLEN_BITS-1:0] csr_status_satp,
  input  logic [1:0]  csr_status_privilege,
  input  logic csr_status_mstatus_mxr,
  input  logic csr_status_mstatus_sum,
  input  logic csr_status_mstatus_mprv,
  input  logic [1:0]  csr_status_mstatus_mpp,
  input  logic mem_req_ready,
  input  logic mem_req_accepted,
  input  logic [3:0]  mem_req_accepted_id,
  input  logic mem_resp_valid,
  input  logic [3:0]  mem_resp_id,
  input  logic [31:0] mem_resp_data [ICACHE_WORD_NUM],
  input  logic dc_resp_valid,
  input  logic dc_resp_retry,
  input  logic dc_resp_miss,
  input  logic [31:0] dc_resp_data,
  input  logic ptw_walk_req_ready,
  input  logic ptw_walk_resp_valid,
  input  logic ptw_walk_resp_fault,
  input  logic [VPN_W-1:0] ptw_walk_resp_vpn,
  input  logic [PPN_W-1:0] ptw_walk_resp_leaf_ppn,
  input  logic [PERM_W-1:0] ptw_walk_resp_leaf_perm,
  input  logic [LVL_W-1:0] ptw_walk_resp_leaf_level,
  output logic icache_ready,
  output logic read_complete,
  output logic [XLEN_BITS-1:0] fetch_pc,
  output logic [FETCH_WIDTH-1:0] inst_valid,
  output logic [FETCH_WIDTH-1:0] page_fault_inst,
  output logic [31:0] fetch_group [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0] fetch_upper_ok,
  output logic        fetch_single_word,
  // Paired Block B response
  output logic        b_hit,
  output logic [4:0]  b_actual_n,
  output logic [31:0] b_fetch_group [FETCH_WIDTH],
  output logic mem_req_valid,
  output logic [31:0] mem_req_addr,
  output logic [7:0]  mem_req_total_size,
  output logic mem_req_bypass,
  output logic [3:0]  mem_req_id,
  output logic mem_resp_ready,
  output logic dc_req_valid,
  output logic [31:0] dc_req_addr,
  output logic ptw_walk_req_valid,
  output logic [VPN_W-1:0] ptw_walk_req_vpn,
  output logic [21:0] ptw_walk_req_root_ppn,
  output logic ptw_walk_resp_consumed,
  output logic ptw_walk_flush
);

  // 16 words -> one packed line
  logic [IC_LINE_W-1:0] mem_resp_line;
  for (genvar w = 0; w < IC_WORDS; w++) begin : g_pack
    assign mem_resp_line[IC_WORD_W * w +: IC_WORD_W] = mem_resp_data[w];
  end

  // ---- control FSM (demand side) ----
  logic arr_rd_en, arr_next_req_valid, arr_cmp_valid, arr_hit, arr_has_invalid, tw_we, inv_all, mmu_req_valid;
  logic [IC_IDX_W-1:0] arr_rd_index, arr_next_rd_index, tw_index;
  logic [IC_WAY_W-1:0] arr_first_invalid, arr_repl_way, tw_way;
  logic [IC_TAG_W-1:0] tw_tag, resp_ppn;
  logic [IC_LINE_W-1:0] arr_hit_line, tw_line, resp_line;
  logic [XLEN_BITS-13:0] mmu_req_vtag;
  logic ppn_valid, page_fault;
  logic [IC_TAG_W-1:0] ppn;
  logic resp_valid, resp_page_fault, resp_single_word;
  logic [XLEN_BITS-1:0] resp_pc;
  logic demand_mem_req_step0, demand_dc_busy, demand_miss_txv;
  logic [25:0] demand_miss_line;
  logic ctl_mem_req_valid, ctl_mem_req_bypass, ctl_mem_resp_ready, ctl_dc_req_valid;
  logic [31:0] ctl_mem_req_addr, ctl_dc_req_addr;
  logic [7:0]  ctl_mem_req_total_size;
  logic [3:0]  ctl_mem_req_id;

  // ---- FDIP signals ----
  logic fdip_acc, fdip_rsp, fdip_rsp_raw, fdip_busy_req, fdip_probe_busy, fdip_dc_req_valid;
  logic fdip_req_valid, fdip_fill_we, arr_fdip_peek_hit;
  logic [31:0] fdip_req_addr, fdip_dc_req_addr;
  logic [3:0]  fdip_req_id;
  logic [IC_IDX_W-1:0] fdip_peek_index, fdip_fill_index;
  logic [IC_TAG_W-1:0] fdip_peek_tag, fdip_fill_tag;
  logic [IC_LINE_W-1:0] fdip_fill_line;
  logic [XLEN_BITS-1:0] peek_fdip_vaddr;
  logic peek_fdip_ok, peek_b_ok;
  logic [31:0] peek_fdip_paddr, peek_b_paddr;

  // ---- Block B parallel lookup ----
  logic        b_same_page, b_pa_ok, arr_b_hit, pair_miss_en;
  logic [31:0] b_paddr;
  logic [IC_LINE_W-1:0] arr_b_hit_line;

  icache_ctl u_ctl (
    .clk, .rst_n, .refetch, .itlb_flush, .fence_i, .invalidate, .req_valid_in(req_valid), .pc(fetch_address),
    .ppn_valid, .page_fault, .ppn,
    .mem_req_ready     (fdip_busy_req ? 1'b0 : mem_req_ready),
    .mem_req_accepted  (fdip_acc ? 1'b0 : mem_req_accepted),
    .mem_req_accepted_id,
    .mem_resp_valid    (fdip_rsp_raw ? 1'b0 : mem_resp_valid),
    .mem_resp_id,
    .mem_resp_data     (mem_resp_line),
    .dc_resp_valid, .dc_resp_retry, .dc_resp_miss, .dc_resp_data, .dc_probe_busy(fdip_probe_busy),
    .hit(arr_hit), .hit_line(arr_hit_line), .has_invalid(arr_has_invalid), .first_invalid(arr_first_invalid),
    .repl_way(arr_repl_way),
    .arr_rd_en, .arr_rd_index, .arr_next_req_valid, .arr_next_rd_index, .arr_cmp_valid, .tw_we, .tw_index, .tw_way, .tw_tag, .tw_line, .inv_all,
    .mmu_req_valid, .mmu_req_vtag,
    .resp_valid, .resp_pc, .resp_ppn, .resp_page_fault, .resp_single_word, .resp_line, .icache_ready,
    .demand_mem_req_step0, .demand_dc_busy, .demand_miss_txv, .demand_miss_line,
    .mem_req_valid(ctl_mem_req_valid), .mem_req_addr(ctl_mem_req_addr),
    .mem_req_total_size(ctl_mem_req_total_size), .mem_req_bypass(ctl_mem_req_bypass),
    .mem_req_id(ctl_mem_req_id), .mem_resp_ready(ctl_mem_resp_ready),
    .dc_req_valid(ctl_dc_req_valid), .dc_req_addr(ctl_dc_req_addr)
  );

  // Block B address translation (same-page reuses resp_ppn; cross-page uses ITLB peek port 0)
  logic b_same_line;
  always_comb begin
    b_same_page  = (resp_pc[XLEN_BITS-1:12] == b_req_addr[XLEN_BITS-1:12]);
    b_paddr      = b_same_page ? {resp_ppn, b_req_addr[11:0]} : peek_b_paddr;
    b_pa_ok      = (b_same_page || peek_b_ok) && b_paddr[31];
    b_same_line  = (b_paddr[31:IC_OFF_W] == {resp_ppn, resp_pc[11:IC_OFF_W]});
    pair_miss_en = b_req_valid && b_pa_ok && !arr_b_hit;
  end

  icache_arr u_arr (
    .clk, .rst_n, .rd_en(arr_rd_en), .rd_index(arr_rd_index), .cmp_valid(arr_cmp_valid), .cmp_tag(ppn),
    .next_rd_index(arr_next_req_valid ? arr_next_rd_index : next_fa_idx),
    .next_b_rd_index(next_b_idx),
    .hit(arr_hit), .hit_line(arr_hit_line), .has_invalid(arr_has_invalid), .first_invalid(arr_first_invalid),
    .repl_way(arr_repl_way),
    .b_rd_valid(b_req_valid && b_pa_ok && !b_same_line),
    .b_rd_index(b_paddr[IC_OFF_W +: IC_IDX_W]), .b_cmp_tag(b_paddr[31:12]),
    .b_hit(arr_b_hit), .b_hit_line(arr_b_hit_line),
    .fdip_peek_index, .fdip_peek_tag, .fdip_peek_hit(arr_fdip_peek_hit),
    .we(tw_we), .w_index(tw_index), .w_way(tw_way), .w_tag(tw_tag), .w_line(tw_line), .inv_all,
    .fdip_we(fdip_fill_we), .fdip_w_index(fdip_fill_index), .fdip_w_tag(fdip_fill_tag), .fdip_w_line(fdip_fill_line)
  );

  icache_fdip u_fdip (
    .clk, .rst_n, .refetch, .fence_i,
    .demand_mem_req_step0, .demand_dc_busy, .demand_miss_txv, .demand_miss_line,
    .mem_req_accepted, .mem_req_accepted_id, .mem_resp_valid, .mem_resp_id, .mem_resp_line,
    .dc_resp_valid, .dc_resp_retry, .dc_resp_miss,
    .fdip_probe_busy, .fdip_dc_req_valid, .fdip_dc_req_addr,
    .peek_vaddr(peek_fdip_vaddr), .peek_ok(peek_fdip_ok), .peek_paddr(peek_fdip_paddr),
    .arr_peek_index(fdip_peek_index), .arr_peek_tag(fdip_peek_tag), .arr_peek_hit(arr_fdip_peek_hit),
    .pair_miss_en, .pair_miss_va(b_req_addr),
    .s2_en(fdip_s2_en), .s2_va(fdip_s2_va), .s2_clear(fdip_s2_clear),
    .fdip_acc, .fdip_rsp, .fdip_rsp_raw, .fdip_busy_req,
    .fdip_req_valid, .fdip_req_addr, .fdip_req_id,
    .fdip_fill_we, .fdip_fill_index, .fdip_fill_tag, .fdip_fill_line
  );

  // AXI & DCache probe output muxes: FDIP drives only when sending / probing (demand was gated cleanly)
  always_comb begin
    mem_resp_ready = ctl_mem_resp_ready || fdip_rsp;
    dc_req_valid   = fdip_dc_req_valid ? 1'b1             : ctl_dc_req_valid;
    dc_req_addr    = fdip_dc_req_valid ? fdip_dc_req_addr : ctl_dc_req_addr;
    if (fdip_req_valid) begin
      mem_req_valid      = 1'b1;
      mem_req_addr       = fdip_req_addr;
      mem_req_total_size = 8'(IC_LINE_W / 8 - 1);
      mem_req_bypass     = 1'b0;
      mem_req_id         = fdip_req_id;
    end else begin
      mem_req_valid      = ctl_mem_req_valid;
      mem_req_addr       = ctl_mem_req_addr;
      mem_req_total_size = ctl_mem_req_total_size;
      mem_req_bypass     = ctl_mem_req_bypass;
      mem_req_id         = ctl_mem_req_id;
    end
  end

  logic itlb_ptw_flush, first_cycle_q;
  icache_itlb #(.ENTRIES(ITLB_ENTRIES)) u_itlb (
    .clk, .rst_n, .itlb_flush, .refetch, .mmu_req_valid, .mmu_req_vtag,
    .csr_satp(csr_status_satp), .csr_privilege(csr_status_privilege), .csr_mxr(csr_status_mstatus_mxr),
    .csr_sum(csr_status_mstatus_sum), .csr_mprv(csr_status_mstatus_mprv), .csr_mpp(csr_status_mstatus_mpp),
    .ptw_req_ready(ptw_walk_req_ready), .ptw_resp_valid(ptw_walk_resp_valid),
    .ptw_resp_fault(ptw_walk_resp_fault), .ptw_resp_vpn(ptw_walk_resp_vpn),
    .ptw_resp_leaf_level(ptw_walk_resp_leaf_level),
    .ptw_resp_leaf_ppn(ptw_walk_resp_leaf_ppn), .ptw_resp_leaf_perm(ptw_walk_resp_leaf_perm),
    .peek_b_vaddr(b_req_addr), .peek_fdip_vaddr,
    .peek_b_ok, .peek_b_paddr, .peek_fdip_ok, .peek_fdip_paddr,
    .ppn_valid, .page_fault, .ppn,
    .ptw_req_valid(ptw_walk_req_valid), .ptw_req_vpn(ptw_walk_req_vpn), .ptw_req_root_ppn(ptw_walk_req_root_ppn),
    .ptw_resp_consumed(ptw_walk_resp_consumed), .ptw_flush(itlb_ptw_flush)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) first_cycle_q <= 1'b1;
    else        first_cycle_q <= 1'b0;
  end
  assign ptw_walk_flush = itlb_ptw_flush || first_cycle_q;

  icache_resp u_resp (
    .resp_valid, .resp_pc, .resp_page_fault, .resp_single_word, .resp_line, .fetch_pc, .fetch_group,
    .upper_ok(fetch_upper_ok),
    .page_fault_inst, .inst_valid
  );

  // Block B halfword-window extraction (reuses resp_line if same 64B physical line, else arr_b_hit_line)
  logic [IC_LINE_W-1:0] b_line_eff;
  logic [FETCH_WIDTH-1:0] b_inst_v_unused, b_pf_unused, b_up_unused;
  logic [XLEN_BITS-1:0]   b_pc_unused;
  logic [5:0]             b_avail_line;

  assign b_line_eff  = b_same_line ? resp_line : arr_b_hit_line;

  icache_resp u_resp_b (
    .resp_valid      (b_req_valid && b_pa_ok && arr_b_hit),
    .resp_pc         (b_req_addr),
    .resp_page_fault (1'b0),
    .resp_single_word(1'b0),
    .resp_line       (b_line_eff),
    .fetch_pc        (b_pc_unused),
    .fetch_group     (b_fetch_group),
    .upper_ok        (b_up_unused),
    .page_fault_inst (b_pf_unused),
    .inst_valid      (b_inst_v_unused)
  );

  always_comb begin
    b_avail_line = 6'd32 - {1'b0, b_req_addr[IC_OFF_W-1:1]};
    b_actual_n   = ({2'b00, b_req_nwords} < b_avail_line) ? {1'b0, b_req_nwords} : b_avail_line[4:0];
    b_hit        = b_req_valid && b_pa_ok && arr_b_hit && (b_actual_n != 5'd0);
  end

  assign read_complete     = resp_valid;
  assign fetch_single_word = resp_single_word;

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ic;
  assign unused_ic = ^{b_inst_v_unused, b_pf_unused, b_up_unused, b_pc_unused, b_paddr[IC_OFF_W-1:0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
