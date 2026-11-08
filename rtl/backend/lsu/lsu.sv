// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (LSU top: spec port adaptation, see spec/lsu.io)
`default_nettype none

module lsu
  import ttg_cfg_pkg::*;
  import lsu_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_valid,
  input  logic [4:0] rob_commit_commit_entry_uop_type [COMMIT_WIDTH],
  input  logic [4:0] rob_commit_commit_entry_uop_amo_op [COMMIT_WIDTH],
  input  logic [5:0] rob_commit_commit_entry_uop_stq_idx [COMMIT_WIDTH],
  input  logic rob_bcast_flush,
  input  logic rob_bcast_head_valid,
  input  logic [6:0] rob_bcast_head_rob_idx,
  input  logic rob_bcast_head_incomplete_valid,
  input  logic [6:0] rob_bcast_head_incomplete_rob_idx,
  input  logic dec_bcast_mispred,
  input  logic [BR_MASK_WIDTH-1:0] dec_bcast_br_mask,
  input  logic [BR_MASK_WIDTH-1:0] dec_bcast_clear_mask,
  input  logic [DECODE_WIDTH-1:0] dis2lsu_alloc_req,
  input  logic [BR_MASK_WIDTH-1:0] dis2lsu_br_mask [DECODE_WIDTH],
  input  logic [6:0] dis2lsu_rob_idx [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0] dis2lsu_rob_flag,
  input  logic [DECODE_WIDTH-1:0] dis2lsu_ldq_alloc_req,
  input  logic [5:0] dis2lsu_ldq_idx [DECODE_WIDTH],
  input  logic [BR_MASK_WIDTH-1:0] dis2lsu_ldq_br_mask [DECODE_WIDTH],
  input  logic [6:0] dis2lsu_ldq_rob_idx [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0] dis2lsu_ldq_rob_flag,
  input  logic [LSU_MDP_BITS-1:0] dis2lsu_ldq_mdp [DECODE_WIDTH],   // wait-table index of the load PC (LSU_MEMSPEC)
  input  logic [LSU_SDU_COUNT-1:0] exe2lsu_sdu_req_valid,
  input  logic [31:0] exe2lsu_sdu_req_uop_result [LSU_SDU_COUNT],
  input  logic [6:0] exe2lsu_sdu_req_uop_rob_idx [LSU_SDU_COUNT],
  input  logic [LSU_SDU_COUNT-1:0] exe2lsu_sdu_req_uop_rob_flag,
  input  logic [5:0] exe2lsu_sdu_req_uop_stq_idx [LSU_SDU_COUNT],
  input  logic [LSU_LDU_COUNT-1:0] exe2lsu_ldu_req_valid,
  input  logic [31:0] exe2lsu_ldu_req_uop_result [LSU_LDU_COUNT],
  input  logic [6:0] exe2lsu_ldu_req_uop_dest_preg [LSU_LDU_COUNT],
  input  logic [2:0] exe2lsu_ldu_req_uop_func3 [LSU_LDU_COUNT],
  input  logic [LSU_LDU_COUNT-1:0] exe2lsu_ldu_req_uop_is_atomic,
  input  logic [4:0] exe2lsu_ldu_req_uop_amo_op [LSU_LDU_COUNT],
  input  logic [6:0] exe2lsu_ldu_req_uop_rob_idx [LSU_LDU_COUNT],
  input  logic exe2lsu_ldu_req_uop_rob_flag [LSU_LDU_COUNT],
  input  logic [5:0] exe2lsu_ldu_req_uop_stq_idx [LSU_LDU_COUNT],
  input  logic exe2lsu_ldu_req_uop_stq_flag [LSU_LDU_COUNT],
  input  logic [5:0] exe2lsu_ldu_req_uop_ldq_idx [LSU_LDU_COUNT],
  input  logic [LSU_STA_COUNT-1:0] exe2lsu_sta_req_valid,
  input  logic [31:0] exe2lsu_sta_req_uop_result [LSU_STA_COUNT],
  input  logic [6:0] exe2lsu_sta_req_uop_dest_preg [LSU_STA_COUNT],
  input  logic [2:0] exe2lsu_sta_req_uop_func3 [LSU_STA_COUNT],
  input  logic [LSU_STA_COUNT-1:0] exe2lsu_sta_req_uop_is_atomic,
  input  logic [4:0] exe2lsu_sta_req_uop_amo_op [LSU_STA_COUNT],
  input  logic [6:0] exe2lsu_sta_req_uop_rob_idx [LSU_STA_COUNT],
  input  logic exe2lsu_sta_req_uop_rob_flag [LSU_STA_COUNT],
  input  logic [5:0] exe2lsu_sta_req_uop_stq_idx [LSU_STA_COUNT],
  input  logic peripheral_resp_is_mmio,
  input  logic peripheral_resp_ready,
  input  logic [31:0] peripheral_resp_mmio_rdata,
  input  logic dcache2lsu_load_resps_valid [LSU_LDU_COUNT],
  input  logic [31:0] dcache2lsu_load_resps_req_id [LSU_LDU_COUNT],
  input  logic [31:0] dcache2lsu_load_resps_data [LSU_LDU_COUNT],
  input  logic [1:0] dcache2lsu_load_resps_replay [LSU_LDU_COUNT],
  input  logic dcache2lsu_store_resps_valid [LSU_STA_COUNT],
  input  logic [31:0] dcache2lsu_store_resps_req_id [LSU_STA_COUNT],
  input  logic [1:0] dcache2lsu_store_resps_replay [LSU_STA_COUNT],
  input  logic dcache2lsu_mshr_fill,
  input  logic [25:0] dcache2lsu_mshr_fill_line,
  // hidden DCache bank-retry latches (registered bits); used by the staged LSU only (LSU_PIPE)
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic dcache2lsu_load_retry_busy [LSU_LDU_COUNT],
  input  logic dcache2lsu_store_retry_busy [LSU_STA_COUNT],
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [LSU_LDU_COUNT-1:0] mmu2lsu_ldq_resp_valid,
  input  logic [31:0] mmu2lsu_ldq_resp_paddr [LSU_LDU_COUNT],
  input  logic [1:0] mmu2lsu_ldq_resp_result [LSU_LDU_COUNT],
  input  logic [5:0] mmu2lsu_ldq_resp_entry_idx [LSU_LDU_COUNT],
  input  logic [5:0] mmu2lsu_ldq_resp_wait_idx [LSU_LDU_COUNT],
  input  logic [LSU_STA_COUNT-1:0] mmu2lsu_stq_resp_valid,
  input  logic [31:0] mmu2lsu_stq_resp_paddr [LSU_STA_COUNT],
  input  logic [1:0] mmu2lsu_stq_resp_result [LSU_STA_COUNT],
  input  logic [5:0] mmu2lsu_stq_resp_entry_idx [LSU_STA_COUNT],
  input  logic [5:0] mmu2lsu_stq_resp_wait_idx [LSU_STA_COUNT],
  output logic [5:0] lsu2dis_stq_tail,
  output logic lsu2dis_stq_tail_flag,
  output logic [6:0] lsu2dis_stq_free,
  output logic [6:0] lsu2dis_ldq_free,
  output logic [DECODE_WIDTH-1:0] lsu2dis_ldq_alloc_valid,
  output logic [5:0] lsu2dis_ldq_alloc_idx [DECODE_WIDTH],
  output logic lsu2rob_committed_store_pending,
  // wake-ups of the load consumers driven by the LSU (LSU_PIPE, LP_L2): [p] L2 speculative, [LDU+p] L3
  output logic [2*LSU_LDU_COUNT-1:0] lsu2iss_wake_valid,
  output logic [6:0] lsu2iss_wake_preg [2*LSU_LDU_COUNT],
  output logic [LSU_LDU_COUNT-1:0] lsu2iss_cancel_valid,
  output logic [6:0] lsu2iss_cancel_preg [LSU_LDU_COUNT],
  output logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_valid,
  output logic [31:0] lsu2exe_wb_req_uop_diag_val [LSU_LOAD_WB_WIDTH],
  output logic [31:0] lsu2exe_wb_req_uop_result [LSU_LOAD_WB_WIDTH],
  output logic [6:0] lsu2exe_wb_req_uop_dest_preg [LSU_LOAD_WB_WIDTH],
  output logic [BR_MASK_WIDTH-1:0] lsu2exe_wb_req_uop_br_mask [LSU_LOAD_WB_WIDTH],
  output logic [6:0] lsu2exe_wb_req_uop_rob_idx [LSU_LOAD_WB_WIDTH],
  output logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_dest_en,
  output logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_page_fault_load,
  output logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_page_fault_store,
  output logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_rob_defer,    // LSU_MEMSPEC: ROB completion deferred
  output logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_flush_pipe,   // LSU_MEMSPEC: write-back of a violator
  output logic [LSU_STA_COUNT-1:0] lsu2exe_sta_wb_req_valid,
  output logic [31:0] lsu2exe_sta_wb_req_uop_diag_val [LSU_STA_COUNT],
  output logic [31:0] lsu2exe_sta_wb_req_uop_result [LSU_STA_COUNT],
  output logic [BR_MASK_WIDTH-1:0] lsu2exe_sta_wb_req_uop_br_mask [LSU_STA_COUNT],
  output logic [6:0] lsu2exe_sta_wb_req_uop_rob_idx [LSU_STA_COUNT],
  output logic [LSU_STA_COUNT-1:0] lsu2exe_sta_wb_req_uop_page_fault_store,
  output logic peripheral_req_is_mmio,
  output logic peripheral_req_wen,
  output logic [31:0] peripheral_req_mmio_addr,
  output logic [31:0] peripheral_req_mmio_wdata,
  output logic [2:0] peripheral_req_mmio_fun3,
  output logic lsu2dcache_load_ports_valid [LSU_LDU_COUNT],
  output logic [31:0] lsu2dcache_load_ports_addr [LSU_LDU_COUNT],
  output logic [30:0] lsu2dcache_load_ports_req_id [LSU_LDU_COUNT],
  output logic lsu2dcache_load_ports_replay [LSU_LDU_COUNT],
  output logic lsu2dcache_store_ports_valid [LSU_STA_COUNT],
  output logic [31:0] lsu2dcache_store_ports_addr [LSU_STA_COUNT],
  output logic [31:0] lsu2dcache_store_ports_data [LSU_STA_COUNT],
  output logic [4:0] lsu2dcache_store_ports_strb [LSU_STA_COUNT],
  output logic [5:0] lsu2dcache_store_ports_req_id [LSU_STA_COUNT],
  output logic [LSU_LDU_COUNT-1:0] lsu2mmu_ldq_req_valid,
  output logic [31:0] lsu2mmu_ldq_req_vaddr [LSU_LDU_COUNT],
  output logic [5:0] lsu2mmu_ldq_req_entry_idx [LSU_LDU_COUNT],
  output logic [5:0] lsu2mmu_ldq_req_wait_idx [LSU_LDU_COUNT],
  output logic [LSU_STA_COUNT-1:0] lsu2mmu_stq_req_valid,
  output logic [31:0] lsu2mmu_stq_req_vaddr [LSU_STA_COUNT],
  output logic [5:0] lsu2mmu_stq_req_entry_idx [LSU_STA_COUNT],
  output logic [5:0] lsu2mmu_stq_req_wait_idx [LSU_STA_COUNT]
);

  if (LSU_PIPE != 0) begin : g_pipe
    lsu_pipe u_pipe (.*);
  end else begin : g_legacy

  // the legacy LSU has no memory speculation and no LSU-driven wake-ups
  assign lsu2exe_wb_req_uop_rob_defer = '0;
  assign lsu2exe_wb_req_uop_flush_pipe = '0;
  assign lsu2iss_wake_valid = '0;
  assign lsu2iss_cancel_valid = '0;
  for (genvar k = 0; k < 2 * LSU_LDU_COUNT; k++) begin : g_nowake
    assign lsu2iss_wake_preg[k] = '0;
  end
  for (genvar k = 0; k < LSU_LDU_COUNT; k++) begin : g_nocancel
    assign lsu2iss_cancel_preg[k] = '0;
  end

  logic [8-1:0] cm_valid_vec;
  logic [8-1:0] dis_stq_req_vec;
  logic [8-1:0] dis_ldq_req_vec;
  logic [LSU_SDU_COUNT-1:0] sdu_valid_vec;
  logic [LSU_LDU_COUNT-1:0] ldu_valid_vec;
  logic [LSU_LDU_COUNT-1:0] ldu_is_atomic_vec;
  logic [LSU_STA_COUNT-1:0] sta_valid_vec;
  logic [LSU_STA_COUNT-1:0] sta_is_atomic_vec;
  logic [LSU_LDU_COUNT-1:0] dcl_valid_vec;
  logic [LSU_STA_COUNT-1:0] dcs_valid_vec;
  logic [LSU_LDU_COUNT-1:0] mmu_ld_valid_vec;
  logic [LSU_STA_COUNT-1:0] mmu_st_valid_vec;
  logic [8-1:0] lsu2dis_ldq_alloc_valid_vec;
  logic [LSU_LOAD_WB_WIDTH-1:0] wb_valid_vec;
  logic [LSU_LOAD_WB_WIDTH-1:0] wb_dest_en_vec;
  logic [LSU_LOAD_WB_WIDTH-1:0] wb_pf_load_vec;
  logic [LSU_LOAD_WB_WIDTH-1:0] wb_pf_store_vec;
  logic [LSU_STA_COUNT-1:0] sta_wb_valid_vec;
  logic [LSU_STA_COUNT-1:0] sta_wb_pf_store_vec;
  logic [LSU_LDU_COUNT-1:0] dcl_req_valid_vec, dcl_req_replay_vec;
  logic [LSU_STA_COUNT-1:0] dcs_req_valid_vec;
  logic [LSU_LDU_COUNT-1:0] mmu_ld_req_valid_vec;
  logic [LSU_STA_COUNT-1:0] mmu_st_req_valid_vec;
  logic [31:0] sta_wb_vaddr_w [NST];

  for (genvar i = 0; i < 8; i++) begin : g_cm_valid
    assign cm_valid_vec[i] = rob_commit_commit_entry_valid[i];
  end
  for (genvar i = 0; i < 8; i++) begin : g_dis_stq_req
    assign dis_stq_req_vec[i] = dis2lsu_alloc_req[i];
  end
  for (genvar i = 0; i < 8; i++) begin : g_dis_ldq_req
    assign dis_ldq_req_vec[i] = dis2lsu_ldq_alloc_req[i];
  end
  for (genvar i = 0; i < LSU_SDU_COUNT; i++) begin : g_sdu_valid
    assign sdu_valid_vec[i] = exe2lsu_sdu_req_valid[i];
  end
  for (genvar i = 0; i < LSU_LDU_COUNT; i++) begin : g_ldu_valid
    assign ldu_valid_vec[i] = exe2lsu_ldu_req_valid[i];
  end
  for (genvar i = 0; i < LSU_LDU_COUNT; i++) begin : g_ldu_is_atomic
    assign ldu_is_atomic_vec[i] = exe2lsu_ldu_req_uop_is_atomic[i];
  end
  for (genvar i = 0; i < LSU_STA_COUNT; i++) begin : g_sta_valid
    assign sta_valid_vec[i] = exe2lsu_sta_req_valid[i];
  end
  for (genvar i = 0; i < LSU_STA_COUNT; i++) begin : g_sta_is_atomic
    assign sta_is_atomic_vec[i] = exe2lsu_sta_req_uop_is_atomic[i];
  end
  for (genvar i = 0; i < LSU_LDU_COUNT; i++) begin : g_dcl_valid
    assign dcl_valid_vec[i] = dcache2lsu_load_resps_valid[i];
  end
  for (genvar i = 0; i < LSU_STA_COUNT; i++) begin : g_dcs_valid
    assign dcs_valid_vec[i] = dcache2lsu_store_resps_valid[i];
  end
  for (genvar i = 0; i < LSU_LDU_COUNT; i++) begin : g_mmu_ld_valid
    assign mmu_ld_valid_vec[i] = mmu2lsu_ldq_resp_valid[i];
  end
  for (genvar i = 0; i < LSU_STA_COUNT; i++) begin : g_mmu_st_valid
    assign mmu_st_valid_vec[i] = mmu2lsu_stq_resp_valid[i];
  end
  for (genvar i = 0; i < 8; i++) begin : g_lsu2dis_ldq_alloc_valid_oc_valid
    assign lsu2dis_ldq_alloc_valid[i] = lsu2dis_ldq_alloc_valid_vec[i];
  end
  for (genvar i = 0; i < LSU_LOAD_WB_WIDTH; i++) begin : g_wb_valid_eq_valid
    assign lsu2exe_wb_req_valid[i] = wb_valid_vec[i];
  end
  for (genvar i = 0; i < LSU_LOAD_WB_WIDTH; i++) begin : g_wb_dest_en__dest_en
    assign lsu2exe_wb_req_uop_dest_en[i] = wb_dest_en_vec[i];
  end
  for (genvar i = 0; i < LSU_LOAD_WB_WIDTH; i++) begin : g_wb_pf_load_ult_load
    assign lsu2exe_wb_req_uop_page_fault_load[i] = wb_pf_load_vec[i];
  end
  for (genvar i = 0; i < LSU_LOAD_WB_WIDTH; i++) begin : g_wb_pf_store_lt_store
    assign lsu2exe_wb_req_uop_page_fault_store[i] = wb_pf_store_vec[i];
  end
  for (genvar i = 0; i < LSU_STA_COUNT; i++) begin : g_sta_wb_valid_eq_valid
    assign lsu2exe_sta_wb_req_valid[i] = sta_wb_valid_vec[i];
  end
  for (genvar i = 0; i < LSU_STA_COUNT; i++) begin : g_sta_wb_pf_store_lt_store
    assign lsu2exe_sta_wb_req_uop_page_fault_store[i] = sta_wb_pf_store_vec[i];
  end
  for (genvar i = 0; i < LSU_LDU_COUNT; i++) begin : g_dcl_req_valid_ts_valid
    assign lsu2dcache_load_ports_valid[i] = dcl_req_valid_vec[i];
    assign lsu2dcache_load_ports_replay[i] = dcl_req_replay_vec[i];
  end
  for (genvar i = 0; i < LSU_STA_COUNT; i++) begin : g_dcs_req_valid_ts_valid
    assign lsu2dcache_store_ports_valid[i] = dcs_req_valid_vec[i];
  end
  for (genvar i = 0; i < LSU_LDU_COUNT; i++) begin : g_mmu_ld_req_valid_eq_valid
    assign lsu2mmu_ldq_req_valid[i] = mmu_ld_req_valid_vec[i];
  end
  for (genvar i = 0; i < LSU_STA_COUNT; i++) begin : g_mmu_st_req_valid_eq_valid
    assign lsu2mmu_stq_req_valid[i] = mmu_st_req_valid_vec[i];
  end
  for (genvar i = 0; i < NST; i++) begin : g_sta_dup
    assign lsu2exe_sta_wb_req_uop_diag_val[i] = sta_wb_vaddr_w[i];
    assign lsu2exe_sta_wb_req_uop_result[i] = sta_wb_vaddr_w[i];
  end

  lsu_core u_core (.clk(clk), .rst_n(rst_n),
    .cm_valid(cm_valid_vec), .cm_type(rob_commit_commit_entry_uop_type),
    .cm_amo_op(rob_commit_commit_entry_uop_amo_op), .cm_stq_idx(rob_commit_commit_entry_uop_stq_idx),
    .rb_flush(rob_bcast_flush), .rb_head_valid(rob_bcast_head_valid), .rb_head_rob_idx(rob_bcast_head_rob_idx),
    .rb_hi_valid(rob_bcast_head_incomplete_valid), .rb_hi_rob_idx(rob_bcast_head_incomplete_rob_idx),
    .dec_mispred(dec_bcast_mispred), .dec_br_mask(dec_bcast_br_mask), .dec_clear_mask(dec_bcast_clear_mask),
    .dis_stq_req(dis_stq_req_vec), .dis_stq_br_mask(dis2lsu_br_mask), .dis_stq_rob_idx(dis2lsu_rob_idx),
    .dis_stq_rob_flag(dis2lsu_rob_flag), .dis_ldq_req(dis_ldq_req_vec), .dis_ldq_idx(dis2lsu_ldq_idx),
    .dis_ldq_br_mask(dis2lsu_ldq_br_mask), .dis_ldq_rob_idx(dis2lsu_ldq_rob_idx),
    .dis_ldq_rob_flag(dis2lsu_ldq_rob_flag), .sdu_valid(sdu_valid_vec), .sdu_result(exe2lsu_sdu_req_uop_result),
    .sdu_rob_idx(exe2lsu_sdu_req_uop_rob_idx), .sdu_rob_flag(exe2lsu_sdu_req_uop_rob_flag),
    .sdu_stq_idx(exe2lsu_sdu_req_uop_stq_idx), .ldu_valid(ldu_valid_vec), .ldu_result(exe2lsu_ldu_req_uop_result),
    .ldu_dest_preg(exe2lsu_ldu_req_uop_dest_preg), .ldu_func3(exe2lsu_ldu_req_uop_func3),
    .ldu_is_atomic(ldu_is_atomic_vec), .ldu_amo_op(exe2lsu_ldu_req_uop_amo_op),
    .ldu_rob_idx(exe2lsu_ldu_req_uop_rob_idx), .ldu_rob_flag(exe2lsu_ldu_req_uop_rob_flag),
    .ldu_stq_idx(exe2lsu_ldu_req_uop_stq_idx), .ldu_stq_flag(exe2lsu_ldu_req_uop_stq_flag),
    .ldu_ldq_idx(exe2lsu_ldu_req_uop_ldq_idx), .sta_valid(sta_valid_vec), .sta_result(exe2lsu_sta_req_uop_result),
    .sta_dest_preg(exe2lsu_sta_req_uop_dest_preg), .sta_func3(exe2lsu_sta_req_uop_func3),
    .sta_is_atomic(sta_is_atomic_vec), .sta_amo_op(exe2lsu_sta_req_uop_amo_op),
    .sta_rob_idx(exe2lsu_sta_req_uop_rob_idx), .sta_rob_flag(exe2lsu_sta_req_uop_rob_flag),
    .sta_stq_idx(exe2lsu_sta_req_uop_stq_idx), .periph_resp_is_mmio(peripheral_resp_is_mmio),
    .periph_resp_ready(peripheral_resp_ready), .periph_resp_rdata(peripheral_resp_mmio_rdata),
    .dcl_valid(dcl_valid_vec), .dcl_req_id(dcache2lsu_load_resps_req_id), .dcl_data(dcache2lsu_load_resps_data),
    .dcl_replay(dcache2lsu_load_resps_replay), .dcs_valid(dcs_valid_vec), .dcs_req_id(dcache2lsu_store_resps_req_id),
    .dcs_replay(dcache2lsu_store_resps_replay), .fill_valid(dcache2lsu_mshr_fill),
    .fill_line(dcache2lsu_mshr_fill_line), .mmu_ld_valid(mmu_ld_valid_vec), .mmu_ld_paddr(mmu2lsu_ldq_resp_paddr),
    .mmu_ld_result(mmu2lsu_ldq_resp_result), .mmu_ld_entry_idx(mmu2lsu_ldq_resp_entry_idx),
    .mmu_ld_wait_idx(mmu2lsu_ldq_resp_wait_idx), .mmu_st_valid(mmu_st_valid_vec),
    .mmu_st_paddr(mmu2lsu_stq_resp_paddr), .mmu_st_result(mmu2lsu_stq_resp_result),
    .mmu_st_entry_idx(mmu2lsu_stq_resp_entry_idx), .mmu_st_wait_idx(mmu2lsu_stq_resp_wait_idx),
    .lsu2dis_stq_tail(lsu2dis_stq_tail), .lsu2dis_stq_tail_flag(lsu2dis_stq_tail_flag),
    .lsu2dis_stq_free(lsu2dis_stq_free), .lsu2dis_ldq_free(lsu2dis_ldq_free),
    .lsu2dis_ldq_alloc_valid(lsu2dis_ldq_alloc_valid_vec), .lsu2dis_ldq_alloc_idx(lsu2dis_ldq_alloc_idx),
    .lsu2rob_committed_store_pending(lsu2rob_committed_store_pending), .wb_valid(wb_valid_vec),
    .wb_diag_val(lsu2exe_wb_req_uop_diag_val), .wb_result(lsu2exe_wb_req_uop_result),
    .wb_dest_preg(lsu2exe_wb_req_uop_dest_preg), .wb_br_mask(lsu2exe_wb_req_uop_br_mask),
    .wb_rob_idx(lsu2exe_wb_req_uop_rob_idx), .wb_dest_en(wb_dest_en_vec), .wb_pf_load(wb_pf_load_vec),
    .wb_pf_store(wb_pf_store_vec), .sta_wb_valid(sta_wb_valid_vec), .sta_wb_br_mask(lsu2exe_sta_wb_req_uop_br_mask),
    .sta_wb_rob_idx(lsu2exe_sta_wb_req_uop_rob_idx), .sta_wb_pf_store(sta_wb_pf_store_vec),
    .periph_req_is_mmio(peripheral_req_is_mmio), .periph_req_wen(peripheral_req_wen),
    .periph_req_addr(peripheral_req_mmio_addr), .periph_req_wdata(peripheral_req_mmio_wdata),
    .periph_req_fun3(peripheral_req_mmio_fun3), .dcl_req_valid(dcl_req_valid_vec), .dcl_req_replay(dcl_req_replay_vec),
    .dcl_req_addr(lsu2dcache_load_ports_addr), .dcl_req_id_o(lsu2dcache_load_ports_req_id),
    .dcs_req_valid(dcs_req_valid_vec), .dcs_req_addr(lsu2dcache_store_ports_addr),
    .dcs_req_data(lsu2dcache_store_ports_data), .dcs_req_strb(lsu2dcache_store_ports_strb),
    .dcs_req_id_o(lsu2dcache_store_ports_req_id), .mmu_ld_req_valid(mmu_ld_req_valid_vec),
    .mmu_ld_req_vaddr(lsu2mmu_ldq_req_vaddr), .mmu_ld_req_entry_idx(lsu2mmu_ldq_req_entry_idx),
    .mmu_ld_req_wait_idx(lsu2mmu_ldq_req_wait_idx), .mmu_st_req_valid(mmu_st_req_valid_vec),
    .mmu_st_req_vaddr(lsu2mmu_stq_req_vaddr), .mmu_st_req_entry_idx(lsu2mmu_stq_req_entry_idx),
    .mmu_st_req_wait_idx(lsu2mmu_stq_req_wait_idx), .sta_wb_vaddr(sta_wb_vaddr_w));

  end

endmodule

`default_nettype wire
