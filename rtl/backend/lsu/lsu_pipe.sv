// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (staged LSU top: spec port adaptation, see spec/lsu.io, docs/analysis/l
`default_nettype none

module lsu_pipe
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
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
  input  logic [XLEN_BITS-1:0] exe2lsu_sdu_req_uop_result [LSU_SDU_COUNT],
  input  logic [6:0] exe2lsu_sdu_req_uop_rob_idx [LSU_SDU_COUNT],
  input  logic [LSU_SDU_COUNT-1:0] exe2lsu_sdu_req_uop_rob_flag,
  input  logic [5:0] exe2lsu_sdu_req_uop_stq_idx [LSU_SDU_COUNT],
  input  logic [LSU_LDU_COUNT-1:0] exe2lsu_ldu_req_valid,
  input  logic [XLEN_BITS-1:0] exe2lsu_ldu_req_uop_result [LSU_LDU_COUNT],
  input  logic [PRF_IDX_WIDTH-1:0] exe2lsu_ldu_req_uop_dest_preg [LSU_LDU_COUNT],
  input  logic [2:0] exe2lsu_ldu_req_uop_func3 [LSU_LDU_COUNT],
  input  logic [LSU_LDU_COUNT-1:0] exe2lsu_ldu_req_uop_is_atomic,
  input  logic [4:0] exe2lsu_ldu_req_uop_amo_op [LSU_LDU_COUNT],
  input  logic [6:0] exe2lsu_ldu_req_uop_rob_idx [LSU_LDU_COUNT],
  input  logic exe2lsu_ldu_req_uop_rob_flag [LSU_LDU_COUNT],
  input  logic [5:0] exe2lsu_ldu_req_uop_stq_idx [LSU_LDU_COUNT],
  input  logic exe2lsu_ldu_req_uop_stq_flag [LSU_LDU_COUNT],
  input  logic [5:0] exe2lsu_ldu_req_uop_ldq_idx [LSU_LDU_COUNT],
  input  logic [LSU_STA_COUNT-1:0] exe2lsu_sta_req_valid,
  input  logic [XLEN_BITS-1:0] exe2lsu_sta_req_uop_result [LSU_STA_COUNT],
  input  logic [PRF_IDX_WIDTH-1:0] exe2lsu_sta_req_uop_dest_preg [LSU_STA_COUNT],
  input  logic [2:0] exe2lsu_sta_req_uop_func3 [LSU_STA_COUNT],
  input  logic [LSU_STA_COUNT-1:0] exe2lsu_sta_req_uop_is_atomic,
  input  logic [4:0] exe2lsu_sta_req_uop_amo_op [LSU_STA_COUNT],
  input  logic [6:0] exe2lsu_sta_req_uop_rob_idx [LSU_STA_COUNT],
  input  logic exe2lsu_sta_req_uop_rob_flag [LSU_STA_COUNT],
  input  logic [5:0] exe2lsu_sta_req_uop_stq_idx [LSU_STA_COUNT],
  input  logic peripheral_resp_is_mmio,
  input  logic peripheral_resp_ready,
  input  logic [XLEN_BITS-1:0] peripheral_resp_mmio_rdata,
  input  logic dcache2lsu_load_resps_valid [LSU_LDU_COUNT],
  input  logic [31:0] dcache2lsu_load_resps_req_id [LSU_LDU_COUNT],
  input  logic [XLEN_BITS-1:0] dcache2lsu_load_resps_data [LSU_LDU_COUNT],
  input  logic [1:0] dcache2lsu_load_resps_replay [LSU_LDU_COUNT],
  input  logic dcache2lsu_store_resps_valid [LSU_STA_COUNT],
  input  logic [31:0] dcache2lsu_store_resps_req_id [LSU_STA_COUNT],
  input  logic [1:0] dcache2lsu_store_resps_replay [LSU_STA_COUNT],
  input  logic dcache2lsu_mshr_fill,
  input  logic [25:0] dcache2lsu_mshr_fill_line,
  input  logic dcache2lsu_load_retry_busy [LSU_LDU_COUNT],
  input  logic dcache2lsu_store_retry_busy [LSU_STA_COUNT],
  input  logic [LSU_LDU_COUNT-1:0] mmu2lsu_ldq_resp_valid,
  input  logic [31:0] mmu2lsu_ldq_resp_paddr [LSU_LDU_COUNT],
  input  logic [1:0] mmu2lsu_ldq_resp_result [LSU_LDU_COUNT],
  input  logic [5:0] mmu2lsu_ldq_resp_entry_idx [LSU_LDU_COUNT],
  /* verilator lint_off UNUSEDSIGNAL */  // wait_idx echoes entry_idx in the staged LSU (spec port kept)
  input  logic [5:0] mmu2lsu_ldq_resp_wait_idx [LSU_LDU_COUNT],
  input  logic [LSU_STA_COUNT-1:0] mmu2lsu_stq_resp_valid,
  input  logic [31:0] mmu2lsu_stq_resp_paddr [LSU_STA_COUNT],
  input  logic [1:0] mmu2lsu_stq_resp_result [LSU_STA_COUNT],
  input  logic [5:0] mmu2lsu_stq_resp_entry_idx [LSU_STA_COUNT],
  input  logic [5:0] mmu2lsu_stq_resp_wait_idx [LSU_STA_COUNT],
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [5:0] lsu2dis_stq_tail,
  output logic lsu2dis_stq_tail_flag,
  output logic [6:0] lsu2dis_stq_free,
  output logic [6:0] lsu2dis_ldq_free,
  output logic [DECODE_WIDTH-1:0] lsu2dis_ldq_alloc_valid,
  output logic [5:0] lsu2dis_ldq_alloc_idx [DECODE_WIDTH],
  output logic lsu2rob_committed_store_pending,
  output logic [2*LSU_LDU_COUNT-1:0] lsu2iss_wake_valid,
  output logic [PRF_IDX_WIDTH-1:0] lsu2iss_wake_preg [2*LSU_LDU_COUNT],
  output logic [LSU_LDU_COUNT-1:0] lsu2iss_cancel_valid,
  output logic [PRF_IDX_WIDTH-1:0] lsu2iss_cancel_preg [LSU_LDU_COUNT],
  output logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_valid,
  output logic [XLEN_BITS-1:0] lsu2exe_wb_req_uop_diag_val [LSU_LOAD_WB_WIDTH],
  output logic [XLEN_BITS-1:0] lsu2exe_wb_req_uop_result [LSU_LOAD_WB_WIDTH],
  output logic [PRF_IDX_WIDTH-1:0] lsu2exe_wb_req_uop_dest_preg [LSU_LOAD_WB_WIDTH],
  output logic [BR_MASK_WIDTH-1:0] lsu2exe_wb_req_uop_br_mask [LSU_LOAD_WB_WIDTH],
  output logic [6:0] lsu2exe_wb_req_uop_rob_idx [LSU_LOAD_WB_WIDTH],
  output logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_dest_en,
  output logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_page_fault_load,
  output logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_page_fault_store,
  output logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_rob_defer,    // LSU_MEMSPEC: ROB completion deferred
  output logic [LSU_LOAD_WB_WIDTH-1:0] lsu2exe_wb_req_uop_flush_pipe,   // LSU_MEMSPEC: write-back of a violator
  output logic [LSU_STA_COUNT-1:0] lsu2exe_sta_wb_req_valid,
  output logic [XLEN_BITS-1:0] lsu2exe_sta_wb_req_uop_diag_val [LSU_STA_COUNT],
  output logic [XLEN_BITS-1:0] lsu2exe_sta_wb_req_uop_result [LSU_STA_COUNT],
  output logic [BR_MASK_WIDTH-1:0] lsu2exe_sta_wb_req_uop_br_mask [LSU_STA_COUNT],
  output logic [6:0] lsu2exe_sta_wb_req_uop_rob_idx [LSU_STA_COUNT],
  output logic [LSU_STA_COUNT-1:0] lsu2exe_sta_wb_req_uop_page_fault_store,
  output logic peripheral_req_is_mmio,
  output logic peripheral_req_wen,
  output logic [31:0] peripheral_req_mmio_addr,
  output logic [XLEN_BITS-1:0] peripheral_req_mmio_wdata,
  output logic [2:0] peripheral_req_mmio_fun3,
  output logic lsu2dcache_load_ports_valid [LSU_LDU_COUNT],
  output logic lsu2dcache_load_ports_replay [LSU_LDU_COUNT],
  output logic [31:0] lsu2dcache_load_ports_addr [LSU_LDU_COUNT],
  output logic [30:0] lsu2dcache_load_ports_req_id [LSU_LDU_COUNT],
  output logic lsu2dcache_store_ports_valid [LSU_STA_COUNT],
  output logic [31:0] lsu2dcache_store_ports_addr [LSU_STA_COUNT],
  output logic [XLEN_BITS-1:0] lsu2dcache_store_ports_data [LSU_STA_COUNT],
  output logic [DST_STRB_W-1:0] lsu2dcache_store_ports_strb [LSU_STA_COUNT],
  output logic [DST_L2_W-1:0] lsu2dcache_store_ports_l2 [LSU_STA_COUNT],
  output logic [5:0] lsu2dcache_store_ports_req_id [LSU_STA_COUNT],
  output logic [LSU_LDU_COUNT-1:0] lsu2mmu_ldq_req_valid,
  output logic [XLEN_BITS-1:0] lsu2mmu_ldq_req_vaddr [LSU_LDU_COUNT],
  output logic [5:0] lsu2mmu_ldq_req_entry_idx [LSU_LDU_COUNT],
  output logic [5:0] lsu2mmu_ldq_req_wait_idx [LSU_LDU_COUNT],
  output logic [LSU_STA_COUNT-1:0] lsu2mmu_stq_req_valid,
  output logic [XLEN_BITS-1:0] lsu2mmu_stq_req_vaddr [LSU_STA_COUNT],
  output logic [5:0] lsu2mmu_stq_req_entry_idx [LSU_STA_COUNT],
  output logic [5:0] lsu2mmu_stq_req_wait_idx [LSU_STA_COUNT]
);

  // ---- struct packing of the spec ports ----
  lp_dis_ld_t   dis_ld [NDIS];
  lp_dis_st_t   dis_st [NDIS];
  lp_std_t      std_w [NSD];
  lp_agu_ld_t   agl [NLD];
  lp_agu_st_t   ags [NST];
  logic [NCM-1:0] cm_valid_w;
  logic [NLD-1:0] dcl_valid_w, ldrb_w;
  logic [NST-1:0] dcs_valid_w, strb_w;
  logic [NLD-1:0] mmu_l_valid_w;
  logic [NST-1:0] mmu_s_valid_w;

  always_comb begin
    for (int i = 0; i < NDIS; i++) begin
      dis_ld[i].v = dis2lsu_ldq_alloc_req[i];
      dis_ld[i].ldq = dis2lsu_ldq_idx[i];
      dis_ld[i].rob_idx = dis2lsu_ldq_rob_idx[i];
      dis_ld[i].rob_flag = dis2lsu_ldq_rob_flag[i];
      dis_ld[i].br_mask = dis2lsu_ldq_br_mask[i];
      dis_ld[i].mdp = dis2lsu_ldq_mdp[i];
      dis_ld[i].wait_b = 1'b0;
      dis_st[i].v = dis2lsu_alloc_req[i];
      dis_st[i].rob_idx = dis2lsu_rob_idx[i];
      dis_st[i].rob_flag = dis2lsu_rob_flag[i];
      dis_st[i].br_mask = dis2lsu_br_mask[i];
      dis_st[i].func3 = '0;
    end
    for (int i = 0; i < NSD; i++) begin
      std_w[i].v = exe2lsu_sdu_req_valid[i];
      std_w[i].stq = exe2lsu_sdu_req_uop_stq_idx[i];
      std_w[i].rob_idx = exe2lsu_sdu_req_uop_rob_idx[i];
      std_w[i].rob_flag = exe2lsu_sdu_req_uop_rob_flag[i];
      std_w[i].data = exe2lsu_sdu_req_uop_result[i];
    end
    for (int i = 0; i < NLD; i++) begin
      agl[i].v = exe2lsu_ldu_req_valid[i];
      agl[i].ldq = exe2lsu_ldu_req_uop_ldq_idx[i];
      agl[i].rob_idx = exe2lsu_ldu_req_uop_rob_idx[i];
      agl[i].rob_flag = exe2lsu_ldu_req_uop_rob_flag[i];
      agl[i].vaddr = exe2lsu_ldu_req_uop_result[i];
      agl[i].dest = exe2lsu_ldu_req_uop_dest_preg[i];
      agl[i].func3 = exe2lsu_ldu_req_uop_func3[i];
      agl[i].snap_idx = exe2lsu_ldu_req_uop_stq_idx[i];
      agl[i].snap_flag = exe2lsu_ldu_req_uop_stq_flag[i];
      agl[i].lr = exe2lsu_ldu_req_uop_is_atomic[i] && exe2lsu_ldu_req_uop_amo_op[i] == AMO_LR;
      dcl_valid_w[i] = dcache2lsu_load_resps_valid[i];
      ldrb_w[i] = dcache2lsu_load_retry_busy[i];
    end
    for (int i = 0; i < NST; i++) begin
      ags[i].v = exe2lsu_sta_req_valid[i];
      ags[i].stq = exe2lsu_sta_req_uop_stq_idx[i];
      ags[i].rob_idx = exe2lsu_sta_req_uop_rob_idx[i];
      ags[i].rob_flag = exe2lsu_sta_req_uop_rob_flag[i];
      ags[i].vaddr = exe2lsu_sta_req_uop_result[i];
      ags[i].dest = exe2lsu_sta_req_uop_dest_preg[i];
      ags[i].func3 = exe2lsu_sta_req_uop_func3[i];
      ags[i].sc = exe2lsu_sta_req_uop_is_atomic[i] && exe2lsu_sta_req_uop_amo_op[i] == AMO_SC;
      dcs_valid_w[i] = dcache2lsu_store_resps_valid[i];
      strb_w[i] = dcache2lsu_store_retry_busy[i];
    end
    cm_valid_w = rob_commit_commit_entry_valid;
    mmu_l_valid_w = mmu2lsu_ldq_resp_valid;
    mmu_s_valid_w = mmu2lsu_stq_resp_valid;
  end

  logic [XLEN_BITS-1:0] sta_vaddr_w [NST];
  logic [NLD-1:0] dcl_req_valid_w, dcl_req_replay_w;
  logic [NST-1:0] dcs_req_valid_w;

  lp_core u_core (
    .clk(clk), .rst_n(rst_n),
    .cm_valid(cm_valid_w), .cm_type(rob_commit_commit_entry_uop_type), .cm_amo_op(rob_commit_commit_entry_uop_amo_op),
    .cm_stq_idx(rob_commit_commit_entry_uop_stq_idx), .rb_flush(rob_bcast_flush), .rb_head_valid(rob_bcast_head_valid),
    .rb_head_rob_idx(rob_bcast_head_rob_idx), .rb_hi_valid(rob_bcast_head_incomplete_valid),
    .rb_hi_rob_idx(rob_bcast_head_incomplete_rob_idx), .dec_mispred(dec_bcast_mispred),
    .dec_br_mask(dec_bcast_br_mask), .dec_clear_mask(dec_bcast_clear_mask),
    .dis_ld(dis_ld), .dis_st(dis_st), .sdw(std_w), .agl(agl), .ags(ags),
    .periph_is_mmio(peripheral_resp_is_mmio), .periph_rdata(peripheral_resp_mmio_rdata),
    .periph_ready(peripheral_resp_ready),
    .dcl_valid(dcl_valid_w), .dcl_req_id(dcache2lsu_load_resps_req_id), .dcl_data(dcache2lsu_load_resps_data),
    .dcl_replay(dcache2lsu_load_resps_replay), .dcs_valid(dcs_valid_w), .dcs_req_id(dcache2lsu_store_resps_req_id),
    .dcs_replay(dcache2lsu_store_resps_replay), .fill_valid(dcache2lsu_mshr_fill),
    .fill_line(dcache2lsu_mshr_fill_line), .ld_retry_busy(ldrb_w), .st_retry_busy(strb_w),
    .mmu_l_valid(mmu_l_valid_w), .mmu_l_paddr(mmu2lsu_ldq_resp_paddr), .mmu_l_result(mmu2lsu_ldq_resp_result),
    .mmu_l_entry(mmu2lsu_ldq_resp_entry_idx), .mmu_s_valid(mmu_s_valid_w), .mmu_s_paddr(mmu2lsu_stq_resp_paddr),
    .mmu_s_result(mmu2lsu_stq_resp_result), .mmu_s_entry(mmu2lsu_stq_resp_entry_idx),
    .o_stq_tail(lsu2dis_stq_tail), .o_stq_tail_flag(lsu2dis_stq_tail_flag), .o_stq_free(lsu2dis_stq_free),
    .o_ldq_free(lsu2dis_ldq_free), .o_ldq_alloc_valid(lsu2dis_ldq_alloc_valid), .o_ldq_alloc_idx(lsu2dis_ldq_alloc_idx),
    .o_committed_store_pending(lsu2rob_committed_store_pending),
    .o_wk_valid(lsu2iss_wake_valid), .o_wk_preg(lsu2iss_wake_preg), .o_cn_valid(lsu2iss_cancel_valid),
    .o_cn_preg(lsu2iss_cancel_preg),
    .wb_valid(lsu2exe_wb_req_valid), .wb_diag(lsu2exe_wb_req_uop_diag_val), .wb_result(lsu2exe_wb_req_uop_result),
    .wb_dest(lsu2exe_wb_req_uop_dest_preg), .wb_br(lsu2exe_wb_req_uop_br_mask), .wb_rob(lsu2exe_wb_req_uop_rob_idx),
    .wb_dest_en(lsu2exe_wb_req_uop_dest_en), .wb_pf_load(lsu2exe_wb_req_uop_page_fault_load),
    .wb_pf_store(lsu2exe_wb_req_uop_page_fault_store),
    .wb_defer(lsu2exe_wb_req_uop_rob_defer), .wb_flushp(lsu2exe_wb_req_uop_flush_pipe),
    .sta_valid(lsu2exe_sta_wb_req_valid), .sta_vaddr(sta_vaddr_w), .sta_br(lsu2exe_sta_wb_req_uop_br_mask),
    .sta_rob(lsu2exe_sta_wb_req_uop_rob_idx), .sta_pf(lsu2exe_sta_wb_req_uop_page_fault_store),
    .per_is_mmio(peripheral_req_is_mmio), .per_wen(peripheral_req_wen), .per_addr(peripheral_req_mmio_addr),
    .per_wdata(peripheral_req_mmio_wdata), .per_func3(peripheral_req_mmio_fun3),
    .dcl_req_valid(dcl_req_valid_w), .dcl_req_replay(dcl_req_replay_w), .dcl_req_addr(lsu2dcache_load_ports_addr),
    .dcl_req_id_o(lsu2dcache_load_ports_req_id),
    .dcs_req_valid(dcs_req_valid_w), .dcs_req_addr(lsu2dcache_store_ports_addr),
    .dcs_req_data(lsu2dcache_store_ports_data),
    .dcs_req_strb(lsu2dcache_store_ports_strb), .dcs_req_l2(lsu2dcache_store_ports_l2),
    .dcs_req_id_o(lsu2dcache_store_ports_req_id),
    .mmu_l_req_valid(lsu2mmu_ldq_req_valid), .mmu_l_req_vaddr(lsu2mmu_ldq_req_vaddr),
    .mmu_l_req_idx(lsu2mmu_ldq_req_entry_idx), .mmu_s_req_valid(lsu2mmu_stq_req_valid),
    .mmu_s_req_vaddr(lsu2mmu_stq_req_vaddr), .mmu_s_req_idx(lsu2mmu_stq_req_entry_idx));

  for (genvar i = 0; i < NLD; i++) begin : g_dcl
    assign lsu2dcache_load_ports_valid[i] = dcl_req_valid_w[i];
    assign lsu2dcache_load_ports_replay[i] = dcl_req_replay_w[i];
    assign lsu2mmu_ldq_req_wait_idx[i] = lsu2mmu_ldq_req_entry_idx[i];
  end
  for (genvar i = 0; i < NST; i++) begin : g_dcs
    assign lsu2dcache_store_ports_valid[i] = dcs_req_valid_w[i];
    assign lsu2mmu_stq_req_wait_idx[i] = lsu2mmu_stq_req_entry_idx[i];
    assign lsu2exe_sta_wb_req_uop_diag_val[i] = sta_vaddr_w[i];
    assign lsu2exe_sta_wb_req_uop_result[i] = sta_vaddr_w[i];
  end

endmodule

`default_nettype wire
