// Ref: rv_simu_mmu_v2.cpp  SimCpu::cycle (front end + back end + the registers between them); BackTop; FrontTop
`default_nettype none

// Core without the memory subsystem: front_top + back_top + the SimCpu glue between them (core_front).
//   core_back2front : back2front register (redirect, fence flushes, stall, BPU training data), one cycle late
//   core_front2back : front.out -> back.in (no-taken cut, 8->16 lane widening, stall hold register)
// Boundary = everything outside the core: the icache AXI read master / DCache probe / ITLB walk client, the LSU's
// DCache / MMIO / DTLB walk ports, interrupt injection; plus the retirement stream (rob_commit / rob_bcast).
// Order of SimCpu::cycle(): registered back2front -> front comb -> back comb -> back2front / hold registers.
module core_top import ttg_cfg_pkg::*; import front_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*;
  import bpu_types_pkg::FTB_BLK_ID_W; import icache_pkg::*; import tlb_mmu_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  // ---- icache memory side (AXI read master, DCache coherent probe) ----
  input  logic mem_req_ready,
  input  logic mem_req_accepted,
  input  logic [3:0] mem_req_accepted_id,
  input  logic mem_resp_valid,
  input  logic [3:0] mem_resp_id,
  input  logic [31:0] mem_resp_data [ICACHE_WORD_NUM],
  input  logic dc_resp_valid,
  input  logic dc_resp_retry,
  input  logic dc_resp_miss,
  input  logic [31:0] dc_resp_data,
  // ---- walk clients of the page table walker: ITLB (front) and DTLB (back) ----
  input  logic itlb_walk_req_ready,
  input  logic itlb_walk_resp_valid,
  input  logic itlb_walk_resp_fault,
  input  logic [VPN_W-1:0] itlb_walk_resp_vpn,
  input  logic [PPN_W-1:0] itlb_walk_resp_leaf_ppn,
  input  logic [PERM_W-1:0] itlb_walk_resp_leaf_perm,
  input  logic [LVL_W-1:0] itlb_walk_resp_leaf_level,
  input  logic dtlb_walk_req_ready,
  input  logic dtlb_walk_resp_valid,
  input  logic dtlb_walk_resp_fault,
  input  logic [VPN_W-1:0] dtlb_walk_resp_vpn,
  input  logic [PPN_W-1:0] dtlb_walk_resp_leaf_ppn,
  input  logic [PERM_W-1:0] dtlb_walk_resp_leaf_perm,
  input  logic [LVL_W-1:0] dtlb_walk_resp_leaf_level,
  // ---- LSU <-> DCache / MMIO, interrupt injection ----
  input  logic [XLEN_BITS-1:0] dcache2lsu_load_resps_data [LSU_LDU_COUNT],
  input  logic [1:0] dcache2lsu_load_resps_replay [LSU_LDU_COUNT],
  input  logic [31:0] dcache2lsu_load_resps_req_id [LSU_LDU_COUNT],
  input  logic dcache2lsu_load_resps_valid [LSU_LDU_COUNT],
  input  logic dcache2lsu_load_retry_busy [LSU_LDU_COUNT],
  input  logic dcache2lsu_store_retry_busy [LSU_STA_COUNT],
  input  logic dcache2lsu_mshr_fill,
  input  logic [25:0] dcache2lsu_mshr_fill_line,
  input  logic [1:0] dcache2lsu_store_resps_replay [LSU_STA_COUNT],
  input  logic [31:0] dcache2lsu_store_resps_req_id [LSU_STA_COUNT],
  input  logic dcache2lsu_store_resps_valid [LSU_STA_COUNT],
  input  logic interrupt_inject_external_irq_pending,
  input  logic interrupt_inject_external_irq_pending_valid,
  input  logic interrupt_inject_supervisor_external_irq_pending,
  input  logic interrupt_inject_supervisor_external_irq_pending_valid,
  input  logic interrupt_inject_timer_irq_pending,
  input  logic interrupt_inject_timer_irq_pending_valid,
  input  logic peripheral_resp_is_mmio,
  input  logic [XLEN_BITS-1:0] peripheral_resp_mmio_rdata,
  input  logic peripheral_resp_ready,
  // ---- outputs: icache memory side ----
  output logic mem_req_valid,
  output logic [31:0] mem_req_addr,
  output logic [7:0] mem_req_total_size,
  output logic mem_req_bypass,
  output logic [3:0] mem_req_id,
  output logic mem_resp_ready,
  output logic dc_req_valid,
  output logic [31:0] dc_req_addr,
  output logic itlb_walk_req_valid,
  output logic [VPN_W-1:0] itlb_walk_req_vpn,
  output logic [21:0] itlb_walk_req_root_ppn,
  output logic itlb_walk_resp_consumed,
  output logic itlb_walk_flush,
  // ---- outputs: LSU memory side, DTLB walk client, retirement stream ----
  output logic dtlb_walk_flush,
  output logic [21:0] dtlb_walk_req_root_ppn,
  output logic dtlb_walk_req_valid,
  output logic [VPN_W-1:0] dtlb_walk_req_vpn,
  output logic dtlb_walk_resp_consumed,
  output logic [XLEN_BITS-1:0] ftq_commit_info_resp_pc [COMMIT_WIDTH],
  output logic [XLEN_BITS-1:0] out_commit_entry_uop_diag_val [COMMIT_WIDTH],
  output logic out_mispred,
  output logic [XLEN_BITS-1:0] out_redirect_pc,
  output logic [31:0] lsu2dcache_load_ports_addr [LSU_LDU_COUNT],
  output logic [30:0] lsu2dcache_load_ports_req_id [LSU_LDU_COUNT],
  output logic lsu2dcache_load_ports_replay [LSU_LDU_COUNT],
  output logic [31:0] lsu2dcache_load_ports_pc [LSU_LDU_COUNT],
  output logic [38:0] lsu2dcache_load_ports_va [LSU_LDU_COUNT],
  input  logic [LSU_LDU_COUNT-1:0] pf_xq_v,
  input  logic [38:0] pf_xq_va [LSU_LDU_COUNT],
  input  logic [LSU_LDU_COUNT-1:0] pf_xq_llc,
  output logic [2:0] pf_xq_pop,
  output logic [LSU_LDU_COUNT-1:0] pf_xans_v,
  output logic [25:0] pf_xans_line [LSU_LDU_COUNT],
  output logic [LSU_LDU_COUNT-1:0] pf_xans_llc,
  output logic lsu2dcache_load_ports_valid [LSU_LDU_COUNT],
  output logic [31:0] lsu2dcache_store_ports_addr [LSU_STA_COUNT],
  output logic [XLEN_BITS-1:0] lsu2dcache_store_ports_data [LSU_STA_COUNT],
  output logic [5:0] lsu2dcache_store_ports_req_id [LSU_STA_COUNT],
  output logic [DST_STRB_W-1:0] lsu2dcache_store_ports_strb [LSU_STA_COUNT],
  output logic [DST_L2_W-1:0] lsu2dcache_store_ports_l2 [LSU_STA_COUNT],
  output logic lsu2dcache_store_ports_valid [LSU_STA_COUNT],
  output logic peripheral_req_is_mmio,
  output logic [31:0] peripheral_req_mmio_addr,
  output logic [2:0] peripheral_req_mmio_fun3,
  output logic [XLEN_BITS-1:0] peripheral_req_mmio_wdata,
  output logic peripheral_req_wen,
  output logic rob_bcast_exception,
  output logic rob_bcast_fence,
  output logic rob_bcast_fence_i,
  output logic rob_bcast_flush,
  output logic rob_bcast_mret,
  output logic [XLEN_BITS-1:0] rob_bcast_pc,
  output logic rob_bcast_sret,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_br_taken,
  output logic [5:0] rob_commit_commit_entry_uop_dest_areg [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_dest_en,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_page_fault_inst,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_page_fault_load,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_page_fault_store,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_rob_flag,
  output logic [ROB_IDX_WIDTH-1:0] rob_commit_commit_entry_uop_rob_idx [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_stq_flag,
  output logic [5:0] rob_commit_commit_entry_uop_stq_idx [COMMIT_WIDTH],
  output logic [4:0] rob_commit_commit_entry_uop_type [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_valid
);

  // ---- PMU event bus, tier 1 (EXP-013): read by the testbench; the pmu counters are not on a CSR yet ----
  logic rob_bcast_interrupt;
  logic [COMMIT_WIDTH-1:0] dis2rob_dis_fire, pmu_slot_valid_vec;  // dispatch slots = DECODE_WIDTH = COMMIT_WIDTH
  logic pmu_slot_valid [COMMIT_WIDTH];
  always_comb begin
    for (int i = 0; i < COMMIT_WIDTH; i++) pmu_slot_valid_vec[i] = pmu_slot_valid[i];
  end
  /* verilator lint_off UNUSEDSIGNAL */  // read by the testbench only
  logic [pmu_ev_pkg::PMU_NUM_EV-1:0][pmu_ev_pkg::PMU_INC_W-1:0] pmu_ev_inc;
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- nets between the glue blocks and the back end ----
  logic        out_rf_valid;
  logic [FTB_BLK_ID_W-1:0] out_rf_blk;
  logic [2:0]  out_rf_type;
  logic [XLEN_BITS-1:0] out_rf_pc;
  logic        out_rf_is_rvc;
  logic [31:0]                    front2ftq_inst [BACKEND_FETCH_WIDTH];
  logic [BACKEND_FETCH_WIDTH-1:0] front2ftq_page_fault_inst;
  logic [BACKEND_FETCH_WIDTH-1:0] front2ftq_pf_inst_hi;
  logic [BACKEND_FETCH_WIDTH-1:0] front2ftq_valid;
  logic [FTQ_IDX_WIDTH-1:0]       front2ftq_ftq_idx;
  ftq_fe_view_t                   ftq2fe;
  fe_ftq_s0_t                     fe2ftq_s0;
  fe_ftq_s2_t                     fe2ftq_s2;
  fe_ftq_pd_t                     fe2ftq_pd;
  logic [3:0] commit_upd_free, commit_tq_free;   // BPU queue free entries -> ROB commit credits (EXP-028)
  logic [COMMIT_WIDTH-1:0] commit_extra_is_ret;
  logic [XLEN_BITS-1:0] csr_status_mstatus;
  logic [1:0] csr_status_privilege;
  logic [XLEN_BITS-1:0] csr_status_satp;
  logic [COMMIT_WIDTH-1:0] ftq_commit_info_resp_alt_pred;
  logic [2:0] ftq_commit_info_resp_pcpn [COMMIT_WIDTH];
  logic ftq_commit_info_resp_pred_taken [COMMIT_WIDTH];
  logic ftq_commit_info_resp_is_rvc [COMMIT_WIDTH];
  logic [FTB_BLK_ID_W-1:0] ftq_commit_info_resp_blk_id [COMMIT_WIDTH];
  logic out_stall;

  pmu_ev_core #(.COMMIT_W(COMMIT_WIDTH)) u_pmu_ev (
    .commit_valid(rob_commit_commit_entry_valid), .commit_type(rob_commit_commit_entry_uop_type),
    .interrupt(rob_bcast_interrupt), .flush(rob_bcast_flush), .exception(rob_bcast_exception),
    .redirect(out_mispred), .slot_valid(pmu_slot_valid_vec), .slot_fire(dis2rob_dis_fire),
    .clk(clk), .rst_n(rst_n), .ev_inc(pmu_ev_inc));

  // ---- back end (outputs nobody in the core needs are not connected) ----
  /* verilator lint_off PINMISSING */
  back_top u_back (
    .clk, .rst_n,
    .out_rf_valid(out_rf_valid),
    .out_rf_blk(out_rf_blk),
    .out_rf_type(out_rf_type),
    .out_rf_pc(out_rf_pc),
    .out_rf_is_rvc(out_rf_is_rvc),
    .front2ftq_inst(front2ftq_inst),
    .front2ftq_page_fault_inst(front2ftq_page_fault_inst),
    .front2ftq_pf_inst_hi(front2ftq_pf_inst_hi),
    .front2ftq_valid(front2ftq_valid),
    .front2ftq_ftq_idx(front2ftq_ftq_idx),
    .fe2ftq_s0(fe2ftq_s0),
    .fe2ftq_s2(fe2ftq_s2),
    .fe2ftq_pd(fe2ftq_pd),
    .ftq2fe(ftq2fe),
    .front_stall(1'b0),
    .bpu_upd_free(commit_upd_free),
    .bpu_tq_free(commit_tq_free),
    .dcache2lsu_load_resps_data(dcache2lsu_load_resps_data),
    .dcache2lsu_load_resps_replay(dcache2lsu_load_resps_replay),
    .dcache2lsu_load_resps_req_id(dcache2lsu_load_resps_req_id),
    .dcache2lsu_load_resps_valid(dcache2lsu_load_resps_valid),
    .dcache2lsu_load_retry_busy(dcache2lsu_load_retry_busy),
    .dcache2lsu_store_retry_busy(dcache2lsu_store_retry_busy),
    .dcache2lsu_mshr_fill(dcache2lsu_mshr_fill),
    .dcache2lsu_mshr_fill_line(dcache2lsu_mshr_fill_line),
    .dcache2lsu_store_resps_replay(dcache2lsu_store_resps_replay),
    .dcache2lsu_store_resps_req_id(dcache2lsu_store_resps_req_id),
    .dcache2lsu_store_resps_valid(dcache2lsu_store_resps_valid),
    .interrupt_inject_external_irq_pending(interrupt_inject_external_irq_pending),
    .interrupt_inject_external_irq_pending_valid(interrupt_inject_external_irq_pending_valid),
    .interrupt_inject_supervisor_external_irq_pending(interrupt_inject_supervisor_external_irq_pending),
    .interrupt_inject_supervisor_external_irq_pending_valid(interrupt_inject_supervisor_external_irq_pending_valid),
    .interrupt_inject_timer_irq_pending(interrupt_inject_timer_irq_pending),
    .interrupt_inject_timer_irq_pending_valid(interrupt_inject_timer_irq_pending_valid),
    .peripheral_resp_is_mmio(peripheral_resp_is_mmio),
    .peripheral_resp_mmio_rdata(peripheral_resp_mmio_rdata),
    .peripheral_resp_ready(peripheral_resp_ready),
    .ptw_walk_req_ready(dtlb_walk_req_ready),
    .ptw_walk_resp_fault(dtlb_walk_resp_fault),
    .ptw_walk_resp_leaf_level(dtlb_walk_resp_leaf_level),
    .ptw_walk_resp_leaf_perm(dtlb_walk_resp_leaf_perm),
    .ptw_walk_resp_leaf_ppn(dtlb_walk_resp_leaf_ppn),
    .ptw_walk_resp_valid(dtlb_walk_resp_valid),
    .ptw_walk_resp_vpn(dtlb_walk_resp_vpn),
    .commit_extra_is_ret(commit_extra_is_ret),
    .csr_status_mstatus(csr_status_mstatus),
    .csr_status_privilege(csr_status_privilege),
    .csr_status_satp(csr_status_satp),
    .ftq_commit_info_resp_alt_pred(ftq_commit_info_resp_alt_pred),
    .ftq_commit_info_resp_pc(ftq_commit_info_resp_pc),
    .ftq_commit_info_resp_pcpn(ftq_commit_info_resp_pcpn),
    .ftq_commit_info_resp_pred_taken(ftq_commit_info_resp_pred_taken),
    .ftq_commit_info_resp_is_rvc(ftq_commit_info_resp_is_rvc),
    .ftq_commit_info_resp_blk_id(ftq_commit_info_resp_blk_id),
    .out_commit_entry_uop_diag_val(out_commit_entry_uop_diag_val),
    .out_mispred(out_mispred),
    .out_redirect_pc(out_redirect_pc),
    .out_stall(out_stall),
    .lsu2dcache_load_ports_addr(lsu2dcache_load_ports_addr),
    .lsu2dcache_load_ports_req_id(lsu2dcache_load_ports_req_id),
    .lsu2dcache_load_ports_replay(lsu2dcache_load_ports_replay),
    .lsu2dcache_load_ports_pc(lsu2dcache_load_ports_pc),
    .lsu2dcache_load_ports_va(lsu2dcache_load_ports_va),
    .pf_xq_v, .pf_xq_va, .pf_xq_llc, .pf_xq_pop, .pf_xans_v, .pf_xans_line, .pf_xans_llc,
    .lsu2dcache_load_ports_valid(lsu2dcache_load_ports_valid),
    .lsu2dcache_store_ports_addr(lsu2dcache_store_ports_addr),
    .lsu2dcache_store_ports_data(lsu2dcache_store_ports_data),
    .lsu2dcache_store_ports_req_id(lsu2dcache_store_ports_req_id),
    .lsu2dcache_store_ports_strb(lsu2dcache_store_ports_strb),
    .lsu2dcache_store_ports_l2(lsu2dcache_store_ports_l2),
    .lsu2dcache_store_ports_valid(lsu2dcache_store_ports_valid),
    .peripheral_req_is_mmio(peripheral_req_is_mmio),
    .peripheral_req_mmio_addr(peripheral_req_mmio_addr),
    .peripheral_req_mmio_fun3(peripheral_req_mmio_fun3),
    .peripheral_req_mmio_wdata(peripheral_req_mmio_wdata),
    .peripheral_req_wen(peripheral_req_wen),
    .ptw_walk_flush(dtlb_walk_flush),
    .ptw_walk_req_root_ppn(dtlb_walk_req_root_ppn),
    .ptw_walk_req_valid(dtlb_walk_req_valid),
    .ptw_walk_req_vpn(dtlb_walk_req_vpn),
    .ptw_walk_resp_consumed(dtlb_walk_resp_consumed),
    .rob_bcast_exception(rob_bcast_exception),
    .rob_bcast_fence(rob_bcast_fence),
    .rob_bcast_fence_i(rob_bcast_fence_i),
    .rob_bcast_flush(rob_bcast_flush),
    .rob_bcast_interrupt(rob_bcast_interrupt),
    .dis2rob_dis_fire(dis2rob_dis_fire),
    .pmu_slot_valid(pmu_slot_valid),
    .rob_bcast_mret(rob_bcast_mret),
    .rob_bcast_pc(rob_bcast_pc),
    .rob_bcast_sret(rob_bcast_sret),
    .rob_commit_commit_entry_uop_br_taken(rob_commit_commit_entry_uop_br_taken),
    .rob_commit_commit_entry_uop_dest_areg(rob_commit_commit_entry_uop_dest_areg),
    .rob_commit_commit_entry_uop_dest_en(rob_commit_commit_entry_uop_dest_en),
    .rob_commit_commit_entry_uop_page_fault_inst(rob_commit_commit_entry_uop_page_fault_inst),
    .rob_commit_commit_entry_uop_page_fault_load(rob_commit_commit_entry_uop_page_fault_load),
    .rob_commit_commit_entry_uop_page_fault_store(rob_commit_commit_entry_uop_page_fault_store),
    .rob_commit_commit_entry_uop_rob_flag(rob_commit_commit_entry_uop_rob_flag),
    .rob_commit_commit_entry_uop_rob_idx(rob_commit_commit_entry_uop_rob_idx),
    .rob_commit_commit_entry_uop_stq_flag(rob_commit_commit_entry_uop_stq_flag),
    .rob_commit_commit_entry_uop_stq_idx(rob_commit_commit_entry_uop_stq_idx),
    .rob_commit_commit_entry_uop_type(rob_commit_commit_entry_uop_type),
    .rob_commit_commit_entry_valid(rob_commit_commit_entry_valid)
  );
  /* verilator lint_on PINMISSING */

  core_front u_front (
    .clk, .rst_n,
    .out_mispred,
    .out_rf_valid,
    .out_rf_blk,
    .out_rf_type,
    .out_rf_pc,
    .out_rf_is_rvc,
    .out_stall,
    .out_redirect_pc,
    .ftq2fe,
    .rob_bcast_fence,
    .rob_bcast_fence_i,
    .rob_bcast_interrupt,
    .rob_commit_commit_entry_valid,
    .rob_commit_commit_entry_uop_type,
    .rob_commit_commit_entry_uop_br_taken,
    .rob_commit_commit_entry_uop_dest_en,
    .rob_commit_commit_entry_uop_dest_areg,
    .out_commit_entry_uop_diag_val,
    .commit_extra_is_ret,
    .ftq_commit_info_resp_pc,
    .ftq_commit_info_resp_pred_taken,
    .ftq_commit_info_resp_is_rvc,
    .ftq_commit_info_resp_alt_pred,
    .ftq_commit_info_resp_pcpn,
    .ftq_commit_info_resp_blk_id,
    .csr_status_satp,
    .csr_status_privilege,
    .csr_status_mstatus,
    .mem_req_ready,
    .mem_req_accepted,
    .mem_req_accepted_id,
    .mem_resp_valid,
    .mem_resp_id,
    .mem_resp_data,
    .dc_resp_valid,
    .dc_resp_retry,
    .dc_resp_miss,
    .dc_resp_data,
    .itlb_walk_req_ready,
    .itlb_walk_resp_valid,
    .itlb_walk_resp_fault,
    .itlb_walk_resp_vpn,
    .itlb_walk_resp_leaf_ppn,
    .itlb_walk_resp_leaf_perm,
    .itlb_walk_resp_leaf_level,
    .mem_req_valid,
    .mem_req_addr,
    .mem_req_total_size,
    .mem_req_bypass,
    .mem_req_id,
    .mem_resp_ready,
    .dc_req_valid,
    .dc_req_addr,
    .itlb_walk_req_valid,
    .itlb_walk_req_vpn,
    .itlb_walk_req_root_ppn,
    .itlb_walk_resp_consumed,
    .itlb_walk_flush,
    .front2ftq_valid,
    .front2ftq_inst,
    .front2ftq_page_fault_inst,
    .front2ftq_pf_inst_hi,
    .front2ftq_ftq_idx,
    .fe2ftq_s0,
    .fe2ftq_s2,
    .fe2ftq_pd,
    .commit_upd_free,
    .commit_tq_free
  );

endmodule

`default_nettype wire
