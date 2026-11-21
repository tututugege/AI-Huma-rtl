// Ref: rv_simu_mmu_v2.cpp  SimCpu::cycle / front_comb_before_back / back2front_comb (the front-end half)
`default_nettype none

// Front end with its SimCpu glue: front_top, the registered back2front bundle (core_back2front) and the front->back
// conversion with the stall hold register (core_front2back).  Inputs are what the back end produced this cycle, outputs
// are the 16-lane group the back end sees (back.in) plus the front end's memory-side ports.
module core_front import ttg_cfg_pkg::*; import front_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*;
  import bpu_types_pkg::FTB_BLK_ID_W; import icache_pkg::*; import tlb_mmu_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  // ---- from the back end (cycle t) ----
  input  logic        out_mispred,
  input  logic        out_rf_valid,
  input  logic [FTB_BLK_ID_W-1:0] out_rf_blk,
  input  logic [2:0]  out_rf_type,
  input  logic [XLEN_BITS-1:0] out_rf_pc,
  input  logic out_rf_is_rvc,
  output logic [FETCH_WIDTH-1:0][KIND_W-1:0] front2pre_slot_kind,
  input  logic        out_stall,
  input  logic [XLEN_BITS-1:0] out_redirect_pc,
  input  logic        rob_bcast_fence,
  input  logic        rob_bcast_fence_i,
  input  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_valid,
  input  logic [4:0]  rob_commit_commit_entry_uop_type [COMMIT_WIDTH],
  input  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_br_taken,
  input  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_dest_en,
  input  logic [5:0]  rob_commit_commit_entry_uop_dest_areg [COMMIT_WIDTH],
  input  logic [XLEN_BITS-1:0] out_commit_entry_uop_diag_val [COMMIT_WIDTH],
  input  logic [31:0] commit_extra_imm [COMMIT_WIDTH],
  input  logic [5:0]  commit_extra_src1_areg [COMMIT_WIDTH],
  input  logic [XLEN_BITS-1:0] ftq_commit_info_resp_pc [COMMIT_WIDTH],
  input  logic        ftq_commit_info_resp_pred_taken [COMMIT_WIDTH],
  input  logic        ftq_commit_info_resp_is_rvc [COMMIT_WIDTH],
  input  logic [COMMIT_WIDTH-1:0] ftq_commit_info_resp_alt_pred,
  input  logic [2:0]  ftq_commit_info_resp_pcpn [COMMIT_WIDTH],
  input  logic [FTB_BLK_ID_W-1:0] ftq_commit_info_resp_blk_id [COMMIT_WIDTH],
  input  logic [XLEN_BITS-1:0] csr_status_satp,
  input  logic [1:0]  csr_status_privilege,
  /* verilator lint_off UNUSEDSIGNAL */   // only the mxr / sum / mprv / mpp bits go to the ITLB
  input  logic [XLEN_BITS-1:0] csr_status_mstatus,
  /* verilator lint_on UNUSEDSIGNAL */
  // ---- memory side of the front end ----
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
  input  logic        itlb_walk_req_ready,
  input  logic        itlb_walk_resp_valid,
  input  logic        itlb_walk_resp_fault,
  input  logic [VPN_W-1:0]  itlb_walk_resp_vpn,
  input  logic [PPN_W-1:0]  itlb_walk_resp_leaf_ppn,
  input  logic [PERM_W-1:0] itlb_walk_resp_leaf_perm,
  input  logic [LVL_W-1:0]        itlb_walk_resp_leaf_level,
  output logic        mem_req_valid,
  output logic [31:0] mem_req_addr,
  output logic [7:0]  mem_req_total_size,
  output logic        mem_req_bypass,
  output logic [3:0]  mem_req_id,
  output logic        mem_resp_ready,
  output logic        dc_req_valid,
  output logic [31:0] dc_req_addr,
  output logic        itlb_walk_req_valid,
  output logic [VPN_W-1:0] itlb_walk_req_vpn,
  output logic [21:0] itlb_walk_req_root_ppn,
  output logic        itlb_walk_resp_consumed,
  output logic        itlb_walk_flush,
  // ---- to the back end (back.in, SC-L / loop metadata are constant 0 and added by the core) ----
  output logic [BACKEND_FETCH_WIDTH-1:0] front2pre_valid,
  output logic [31:0] front2pre_inst [BACKEND_FETCH_WIDTH],
  output logic [BACKEND_FETCH_WIDTH-1:0] front2pre_page_fault_inst,
  output logic [BACKEND_FETCH_WIDTH-1:0] front2pre_pf_inst_hi,
  output logic [XLEN_BITS-1:0] front2pre_pc [BACKEND_FETCH_WIDTH],
  output logic [BACKEND_FETCH_WIDTH-1:0] front2pre_predict_dir,
  output logic [BACKEND_FETCH_WIDTH-1:0] front2pre_is_rvc,
  output logic [BACKEND_FETCH_WIDTH-1:0] front2pre_alt_pred,
  output logic [front_pkg::PCPN_W-1:0]     front2pre_pcpn [BACKEND_FETCH_WIDTH],
  output logic [BLK_ID_W-1:0] front2pre_blk_id,
  output logic                front2pre_is_pair,
  output logic [3:0]          front2pre_a_len,
  output logic [XLEN_BITS-1:0] front2pre_predict_next_fetch_address,
  output logic [3:0]  commit_upd_free,   // compact ROB commit credits (EXP-028)
  output logic [3:0]  commit_tq_free
);

  // ---- back end -> front end: registered back2front ----
  logic        b2f_refetch, b2f_itlb_flush, b2f_fence_i, b2f_stall;
  logic [XLEN_BITS-1:0] b2f_refetch_address;
  logic        b2f_rf_valid;
  logic [FTB_BLK_ID_W-1:0] b2f_rf_blk;
  logic [2:0]  b2f_rf_type;
  logic [XLEN_BITS-1:0] b2f_rf_pc;
  logic b2f_rf_is_rvc;
  logic [COMMIT_WIDTH-1:0] upd_valid;
  logic [XLEN_BITS-1:0] upd_base_pc  [COMMIT_WIDTH];
  logic [COMMIT_WIDTH-1:0] upd_actual_dir;
  logic [COMMIT_WIDTH-1:0] upd_is_rvc;
  logic [2:0]  upd_br_type  [COMMIT_WIDTH];
  logic [XLEN_BITS-1:0] upd_target   [COMMIT_WIDTH];
  logic [COMMIT_WIDTH-1:0] upd_pred_dir;
  logic [COMMIT_WIDTH-1:0] upd_alt_pred;
  logic [2:0]  upd_pcpn     [COMMIT_WIDTH];
  logic [FTB_BLK_ID_W-1:0] upd_blk_id [COMMIT_WIDTH];

  core_back2front u_b2f (
    .clk, .rst_n,
    .out_mispred             (out_mispred),
    .out_stall               (out_stall),
    .out_redirect_pc         (out_redirect_pc),
    .out_rf_valid, .out_rf_blk, .out_rf_type, .out_rf_pc, .out_rf_is_rvc,
    .rob_bcast_fence         (rob_bcast_fence),
    .rob_bcast_fence_i       (rob_bcast_fence_i),
    .commit_valid            (rob_commit_commit_entry_valid),
    .commit_type             (rob_commit_commit_entry_uop_type),
    .commit_br_taken         (rob_commit_commit_entry_uop_br_taken),
    .commit_dest_en          (rob_commit_commit_entry_uop_dest_en),
    .commit_dest_areg        (rob_commit_commit_entry_uop_dest_areg),
    .commit_diag_val         (out_commit_entry_uop_diag_val),
    .commit_imm              (commit_extra_imm),
    .commit_src1_areg        (commit_extra_src1_areg),
    .ftq_pc                  (ftq_commit_info_resp_pc),
    .ftq_pred_taken          (ftq_commit_info_resp_pred_taken),
    .ftq_is_rvc          (ftq_commit_info_resp_is_rvc),
    .ftq_alt_pred            (ftq_commit_info_resp_alt_pred),
    .ftq_pcpn                (ftq_commit_info_resp_pcpn),
    .ftq_blk_id              (ftq_commit_info_resp_blk_id),
    .refetch_q               (b2f_refetch),
    .refetch_address_q       (b2f_refetch_address),
    .rf_valid_q              (b2f_rf_valid),
    .rf_blk_q                (b2f_rf_blk),
    .rf_type_q               (b2f_rf_type),
    .rf_pc_q                 (b2f_rf_pc),
    .rf_is_rvc_q             (b2f_rf_is_rvc),
    .itlb_flush_q            (b2f_itlb_flush),
    .fence_i_q               (b2f_fence_i),
    .stall_q                 (b2f_stall),
    .upd_valid_q             (upd_valid),
    .upd_base_pc_q           (upd_base_pc),
    .upd_actual_dir_q        (upd_actual_dir),
    .upd_is_rvc_q            (upd_is_rvc),
    .upd_br_type_q           (upd_br_type),
    .upd_target_q            (upd_target),
    .upd_pred_dir_q          (upd_pred_dir),
    .upd_alt_pred_q          (upd_alt_pred),
    .upd_pcpn_q              (upd_pcpn),
    .upd_blk_id_q            (upd_blk_id)
  );

  // ---- front end ----
  // Delivers when the back end did not stall last cycle or a redirect is pending (SimCpu::front_comb_before_back)
  logic can_read;
  assign can_read = !b2f_stall || b2f_refetch;

  logic        fe_out_valid;
  logic [FETCH_WIDTH-1:0] fe_lane_valid;
  logic [31:0] fe_instructions    [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] fe_page_fault_inst;
  logic [FETCH_WIDTH-1:0] fe_pf_inst_hi;
  logic [FETCH_WIDTH-1:0] fe_predict_dir;
  logic [FETCH_WIDTH-1:0] fe_is_rvc;   // 16-bit instruction (RVC=1)
  logic [XLEN_BITS-1:0] fe_pc              [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] fe_alt_pred;
  logic [front_pkg::PCPN_W-1:0]     fe_pcpn    [FETCH_WIDTH];
  logic [BLK_ID_W-1:0] fe_blk_id;
  logic                fe_is_pair;
  logic [3:0]          fe_a_len;
  logic [XLEN_BITS-1:0] fe_predict_next_fetch_address;
  logic [FETCH_WIDTH-1:0][KIND_W-1:0] fe_slot_kind;

  front_top u_front (
    .clk, .rst_n,
    .be_refetch                 (b2f_refetch),
    .be_refetch_address         (b2f_refetch_address),
    .be_rf_valid                (b2f_rf_valid),
    .be_rf_blk                  (b2f_rf_blk),
    .be_rf_type                 (b2f_rf_type),
    .be_rf_pc                   (b2f_rf_pc),
    .be_rf_is_rvc               (b2f_rf_is_rvc),
    .itlb_flush                 (b2f_itlb_flush),
    .fence_i                    (b2f_fence_i),
    .fifo_read_enable           (can_read),
    .csr_status_satp            (csr_status_satp),
    .csr_status_privilege       (csr_status_privilege),
    .csr_status_mstatus_mxr     (csr_status_mstatus[19]),
    .csr_status_mstatus_sum     (csr_status_mstatus[18]),
    .csr_status_mstatus_mprv    (csr_status_mstatus[17]),
    .csr_status_mstatus_mpp     (csr_status_mstatus[12:11]),
    .upd_valid                  (upd_valid),
    .base_pc                    (upd_base_pc),
    .actual_dir                 (upd_actual_dir),
    .upd_is_rvc                 (upd_is_rvc),
    .br_type                    (upd_br_type),
    .target                     (upd_target),
    .pred_dir                   (upd_pred_dir),
    .alt_pred                   (upd_alt_pred),
    .pcpn                       (upd_pcpn),
    .blk_id                     (upd_blk_id),
    .mem_req_ready, .mem_req_accepted, .mem_req_accepted_id, .mem_resp_valid, .mem_resp_id, .mem_resp_data,
    .dc_resp_valid, .dc_resp_retry, .dc_resp_miss, .dc_resp_data,
    .ptw_walk_req_ready         (itlb_walk_req_ready),
    .ptw_walk_resp_valid        (itlb_walk_resp_valid),
    .ptw_walk_resp_fault        (itlb_walk_resp_fault),
    .ptw_walk_resp_vpn          (itlb_walk_resp_vpn),
    .ptw_walk_resp_leaf_ppn     (itlb_walk_resp_leaf_ppn),
    .ptw_walk_resp_leaf_perm    (itlb_walk_resp_leaf_perm),
    .ptw_walk_resp_leaf_level   (itlb_walk_resp_leaf_level),
    .out_valid                  (fe_out_valid),
    .out_lane_valid             (fe_lane_valid),
    .out_instructions           (fe_instructions),
    .out_page_fault_inst        (fe_page_fault_inst),
    .out_pf_inst_hi             (fe_pf_inst_hi),
    .out_predict_dir            (fe_predict_dir),
    .out_pc                     (fe_pc),
    .out_alt_pred               (fe_alt_pred),
    .out_pcpn                   (fe_pcpn),
    .out_blk_id                 (fe_blk_id),
    .out_is_pair                (fe_is_pair),
    .out_a_len                  (fe_a_len),
    .out_predict_next_fetch_address (fe_predict_next_fetch_address),
    .out_slot_kind              (fe_slot_kind),
    .out_is_rvc                 (fe_is_rvc),
    .mem_req_valid, .mem_req_addr, .mem_req_total_size, .mem_req_bypass, .mem_req_id, .mem_resp_ready,
    .dc_req_valid, .dc_req_addr,
    .ptw_walk_req_valid         (itlb_walk_req_valid),
    .ptw_walk_req_vpn           (itlb_walk_req_vpn),
    .ptw_walk_req_root_ppn      (itlb_walk_req_root_ppn),
    .ptw_walk_resp_consumed     (itlb_walk_resp_consumed),
    .ptw_walk_flush             (itlb_walk_flush),
    .commit_upd_free, .commit_tq_free
  );

  // ---- front end -> back end ----
  core_front2back u_f2b (
    .clk, .rst_n,
    .can_read,
    .lane_valid                  (fe_lane_valid),
    .instructions                (fe_instructions),
    .page_fault_inst             (fe_page_fault_inst),
    .pf_inst_hi                  (fe_pf_inst_hi),
    .predict_dir                 (fe_predict_dir),
    .is_rvc                      (fe_is_rvc),
    .pc                          (fe_pc),
    .alt_pred                    (fe_alt_pred),
    .pcpn                        (fe_pcpn),
    .blk_id                      (fe_blk_id),
    .is_pair                     (fe_is_pair),
    .a_len                       (fe_a_len),
    .predict_next_fetch_address  (fe_predict_next_fetch_address),
    .slot_kind                   (fe_slot_kind),
    .back_valid                  (front2pre_valid),
    .back_inst                   (front2pre_inst),
    .back_page_fault             (front2pre_page_fault_inst),
    .back_pf_inst_hi             (front2pre_pf_inst_hi),
    .back_pc                     (front2pre_pc),
    .back_predict_dir            (front2pre_predict_dir),
    .back_is_rvc                 (front2pre_is_rvc),
    .back_alt_pred               (front2pre_alt_pred),
    .back_pcpn                   (front2pre_pcpn),
    .back_blk_id                 (front2pre_blk_id),
    .back_is_pair                (front2pre_is_pair),
    .back_a_len                  (front2pre_a_len),
    .back_predict_next_fetch_address (front2pre_predict_next_fetch_address),
    .back_slot_kind              (front2pre_slot_kind)
  );

  // the group-level valid of front.out is implied by the lane valids
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = fe_out_valid;
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
