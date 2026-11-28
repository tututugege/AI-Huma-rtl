// Ref: front-end/icache/icache_top.cpp  ICacheTop (64KiB 2-stage F0->F1 Lo/Hi 1RW VIPT + FDIP fill buffer)
`default_nettype none

module icache import ttg_cfg_pkg::*; import icache_pkg::*; import tlb_mmu_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  input  logic refetch,
  input  logic itlb_flush,
  input  logic fence_i,
  input  logic invalidate,
  input  logic req_valid,
  input  logic [XLEN_BITS-1:0] fetch_address,
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
  output logic [1:0]  ic_inflight,
  output logic read_complete,
  output logic [XLEN_BITS-1:0] fetch_pc,
  output logic [FETCH_WIDTH-1:0] inst_valid,
  output logic [FETCH_WIDTH-1:0] page_fault_inst,
  output logic [15:0] fetch_half [FETCH_WIDTH],
  output logic [15:0] fetch_up16,
  output logic        fetch_single_word,
  output logic        b_hit,
  output logic        b_is_straddle,
  output logic        b_is_tail,
  output logic [3:0]  b_a_len,
  output logic [3:0]  b_actual_n,
  output logic [15:0] b_half [FETCH_WIDTH],
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

  logic [IC_LINE_W-1:0] mem_resp_line;
  for (genvar w = 0; w < IC_WORDS; w++) begin : g_pack
    assign mem_resp_line[IC_WORD_W * w +: IC_WORD_W] = mem_resp_data[w];
  end

  logic arr_rd_en, arr_data_rd_en, arr_cmp_valid, arr_hit, arr_b_hit, arr_has_invalid, tw_we, inv_all, mmu_req_valid;
  logic [IC_IDX_W-1:0] arr_rd_index, tw_index;
  logic [XLEN_BITS-1:0] arr_rd_pc, f0_pc, peek_fdip_vaddr;
  logic [IC_WAY_W-1:0] arr_first_invalid, arr_repl_way, tw_way;
  logic [IC_TAG_W-1:0] tw_tag, f0_ppn, ppn;
  logic [IC_LINE_W-1:0] tw_line, f0_byp_line, fdip_fill_line;
  logic [IC_LINE_W/2-1:0] lo_rdata, hi_rdata;
  logic [XLEN_BITS-13:0] mmu_req_vtag;
  logic ppn_valid, page_fault, f0_resp_valid, f0_from_sram, f0_resp_pf, f0_resp_single;
  logic r_req_valid_o, demand_idle_req, demand_mem_req_step0, demand_dc_busy, demand_miss_txv;
  logic [25:0] demand_miss_line;
  logic ctl_mem_req_valid, ctl_mem_req_bypass, ctl_mem_resp_ready, ctl_dc_req_valid;
  logic [31:0] ctl_mem_req_addr, ctl_dc_req_addr, fdip_req_addr, fdip_dc_req_addr, peek_fdip_paddr;
  logic [7:0] ctl_mem_req_total_size;
  logic [3:0] ctl_mem_req_id, fdip_req_id;
  logic fdip_acc, fdip_rsp, fdip_rsp_raw, fdip_busy_req, fdip_probe_busy, fdip_fb_busy;
  logic fdip_dc_req_valid, fdip_req_valid, fdip_fill_we, arr_fdip_peek_hit, peek_fdip_ok, b_miss_en;
  logic [IC_IDX_W-1:0] fdip_peek_index, fdip_fill_index;
  logic [IC_TAG_W-1:0] fdip_peek_tag, fdip_fill_tag;

  icache_ctl u_ctl (
    .clk, .rst_n, .refetch, .itlb_flush, .fence_i, .invalidate, .req_valid_in(req_valid), .pc(fetch_address),
    .ppn_valid, .page_fault, .ppn,
    .mem_req_ready     (fdip_busy_req ? 1'b0 : mem_req_ready),
    .mem_req_accepted  (fdip_acc ? 1'b0 : mem_req_accepted),
    .mem_req_accepted_id,
    .mem_resp_valid    (fdip_rsp_raw ? 1'b0 : mem_resp_valid),
    .mem_resp_id, .mem_resp_data(mem_resp_line),
    .dc_resp_valid, .dc_resp_retry, .dc_resp_miss, .dc_resp_data, .dc_probe_busy(fdip_probe_busy),
    .fdip_fb_busy,
    .hit(arr_hit), .has_invalid(arr_has_invalid), .first_invalid(arr_first_invalid), .repl_way(arr_repl_way),
    .arr_rd_en, .arr_data_rd_en, .arr_rd_index, .arr_rd_pc, .arr_cmp_valid,
    .tw_we, .tw_index, .tw_way, .tw_tag, .tw_line, .inv_all,
    .mmu_req_valid, .mmu_req_vtag,
    .resp_valid(f0_resp_valid), .f0_from_sram, .resp_pc(f0_pc), .resp_ppn(f0_ppn),
    .resp_page_fault(f0_resp_pf), .resp_single_word(f0_resp_single), .resp_line(f0_byp_line),
    .icache_ready, .r_req_valid_o, .demand_idle_req,
    .demand_mem_req_step0, .demand_dc_busy, .demand_miss_txv, .demand_miss_line,
    .mem_req_valid(ctl_mem_req_valid), .mem_req_addr(ctl_mem_req_addr),
    .mem_req_total_size(ctl_mem_req_total_size), .mem_req_bypass(ctl_mem_req_bypass),
    .mem_req_id(ctl_mem_req_id), .mem_resp_ready(ctl_mem_resp_ready),
    .dc_req_valid(ctl_dc_req_valid), .dc_req_addr(ctl_dc_req_addr)
  );

  logic arr_rd_b_need;
  assign arr_rd_b_need = arr_rd_pc[5] && (arr_rd_pc[11:6] != 6'h3f);

  icache_arr u_arr (
    .clk, .rst_n, .rd_en(arr_rd_en), .data_rd_en(arr_data_rd_en), .rd_index(arr_rd_index),
    .rd_pc_hi(arr_rd_pc[5]), .rd_b_need(arr_rd_b_need), .cmp_valid(arr_cmp_valid), .cmp_tag(ppn),
    .hit(arr_hit), .b_hit(arr_b_hit), .has_invalid(arr_has_invalid),
    .first_invalid(arr_first_invalid), .repl_way(arr_repl_way),
    .lo_rdata, .hi_rdata,
    .fdip_peek_index, .fdip_peek_tag, .fdip_peek_hit(arr_fdip_peek_hit),
    .we(tw_we), .w_index(tw_index), .w_way(tw_way), .w_tag(tw_tag), .w_line(tw_line), .inv_all,
    .fdip_we(fdip_fill_we), .fdip_w_index(fdip_fill_index), .fdip_w_tag(fdip_fill_tag), .fdip_w_line(fdip_fill_line)
  );

  // ---- F0 Block B decision & F0 -> F1 pipeline register ----
  logic                 f0_same_pg, f0_straddle, f0_tail, f0_b_need, f0_b_pa_ok, f0_b_en;
  logic [3:0]           f0_a_len, f0_b_nwords;
  logic [XLEN_BITS-1:0] f0_b_addr;
  ic_f1_t               f1_q, f1_d;
  logic [IC_LINE_W-1:0] f1_byp_line_q;

  always_comb begin
    f0_same_pg   = (f0_pc[11:6] != 6'h3f);
    f0_straddle  = (f0_pc[5:0] > 6'd32) && f0_same_pg;
    f0_tail      = (f0_pc[5:0] == 6'd32) && f0_same_pg;
    f0_b_need    = f0_straddle || f0_tail;
    f0_a_len     = f0_straddle ? 4'((7'd64 - {1'b0, f0_pc[5:0]}) >> 1) : 4'd0;
    f0_b_nwords  = f0_straddle ? (4'd0 - f0_a_len) : (f0_tail ? 4'd1 : 4'd0);
    f0_b_addr    = {f0_pc[XLEN_BITS-1:6] + (XLEN_BITS-6)'(1), 6'd0};
    f0_b_pa_ok   = f0_ppn[IC_TAG_W-1];
    f0_b_en      = f0_from_sram && f0_b_need && f0_b_pa_ok;
    b_miss_en = f0_b_en && !arr_b_hit;

    f1_d             = '0;
    f1_d.valid       = !invalidate && f0_resp_valid;
    f1_d.from_sram   = f0_from_sram;
    f1_d.page_fault  = f0_resp_pf;
    f1_d.single_word = f0_resp_single;
    f1_d.pc          = f0_pc;
    f1_d.use_hi_only = f0_pc[5];
    f1_d.b_hit       = f0_b_en && arr_b_hit;
    f1_d.b_is_straddle = f0_b_en && f0_straddle;
    f1_d.b_is_tail   = f0_b_en && f0_tail;
    f1_d.a_len       = f0_a_len;
    f1_d.b_nwords    = f0_b_nwords;
  end

  always_ff @(posedge clk) begin
    if (!rst_n || refetch) f1_q <= '0;
    else                   f1_q <= f1_d;
    if (!rst_n)                             f1_byp_line_q <= '0;
    else if (f1_d.valid && !f1_d.from_sram) f1_byp_line_q <= f0_byp_line;
  end

  icache_fdip u_fdip (
    .clk, .rst_n, .refetch, .fence_i,
    .demand_mem_req_step0, .demand_dc_busy, .demand_miss_txv, .demand_miss_line,
    .demand_tw_we(tw_we), .demand_idle_req,
    .mem_req_accepted, .mem_req_accepted_id, .mem_resp_valid, .mem_resp_id, .mem_resp_line,
    .dc_resp_valid, .dc_resp_retry, .dc_resp_miss,
    .fdip_probe_busy, .fdip_fb_busy, .fdip_dc_req_valid, .fdip_dc_req_addr,
    .peek_vaddr(peek_fdip_vaddr), .peek_ok(peek_fdip_ok), .peek_paddr(peek_fdip_paddr),
    .arr_peek_index(fdip_peek_index), .arr_peek_tag(fdip_peek_tag), .arr_peek_hit(arr_fdip_peek_hit),
    .b_miss_en, .b_miss_va(f0_b_addr),
    .s2_en(fdip_s2_en), .s2_va(fdip_s2_va), .s2_clear(fdip_s2_clear),
    .fdip_acc, .fdip_rsp, .fdip_rsp_raw, .fdip_busy_req,
    .fdip_req_valid, .fdip_req_addr, .fdip_req_id,
    .fdip_fill_we, .fdip_fill_index, .fdip_fill_tag, .fdip_fill_line
  );

  always_comb begin
    mem_resp_ready = ctl_mem_resp_ready || fdip_rsp;
    dc_req_valid   = fdip_dc_req_valid ? 1'b1             : ctl_dc_req_valid;
    dc_req_addr    = fdip_dc_req_valid ? fdip_dc_req_addr : ctl_dc_req_addr;
    if (fdip_req_valid) begin
      mem_req_valid = 1'b1; mem_req_addr = fdip_req_addr;
      mem_req_total_size = 8'(IC_LINE_W / 8 - 1); mem_req_bypass = 1'b0; mem_req_id = fdip_req_id;
    end else begin
      mem_req_valid = ctl_mem_req_valid; mem_req_addr = ctl_mem_req_addr;
      mem_req_total_size = ctl_mem_req_total_size; mem_req_bypass = ctl_mem_req_bypass; mem_req_id = ctl_mem_req_id;
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
    .peek_fdip_vaddr, .peek_fdip_ok, .peek_fdip_paddr,
    .ppn_valid, .page_fault, .ppn,
    .ptw_req_valid(ptw_walk_req_valid), .ptw_req_vpn(ptw_walk_req_vpn), .ptw_req_root_ppn(ptw_walk_req_root_ppn),
    .ptw_resp_consumed(ptw_walk_resp_consumed), .ptw_flush(itlb_ptw_flush)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) first_cycle_q <= 1'b1;
    else        first_cycle_q <= 1'b0;
  end
  assign ptw_walk_flush = itlb_ptw_flush || first_cycle_q;

  // ---- F1 Data SRAM output / halfword slicing -> inst_fifo ----
  logic                   f1_v;
  logic [IC_LINE_W-1:0]   f1_line_a;

  assign f1_v      = !refetch && f1_q.valid;
  assign f1_line_a = f1_q.from_sram ? (f1_q.use_hi_only ? {hi_rdata, 256'd0} : {hi_rdata, lo_rdata})
                                    : f1_byp_line_q;

  icache_resp u_resp (
    .resp_valid(f1_v), .resp_pc(f1_q.pc), .resp_page_fault(f1_q.page_fault),
    .resp_single_word(f1_q.single_word), .resp_line(f1_line_a),
    .fetch_pc, .fetch_half, .fetch_up16, .page_fault_inst, .inst_valid
  );
  // Block B always starts at halfword 0 of the next line (Lo half of the SRAM row): its lanes are the Lo halfwords.
  // They are read only while b_hit (front_fetch_buf), so no lane gating is needed.
  for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_b_half
    assign b_half[i] = lo_rdata[16 * i +: 16];
  end

  assign b_actual_n        = f1_q.b_nwords;
  assign b_hit             = f1_v && f1_q.b_hit && (f1_q.b_nwords != 4'd0);
  assign b_is_straddle     = f1_v && f1_q.b_is_straddle;
  assign b_is_tail         = f1_v && f1_q.b_is_tail;
  assign b_a_len           = f1_q.a_len;
  assign read_complete     = f1_v;
  assign fetch_single_word = f1_q.single_word;
  assign ic_inflight       = {1'b0, f1_q.valid} + {1'b0, r_req_valid_o};

  logic unused_ic;
  assign unused_ic = ^{f0_ppn[IC_TAG_W-2:0],
                       arr_rd_pc[XLEN_BITS-1:IC_OFF_W], arr_rd_pc[IC_OFF_W-2:0]};

endmodule
`default_nettype wire
