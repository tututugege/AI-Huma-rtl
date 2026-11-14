// Ref: front-end/icache/ICacheTop.cpp  TrueICacheTopT (comb/seq); icache.cpp icache_comb_calc / icache_peek_ready
`default_nettype none

// Front-end instruction cache with ITLB.  Top level only adapts the flat spec ports and wires the sub-blocks
// (spec/icache.io).
module icache import ttg_cfg_pkg::*; import icache_pkg::*; import tlb_mmu_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  input  logic refetch,
  input  logic itlb_flush,
  input  logic fence_i,
  input  logic invalidate,
  input  logic req_valid,
  input  logic [XLEN_BITS-1:0] fetch_address,
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

  // ---- control FSM ----
  logic arr_rd_en, arr_cmp_valid, arr_hit, arr_has_invalid, tw_we, inv_all, mmu_req_valid;
  logic [IC_IDX_W-1:0] arr_rd_index, tw_index;
  logic [IC_WAY_W-1:0] arr_first_invalid, tw_way;
  logic [IC_TAG_W-1:0] tw_tag;
  logic [IC_LINE_W-1:0] arr_hit_line, tw_line, resp_line;
  logic [XLEN_BITS-13:0] mmu_req_vtag;
  logic ppn_valid, page_fault;
  logic [IC_TAG_W-1:0] ppn;
  logic resp_valid, resp_page_fault, resp_single_word;
  logic [XLEN_BITS-1:0] resp_pc;

  icache_ctl u_ctl (
    .clk, .rst_n, .refetch, .itlb_flush, .fence_i, .invalidate, .req_valid_in(req_valid), .pc(fetch_address),
    .ppn_valid, .page_fault, .ppn,
    .mem_req_ready, .mem_req_accepted, .mem_req_accepted_id, .mem_resp_valid, .mem_resp_id,
    .mem_resp_data(mem_resp_line),
    .dc_resp_valid, .dc_resp_retry, .dc_resp_miss, .dc_resp_data,
    .hit(arr_hit), .hit_line(arr_hit_line), .has_invalid(arr_has_invalid), .first_invalid(arr_first_invalid),
    .arr_rd_en, .arr_rd_index, .arr_cmp_valid, .tw_we, .tw_index, .tw_way, .tw_tag, .tw_line, .inv_all,
    .mmu_req_valid, .mmu_req_vtag,
    .resp_valid, .resp_pc, .resp_page_fault, .resp_single_word, .resp_line, .icache_ready,
    .mem_req_valid, .mem_req_addr, .mem_req_total_size, .mem_req_bypass, .mem_req_id, .mem_resp_ready,
    .dc_req_valid, .dc_req_addr
  );

  icache_arr u_arr (
    .clk, .rst_n, .rd_en(arr_rd_en), .rd_index(arr_rd_index), .cmp_valid(arr_cmp_valid), .cmp_tag(ppn),
    .hit(arr_hit), .hit_line(arr_hit_line), .has_invalid(arr_has_invalid), .first_invalid(arr_first_invalid),
    .we(tw_we), .w_index(tw_index), .w_way(tw_way), .w_tag(tw_tag), .w_line(tw_line), .inv_all
  );

  logic itlb_ptw_flush, first_cycle_q;
  icache_itlb #(.ENTRIES(ITLB_ENTRIES)) u_itlb (
    .clk, .rst_n, .itlb_flush, .refetch, .mmu_req_valid, .mmu_req_vtag,
    .csr_satp(csr_status_satp), .csr_privilege(csr_status_privilege), .csr_mxr(csr_status_mstatus_mxr),
    .csr_sum(csr_status_mstatus_sum), .csr_mprv(csr_status_mstatus_mprv), .csr_mpp(csr_status_mstatus_mpp),
    .ptw_req_ready(ptw_walk_req_ready), .ptw_resp_valid(ptw_walk_resp_valid),
    .ptw_resp_fault(ptw_walk_resp_fault), .ptw_resp_vpn(ptw_walk_resp_vpn),
    .ptw_resp_leaf_level(ptw_walk_resp_leaf_level),
    .ptw_resp_leaf_ppn(ptw_walk_resp_leaf_ppn), .ptw_resp_leaf_perm(ptw_walk_resp_leaf_perm),
    .ppn_valid, .page_fault, .ppn,
    .ptw_req_valid(ptw_walk_req_valid), .ptw_req_vpn(ptw_walk_req_vpn), .ptw_req_root_ppn(ptw_walk_req_root_ppn),
    .ptw_resp_consumed(ptw_walk_resp_consumed), .ptw_flush(itlb_ptw_flush)
  );

  // The first cycle after reset also flushes the PTW walk client (the reference leaves the flush of its
  // initialisation call on the port; harmless, but visible at the boundary).
  always_ff @(posedge clk) begin
    if (!rst_n) first_cycle_q <= 1'b1;
    else        first_cycle_q <= 1'b0;
  end
  assign ptw_walk_flush = itlb_ptw_flush || first_cycle_q;

  icache_resp u_resp (
    .resp_valid, .resp_pc, .resp_page_fault, .resp_single_word, .resp_line, .fetch_pc, .fetch_group,
    .page_fault_inst, .inst_valid
  );

  assign read_complete = resp_valid;

endmodule

`default_nettype wire
