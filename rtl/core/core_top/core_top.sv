// Ref: rv_simu_mmu_v2.cpp  SimCpu::cycle (front end + back end + the registers between them); BackTop; FrontTop
`default_nettype none

// Core without the memory subsystem: front_top + back_top + the SimCpu glue between them (core_front).
//   core_back2front : back2front register (redirect, fence flushes, stall, BPU training data), one cycle late
//   core_front2back : front.out -> back.in (no-taken cut, 8->16 lane widening, stall hold register)
// Boundary = everything outside the core: the icache AXI read master / DCache probe / ITLB walk client, the LSU's
// DCache / MMIO / DTLB walk ports, interrupt injection; plus the retirement stream (rob_commit / rob_bcast).
// Order of SimCpu::cycle(): registered back2front -> front comb -> back comb -> back2front / hold registers.
module core_top import ttg_cfg_pkg::*; import front_pkg::*; import bpu_pkg::*; import icache_pkg::*;
  import tlb_mmu_pkg::*; (
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
  input  logic itlb_walk_resp_leaf_level,
  input  logic dtlb_walk_req_ready,
  input  logic dtlb_walk_resp_valid,
  input  logic dtlb_walk_resp_fault,
  input  logic [VPN_W-1:0] dtlb_walk_resp_vpn,
  input  logic [PPN_W-1:0] dtlb_walk_resp_leaf_ppn,
  input  logic [PERM_W-1:0] dtlb_walk_resp_leaf_perm,
  input  logic dtlb_walk_resp_leaf_level,
  // ---- LSU <-> DCache / MMIO, interrupt injection ----
  input  logic [31:0] dcache2lsu_load_resps_data [LSU_LDU_COUNT],
  input  logic [1:0] dcache2lsu_load_resps_replay [LSU_LDU_COUNT],
  input  logic [31:0] dcache2lsu_load_resps_req_id [LSU_LDU_COUNT],
  input  logic dcache2lsu_load_resps_valid [LSU_LDU_COUNT],
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
  input  logic [31:0] peripheral_resp_mmio_rdata,
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
  output logic [19:0] dtlb_walk_req_vpn,
  output logic dtlb_walk_resp_consumed,
  output logic [31:0] ftq_commit_info_resp_pc [COMMIT_WIDTH],
  output logic [31:0] out_commit_entry_uop_diag_val [COMMIT_WIDTH],
  output logic out_mispred,
  output logic [31:0] out_redirect_pc,
  output logic [31:0] lsu2dcache_load_ports_addr [LSU_LDU_COUNT],
  output logic [30:0] lsu2dcache_load_ports_req_id [LSU_LDU_COUNT],
  output logic lsu2dcache_load_ports_replay [LSU_LDU_COUNT],
  output logic lsu2dcache_load_ports_valid [LSU_LDU_COUNT],
  output logic [31:0] lsu2dcache_store_ports_addr [LSU_STA_COUNT],
  output logic [31:0] lsu2dcache_store_ports_data [LSU_STA_COUNT],
  output logic [5:0] lsu2dcache_store_ports_req_id [LSU_STA_COUNT],
  output logic [4:0] lsu2dcache_store_ports_strb [LSU_STA_COUNT],
  output logic lsu2dcache_store_ports_valid [LSU_STA_COUNT],
  output logic peripheral_req_is_mmio,
  output logic [31:0] peripheral_req_mmio_addr,
  output logic [2:0] peripheral_req_mmio_fun3,
  output logic [31:0] peripheral_req_mmio_wdata,
  output logic peripheral_req_wen,
  output logic rob_bcast_exception,
  output logic rob_bcast_fence,
  output logic rob_bcast_fence_i,
  output logic rob_bcast_flush,
  output logic rob_bcast_mret,
  output logic [31:0] rob_bcast_pc,
  output logic rob_bcast_sret,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_br_taken,
  output logic [5:0] rob_commit_commit_entry_uop_dest_areg [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_dest_en,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_page_fault_inst,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_page_fault_load,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_page_fault_store,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_rob_flag,
  output logic [6:0] rob_commit_commit_entry_uop_rob_idx [COMMIT_WIDTH],
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
  logic [BACKEND_FETCH_WIDTH-1:0] front2pre_alt_pred;
  logic [2:0] front2pre_altpcpn [BACKEND_FETCH_WIDTH];
  logic [31:0] front2pre_inst [BACKEND_FETCH_WIDTH];
  logic [BACKEND_FETCH_WIDTH-1:0] front2pre_page_fault_inst;
  logic [31:0] front2pre_pc [BACKEND_FETCH_WIDTH];
  logic [2:0] front2pre_pcpn [BACKEND_FETCH_WIDTH];
  logic [BACKEND_FETCH_WIDTH-1:0] front2pre_predict_dir;
  logic [31:0] front2pre_predict_next_fetch_address;
  logic [9:0] front2pre_tage_idx [BACKEND_FETCH_WIDTH][4];
  logic [7:0] front2pre_tage_tag [BACKEND_FETCH_WIDTH][4];
  logic [BACKEND_FETCH_WIDTH-1:0] front2pre_valid;
  logic [31:0] commit_extra_imm [COMMIT_WIDTH];
  logic [5:0] commit_extra_src1_areg [COMMIT_WIDTH];
  logic [31:0] csr_status_mstatus;
  logic [1:0] csr_status_privilege;
  logic [31:0] csr_status_satp;
  logic [COMMIT_WIDTH-1:0] ftq_commit_info_resp_alt_pred;
  logic [2:0] ftq_commit_info_resp_altpcpn [COMMIT_WIDTH];
  logic [2:0] ftq_commit_info_resp_pcpn [COMMIT_WIDTH];
  logic ftq_commit_info_resp_pred_taken [COMMIT_WIDTH];
  logic [9:0] ftq_commit_info_resp_tage_idx [COMMIT_WIDTH][4];
  logic [7:0] ftq_commit_info_resp_tage_tag [COMMIT_WIDTH][4];
  logic out_stall;

  // SC-L / loop predictor metadata of the front-to-back path and the update-queue stall are constant 0 (see front_top)
  always_comb begin
  end

  pmu_ev_core #(.COMMIT_W(COMMIT_WIDTH)) u_pmu_ev (
    .commit_valid(rob_commit_commit_entry_valid), .commit_type(rob_commit_commit_entry_uop_type),
    .interrupt(rob_bcast_interrupt), .flush(rob_bcast_flush), .exception(rob_bcast_exception),
    .redirect(out_mispred), .slot_valid(pmu_slot_valid_vec), .slot_fire(dis2rob_dis_fire),
    .clk(clk), .rst_n(rst_n), .ev_inc(pmu_ev_inc));

  // ---- back end (outputs nobody in the core needs are not connected) ----
  /* verilator lint_off PINMISSING */
  back_top u_back (
    .clk, .rst_n,
    .front2pre_alt_pred(front2pre_alt_pred),
    .front2pre_altpcpn(front2pre_altpcpn),
    .front2pre_inst(front2pre_inst),
    .front2pre_page_fault_inst(front2pre_page_fault_inst),
    .front2pre_pc(front2pre_pc),
    .front2pre_pcpn(front2pre_pcpn),
    .front2pre_predict_dir(front2pre_predict_dir),
    .front2pre_predict_next_fetch_address(front2pre_predict_next_fetch_address),
    .front2pre_tage_idx(front2pre_tage_idx),
    .front2pre_tage_tag(front2pre_tage_tag),
    .front2pre_valid(front2pre_valid),
    .front_stall(1'b0),
    .dcache2lsu_load_resps_data(dcache2lsu_load_resps_data),
    .dcache2lsu_load_resps_replay(dcache2lsu_load_resps_replay),
    .dcache2lsu_load_resps_req_id(dcache2lsu_load_resps_req_id),
    .dcache2lsu_load_resps_valid(dcache2lsu_load_resps_valid),
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
    .commit_extra_imm(commit_extra_imm),
    .commit_extra_src1_areg(commit_extra_src1_areg),
    .csr_status_mstatus(csr_status_mstatus),
    .csr_status_privilege(csr_status_privilege),
    .csr_status_satp(csr_status_satp),
    .ftq_commit_info_resp_alt_pred(ftq_commit_info_resp_alt_pred),
    .ftq_commit_info_resp_altpcpn(ftq_commit_info_resp_altpcpn),
    .ftq_commit_info_resp_pc(ftq_commit_info_resp_pc),
    .ftq_commit_info_resp_pcpn(ftq_commit_info_resp_pcpn),
    .ftq_commit_info_resp_pred_taken(ftq_commit_info_resp_pred_taken),
    .ftq_commit_info_resp_tage_idx(ftq_commit_info_resp_tage_idx),
    .ftq_commit_info_resp_tage_tag(ftq_commit_info_resp_tage_tag),
    .out_commit_entry_uop_diag_val(out_commit_entry_uop_diag_val),
    .out_mispred(out_mispred),
    .out_redirect_pc(out_redirect_pc),
    .out_stall(out_stall),
    .lsu2dcache_load_ports_addr(lsu2dcache_load_ports_addr),
    .lsu2dcache_load_ports_req_id(lsu2dcache_load_ports_req_id),
    .lsu2dcache_load_ports_replay(lsu2dcache_load_ports_replay),
    .lsu2dcache_load_ports_valid(lsu2dcache_load_ports_valid),
    .lsu2dcache_store_ports_addr(lsu2dcache_store_ports_addr),
    .lsu2dcache_store_ports_data(lsu2dcache_store_ports_data),
    .lsu2dcache_store_ports_req_id(lsu2dcache_store_ports_req_id),
    .lsu2dcache_store_ports_strb(lsu2dcache_store_ports_strb),
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
    .out_stall,
    .out_redirect_pc,
    .rob_bcast_fence,
    .rob_bcast_fence_i,
    .rob_commit_commit_entry_valid,
    .rob_commit_commit_entry_uop_type,
    .rob_commit_commit_entry_uop_br_taken,
    .rob_commit_commit_entry_uop_dest_en,
    .rob_commit_commit_entry_uop_dest_areg,
    .out_commit_entry_uop_diag_val,
    .commit_extra_imm,
    .commit_extra_src1_areg,
    .ftq_commit_info_resp_pc,
    .ftq_commit_info_resp_pred_taken,
    .ftq_commit_info_resp_alt_pred,
    .ftq_commit_info_resp_altpcpn,
    .ftq_commit_info_resp_pcpn,
    .ftq_commit_info_resp_tage_idx,
    .ftq_commit_info_resp_tage_tag,
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
    .front2pre_valid,
    .front2pre_inst,
    .front2pre_page_fault_inst,
    .front2pre_pc,
    .front2pre_predict_dir,
    .front2pre_alt_pred,
    .front2pre_altpcpn,
    .front2pre_pcpn,
    .front2pre_tage_idx,
    .front2pre_tage_tag,
    .front2pre_predict_next_fetch_address
  );

endmodule

`default_nettype wire
