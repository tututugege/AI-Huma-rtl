// Ref: front-end/front_top.cpp  front_comb_calc (whole function); boundary = front.in / front.out plus the
//      memory-side ports of the icache (AXI read master, DCache probe, ITLB walk client)
`default_nettype none

// Front end: BPU + ICache(ITLB) + fetch-address / instruction / PTAB / front2back queues + predecode + checker.
// Top level only wires the blocks (spec/front_top.io); one evaluation per cycle, registers only inside the blocks:
//   front_ctrl       global refetch (with the delayed predecode refetch), read/write enables, bypass select
//   icache           fetch-address queue head -> fetch group (+ memory side ports)
//   front_fetch_buf  fetch-address queue, predecode, instruction queue
//   front_pred_path  BPU, PTAB, checker, front2back queue, output bypass
// Inputs from the back end (be_refetch.., upd_*, csr) are the REGISTERED back2front values of the reference.
module front_top import ttg_cfg_pkg::*; import front_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*;
  import icache_pkg::*; import tlb_mmu_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  // ---- back end -> front end (registered back2front) ----
  input  logic        be_refetch,
  input  logic [31:0] be_refetch_address,
  input  logic        be_rf_valid,
  input  logic [HCK_W-1:0] be_rf_ck,
  input  logic [EPOCH_W-1:0] be_rf_epoch,
  input  logic [2:0]  be_rf_type,
  input  logic [31:0] be_rf_pc,
  input  logic        itlb_flush,
  input  logic        fence_i,
  input  logic        fifo_read_enable,
  input  logic [31:0] csr_status_satp,
  input  logic [1:0]  csr_status_privilege,
  input  logic        csr_status_mstatus_mxr,
  input  logic        csr_status_mstatus_sum,
  input  logic        csr_status_mstatus_mprv,
  input  logic [1:0]  csr_status_mstatus_mpp,
  input  logic [NCOMMIT-1:0] upd_valid,
  input  logic [31:0]         base_pc    [NCOMMIT],
  input  logic [NCOMMIT-1:0] actual_dir,
  input  logic [2:0]          br_type    [NCOMMIT],
  input  logic [31:0]         target     [NCOMMIT],
  input  logic [NCOMMIT-1:0] pred_dir,
  input  logic [NCOMMIT-1:0] alt_pred,
  input  logic [front_pkg::PCPN_W-1:0]   pcpn       [NCOMMIT],
  input  logic [T_TAG_W-1:0]  tags       [NCOMMIT][TN],
  input  logic [T_IDX_W-1:0]  idxs       [NCOMMIT][TN],
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
  input  logic        ptw_walk_resp_leaf_level,
  // ---- front end -> back end (front.out, before the back end's no-taken truncation) ----
  output logic        out_valid,
  output logic [FETCH_WIDTH-1:0] out_lane_valid,
  output logic [31:0] out_instructions    [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0] out_page_fault_inst,
  output logic [FETCH_WIDTH-1:0] out_predict_dir,
  output logic [31:0] out_pc              [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0] out_alt_pred,
  output logic [front_pkg::PCPN_W-1:0]     out_altpcpn [FETCH_WIDTH],
  output logic [front_pkg::PCPN_W-1:0]     out_pcpn    [FETCH_WIDTH],
  output logic [TAGE_IDX_W-1:0] out_tage_idx [FETCH_WIDTH][TN_MAX],
  output logic [TAGE_TAG_W-1:0] out_tage_tag [FETCH_WIDTH][TN_MAX],
  output logic [31:0] out_predict_next_fetch_address,
  output logic [BCK_W-1:0] out_bpu_ck,
  output logic [FETCH_WIDTH-1:0][KIND_W-1:0] out_slot_kind,
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
  output logic        ptw_walk_flush
);

  // ---- control ----
  logic        global_refetch;
  logic [31:0] refetch_address;
  logic        fa_rd_en, predecode_can_run, bpu_can_run, bpu_icache_read_ready;
  logic        fa_wr_en, ptab_wr_en, f2b_wr_en, f2b_use_bypass, front_out_valid, do_predecode_flush;
  logic        fa_full, fa_empty, inst_empty, ptab_empty, f2b_full, f2b_empty;
  logic        fa_drop_tail, bpu_override_valid, bpu_override_squash, refetch_pd;
  logic [$clog2(FETCH_ADDR_FIFO_DEPTH + 1)-1:0] fa_size;
  logic        bpu_icache_read_valid, bpu_ptab_write_enable;
  logic        checker_flush_enable;
  logic [31:0] checker_flush_address;
  logic        icache_ready;

  front_ctrl u_ctrl (
    .clk, .rst_n,
    .be_refetch, .be_refetch_address,
    .be_fifo_read_enable   (fifo_read_enable),
    .icache_ready, .fa_full, .fa_empty, .inst_empty, .ptab_empty, .f2b_full, .f2b_empty,
    .bpu_icache_read_valid,
    .bpu_ptab_write_enable,
    .checker_flush_enable, .checker_flush_address,
    .bpu_override_valid, .bpu_override_squash, .fa_size,
    .global_refetch, .refetch_address, .fa_rd_en, .predecode_can_run, .bpu_can_run, .bpu_icache_read_ready,
    .fa_wr_en, .fa_drop_tail, .ptab_wr_en, .f2b_wr_en, .f2b_use_bypass, .front_out_valid, .do_predecode_flush
  );

  // ---- fetch side ----
  logic [31:0] bpu_fetch_address;
  logic        fa_rd_valid;
  logic [31:0] fa_rd_address;

  logic        ic_read_complete;
  logic [31:0] ic_fetch_pc;
  logic [FETCH_WIDTH-1:0] ic_inst_valid;
  logic [FETCH_WIDTH-1:0] ic_page_fault_inst;
  logic [31:0] ic_fetch_group     [FETCH_WIDTH];

  logic [31:0] inst_rd_instructions             [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] inst_rd_page_fault_inst;
  logic [FETCH_WIDTH-1:0] inst_rd_inst_valid;
  logic [1:0]  inst_rd_predecode_type           [FETCH_WIDTH];
  logic [31:0] inst_rd_predecode_target_address [FETCH_WIDTH];
  logic [31:0] inst_rd_seq_next_pc;

  icache u_icache (
    .clk, .rst_n,
    .refetch         (global_refetch),
    .itlb_flush, .fence_i,
    .invalidate      (do_predecode_flush),
    .req_valid       (fa_rd_valid),
    .fetch_address   (fa_rd_address),
    .csr_status_satp, .csr_status_privilege, .csr_status_mstatus_mxr, .csr_status_mstatus_sum,
    .csr_status_mstatus_mprv, .csr_status_mstatus_mpp,
    .mem_req_ready, .mem_req_accepted, .mem_req_accepted_id, .mem_resp_valid, .mem_resp_id, .mem_resp_data,
    .dc_resp_valid, .dc_resp_retry, .dc_resp_miss, .dc_resp_data,
    .ptw_walk_req_ready, .ptw_walk_resp_valid, .ptw_walk_resp_fault, .ptw_walk_resp_vpn,
    .ptw_walk_resp_leaf_ppn, .ptw_walk_resp_leaf_perm, .ptw_walk_resp_leaf_level,
    .icache_ready,
    .read_complete   (ic_read_complete),
    .fetch_pc        (ic_fetch_pc),
    .inst_valid      (ic_inst_valid),
    .page_fault_inst (ic_page_fault_inst),
    .fetch_group     (ic_fetch_group),
    .mem_req_valid, .mem_req_addr, .mem_req_total_size, .mem_req_bypass, .mem_req_id, .mem_resp_ready,
    .dc_req_valid, .dc_req_addr,
    .ptw_walk_req_valid, .ptw_walk_req_vpn, .ptw_walk_req_root_ppn, .ptw_walk_resp_consumed, .ptw_walk_flush
  );

  front_fetch_buf u_fetch_buf (
    .clk, .rst_n, .global_refetch,
    .fa_rd_en, .fa_wr_en, .fa_drop_tail,
    .fa_wr_address   (bpu_fetch_address),
    .fa_rd_valid, .fa_rd_address, .fa_full, .fa_empty, .fa_size,
    .ic_read_complete, .ic_fetch_pc, .ic_inst_valid, .ic_page_fault_inst, .ic_fetch_group,
    .inst_rd_en      (predecode_can_run),
    .inst_empty,
    .inst_rd_instructions, .inst_rd_page_fault_inst, .inst_rd_inst_valid, .inst_rd_predecode_type,
    .inst_rd_predecode_target_address, .inst_rd_seq_next_pc
  );

  // ---- prediction side + front.out ----
  logic [FETCH_WIDTH-1:0] out_inst_valid;

  front_pred_path u_pred_path (
    .clk, .rst_n,
    .global_refetch, .refetch_address, .be_refetch,
    .refetch_pd, .rf_valid(be_rf_valid), .rf_ck(be_rf_ck), .rf_epoch(be_rf_epoch), .rf_type(be_rf_type),
    .rf_pc(be_rf_pc),
    .be_fifo_read_enable (fifo_read_enable),
    .bpu_icache_read_ready, .ptab_wr_en, .predecode_can_run, .f2b_wr_en, .f2b_use_bypass,
    .upd_valid, .base_pc, .actual_dir, .br_type, .target, .pred_dir, .alt_pred, .pcpn, .tags, .idxs,
    .inst_rd_instructions, .inst_rd_page_fault_inst, .inst_rd_inst_valid, .inst_rd_predecode_type,
    .inst_rd_predecode_target_address, .inst_rd_seq_next_pc,
    .bpu_icache_read_valid, .bpu_fetch_address, .bpu_ptab_write_enable,
    .bpu_override_valid, .bpu_override_squash, .ptab_empty, .f2b_full, .f2b_empty,
    .checker_flush_enable, .checker_flush_address,
    .out_inst_valid, .out_instructions, .out_page_fault_inst, .out_predict_dir, .out_pc, .out_alt_pred,
    .out_altpcpn, .out_pcpn, .out_tage_idx, .out_tage_tag, .out_predict_next_fetch_address,
    .out_bpu_ck, .out_slot_kind
  );

  // the delayed predecode refetch is the part of the global refetch that does not come from the back end
  assign refetch_pd = global_refetch && !be_refetch;

  // front.out.FIFO_valid and the per-lane valid seen by the back end (back.in.valid[j] = FIFO_valid & inst_valid[j])
  assign out_valid = front_out_valid;
  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) out_lane_valid[i] = front_out_valid && out_inst_valid[i];
  end

  // bpu_can_run only gates the BPU's icache_read_ready inside front_ctrl
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = bpu_can_run;
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
