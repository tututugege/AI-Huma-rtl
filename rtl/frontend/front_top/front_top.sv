// Ref: front-end/front_top.cpp  FrontCore (BPU + 4-bank/FDIP ICache + inst_fifo + checker, backed by Unified FTQ-64)
`default_nettype none

module front_top import ttg_cfg_pkg::*; import front_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*;
  import bpu_types_pkg::FTB_BLK_ID_W; import icache_pkg::*; import tlb_mmu_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  // ---- back end -> front end (registered back2front + registered Unified FTQ-64 view) ----
  input  logic        be_refetch,
  input  logic [XLEN_BITS-1:0] be_refetch_address,
  input  logic        be_rf_valid,
  input  logic [FTB_BLK_ID_W-1:0] be_rf_blk,
  input  logic [FTB_BLK_ID_W-1:0] be_next_rf_blk,
  input  logic [2:0]  be_rf_type,
  input  logic [XLEN_BITS-1:0] be_rf_pc,
  input  logic        be_rf_is_rvc,
  input  logic        itlb_flush,
  input  logic        fence_i,
  input  logic        fifo_read_enable,
  input  ftq_fe_view_t ftq2fe,
  input  logic [XLEN_BITS-1:0] csr_status_satp,
  input  logic [1:0]  csr_status_privilege,
  input  logic        csr_status_mstatus_mxr,
  input  logic        csr_status_mstatus_sum,
  input  logic        csr_status_mstatus_mprv,
  input  logic [1:0]  csr_status_mstatus_mpp,
  input  logic [NCOMMIT-1:0] upd_valid,
  input  logic [XLEN_BITS-1:0] base_pc    [NCOMMIT],
  input  logic [NCOMMIT-1:0] actual_dir,
  input  logic [NCOMMIT-1:0] upd_is_rvc,
  input  logic [2:0]          br_type    [NCOMMIT],
  input  logic [XLEN_BITS-1:0] target     [NCOMMIT],
  input  logic [NCOMMIT-1:0] pred_dir,
  input  logic [NCOMMIT-1:0] alt_pred,
  input  logic [front_pkg::PCPN_W-1:0] pcpn [NCOMMIT],
  input  logic [FTB_BLK_ID_W-1:0] blk_id    [NCOMMIT],
  // ---- memory side inputs ----
  input  logic        mem_req_ready,
  input  logic        mem_req_accepted,
  input  logic [3:0]  mem_req_accepted_id,
  input  logic        mem_resp_valid,
  input  logic [3:0]  mem_resp_id,
  input  logic [31:0] mem_resp_data [ICACHE_WORD_NUM],
  input  logic        dc_resp_valid,
  input  logic        dc_resp_retry,
  input  logic        dc_resp_miss,
  input  logic [31:0] dc_resp_data,
  input  logic        ptw_walk_req_ready,
  input  logic        ptw_walk_resp_valid,
  input  logic        ptw_walk_resp_fault,
  input  logic [VPN_W-1:0]  ptw_walk_resp_vpn,
  input  logic [PPN_W-1:0]  ptw_walk_resp_leaf_ppn,
  input  logic [PERM_W-1:0] ptw_walk_resp_leaf_perm,
  input  logic [LVL_W-1:0]  ptw_walk_resp_leaf_level,
  // ---- front end -> back end (trimmed instruction delivery + Unified FTQ-64 write requests) ----
  output logic [FETCH_WIDTH-1:0]   out_lane_valid,
  output logic [31:0]              out_instructions [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0]   out_page_fault_inst,
  output logic [FETCH_WIDTH-1:0]   out_pf_inst_hi,
  output logic [FTQ_IDX_WIDTH-1:0] out_ftq_idx,
  output fe_ftq_s0_t               fe2ftq_s0,
  output fe_ftq_s2_t               fe2ftq_s2,
  output fe_ftq_pd_t               fe2ftq_pd,
  // ---- memory side outputs ----
  output logic        mem_req_valid,
  output logic [31:0] mem_req_addr,
  output logic [7:0]  mem_req_total_size,
  output logic        mem_req_bypass,
  output logic [3:0]  mem_req_id,
  output logic        mem_resp_ready,
  output logic        dc_req_valid,
  output logic [31:0] dc_req_addr,
  output logic        ptw_walk_req_valid,
  output logic [VPN_W-1:0] ptw_walk_req_vpn,
  output logic [21:0] ptw_walk_req_root_ppn,
  output logic        ptw_walk_resp_consumed,
  output logic        ptw_walk_flush,
  output logic [3:0]  commit_upd_free,
  output logic [3:0]  commit_tq_free
);

  // ---- control ----
  logic        global_refetch;
  logic [XLEN_BITS-1:0] refetch_address;
  logic        fa_rd_en, predecode_can_run, bpu_can_run, bpu_icache_read_ready;
  logic        fa_wr_en, s2_wr_en, do_predecode_flush;
  logic        inst_empty, inst_fifo_room;
  logic        fa_drop_tail, bpu_override_squash, refetch_pd;
  logic        bpu_icache_read_valid, bpu_ptab_write_enable;
  logic        checker_flush_enable;
  logic [XLEN_BITS-1:0] checker_flush_address;
  logic        icache_ready;

  front_ctrl u_ctrl (
    .clk, .rst_n,
    .be_refetch, .be_refetch_address,
    .be_fifo_read_enable   (fifo_read_enable),
    .icache_ready,
    .ftq_full              (ftq2fe.ftq_full),
    .fa_empty              (ftq2fe.fa_empty),
    .fa_head_fresh         (ftq2fe.fa_head_fresh),
    .inst_empty, .inst_fifo_room,
    .s2_empty              (ftq2fe.s2_empty),
    .bpu_icache_read_valid,
    .bpu_ptab_write_enable,
    .checker_flush_enable, .checker_flush_address,
    .bpu_override_squash,
    .global_refetch, .refetch_address, .fa_rd_en, .predecode_can_run, .bpu_can_run, .bpu_icache_read_ready,
    .fa_wr_en, .fa_drop_tail, .s2_wr_en, .do_predecode_flush
  );

  // ---- fetch side & FDIP wires ----
  logic [XLEN_BITS-1:0] bpu_fetch_address, fa_rd_address, ic_fetch_pc, b_req_addr, fdip_s2_va;
  fetch_pair_t          bpu_fetch_pair;
  logic                 fa_rd_valid, ic_read_complete, ic_fetch_single_word;
  logic                 b_req_valid, b_hit, fdip_s2_en, fdip_s2_clear;
  logic [3:0]           b_req_nwords;
  logic [IC_IDX_W-1:0]  ic_next_fa_idx, ic_next_b_idx;
  logic [4:0]           b_actual_n;
  logic [FETCH_WIDTH-1:0] ic_inst_valid, ic_page_fault_inst, ic_upper_ok_unused;
  logic [31:0]          ic_fetch_group [FETCH_WIDTH], b_fetch_group [FETCH_WIDTH];
  inst_fifo_entry_t     inst_rd;

  icache u_icache (
    .clk, .rst_n,
    .refetch         (global_refetch),
    .itlb_flush, .fence_i,
    .invalidate      (do_predecode_flush),
    .req_valid       (fa_rd_valid),
    .fetch_address   (fa_rd_address),
    .b_req_valid, .b_req_addr, .b_req_nwords,
    .next_fa_idx     (ic_next_fa_idx),
    .next_b_idx      (ic_next_b_idx),
    .fdip_s2_en, .fdip_s2_va, .fdip_s2_clear,
    .csr_status_satp, .csr_status_privilege, .csr_status_mstatus_mxr, .csr_status_mstatus_sum,
    .csr_status_mstatus_mprv, .csr_status_mstatus_mpp,
    .mem_req_ready, .mem_req_accepted, .mem_req_accepted_id, .mem_resp_valid, .mem_resp_id, .mem_resp_data,
    .dc_resp_valid, .dc_resp_retry, .dc_resp_miss, .dc_resp_data,
    .ptw_walk_req_ready, .ptw_walk_resp_valid, .ptw_walk_resp_fault, .ptw_walk_resp_vpn,
    .ptw_walk_resp_leaf_ppn, .ptw_walk_resp_leaf_perm, .ptw_walk_resp_leaf_level,
    .icache_ready,
    .read_complete     (ic_read_complete),
    .fetch_pc          (ic_fetch_pc),
    .inst_valid        (ic_inst_valid),
    .page_fault_inst   (ic_page_fault_inst),
    .fetch_group       (ic_fetch_group),
    .fetch_upper_ok    (ic_upper_ok_unused),
    .fetch_single_word (ic_fetch_single_word),
    .b_hit, .b_actual_n, .b_fetch_group,
    .mem_req_valid, .mem_req_addr, .mem_req_total_size, .mem_req_bypass, .mem_req_id, .mem_resp_ready,
    .dc_req_valid, .dc_req_addr,
    .ptw_walk_req_valid, .ptw_walk_req_vpn, .ptw_walk_req_root_ppn, .ptw_walk_resp_consumed, .ptw_walk_flush
  );

  front_fetch_buf u_fetch_buf (
    .clk, .rst_n, .global_refetch, .do_predecode_flush,
    .ftq_fa_empty        (ftq2fe.fa_empty),
    .ftq_ifu_addr        (ftq2fe.ifu_addr),
    .ftq_ifu_pair        (ftq2fe.ifu_pair),
    .ftq_ifu_next_fa_idx (ftq2fe.ifu_next_fa_idx),
    .ftq_ifu_next_b_idx  (ftq2fe.ifu_next_b_idx),
    .fa_rd_en,
    .fa_wr_address       (bpu_fetch_address),
    .fa_wr_pair          (bpu_fetch_pair),
    .fa_rd_valid, .fa_rd_address, .inst_fifo_room,
    .ic_read_complete, .ic_fetch_pc, .ic_inst_valid, .ic_page_fault_inst, .ic_fetch_group, .ic_fetch_single_word,
    .b_req_valid, .b_req_addr, .b_req_nwords, .ic_next_fa_idx, .ic_next_b_idx, .b_hit, .b_actual_n, .b_fetch_group,
    .inst_rd_en          (predecode_can_run),
    .inst_empty,
    .inst_rd
  );

  // ---- prediction side + Unified FTQ-64 S2/PD write requests ----
  front_pred_path u_pred_path (
    .clk, .rst_n,
    .global_refetch, .refetch_address, .be_refetch,
    .refetch_pd, .rf_valid(be_rf_valid), .rf_blk(be_rf_blk), .next_rf_blk(be_next_rf_blk), .rf_type(be_rf_type),
    .rf_pc(be_rf_pc), .rf_is_rvc(be_rf_is_rvc),
    .bpu_icache_read_ready, .s2_wr_en, .predecode_can_run,
    .ftq_pd_idx      (ftq2fe.pd_idx),
    .ftq_pd_base_pc  (ftq2fe.pd_base_pc),
    .ftq_pd_is_pair  (ftq2fe.pd_is_pair),
    .ftq_pd_base_b   (ftq2fe.pd_base_b),
    .ftq_pd_a_len    (ftq2fe.pd_a_len),
    .ftq_pd_pred_dir (ftq2fe.pd_pred_dir),
    .ftq_pd_next_pc  (ftq2fe.pd_next_pc),
    .upd_valid, .base_pc, .actual_dir, .upd_is_rvc, .br_type, .target, .pred_dir, .alt_pred, .pcpn, .blk_id,
    .inst_rd,
    .bpu_icache_read_valid, .bpu_fetch_address, .bpu_fetch_pair, .bpu_ptab_write_enable,
    .bpu_override_squash, .fdip_s2_en, .fdip_s2_va, .fdip_s2_clear,
    .checker_flush_enable, .checker_flush_address,
    .fe2ftq_s2, .fe2ftq_pd,
    .out_lane_valid, .out_instructions, .out_page_fault_inst, .out_pf_inst_hi, .out_ftq_idx,
    .commit_upd_free, .commit_tq_free
  );

  assign refetch_pd = global_refetch && !be_refetch;

  // S0 allocate / S2-override tail drop / ICache issue pop -> ftq_ibuf
  always_comb begin
    fe2ftq_s0           = '0;
    fe2ftq_s0.wr_en     = fa_wr_en;
    fe2ftq_s0.addr      = bpu_fetch_address;
    fe2ftq_s0.pair      = bpu_fetch_pair;
    fe2ftq_s0.drop_tail = fa_drop_tail;
    fe2ftq_s0.ifu_pop   = fa_rd_valid;
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = ^{bpu_can_run, ic_upper_ok_unused};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
