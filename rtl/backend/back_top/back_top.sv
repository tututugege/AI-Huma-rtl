// Ref: back-end/BackTop.cpp  class BackTop
// Instances: u_ftq_ibuf, u_br_redirect, u_idu, u_ren, u_dis, u_isu, u_prf, u_exu, u_csr, u_rob, u_dtlb, u_lsu, u_glue.
`default_nettype none

module back_top
  import ttg_cfg_pkg::*;
  import front_pkg::ftq_fe_view_t;
  import front_pkg::fe_ftq_s0_t;
  import front_pkg::fe_ftq_s2_t;
  import front_pkg::fe_ftq_pd_t;
  import tlb_mmu_pkg::*;
  import fp_pkg::*;
  import ftq_ibuf_pkg::ib_entry_t;
  import ren_pkg::ren_inst_t;
  import ren_pkg::ren_out_uop_t;
  import dis_pkg::dis_iss_uop_t;
  import dis_pkg::dis_rob_uop_t;
  import isu_pkg::isu_uop_t;
  import exu_ctrl_pkg::xc_inst_t;
  import exu_ctrl_pkg::xc_prf_wb_t;
  import exu_ctrl_pkg::xc_rob_wb_t;
  import exu_ctrl_pkg::xc_agu_req_t;
(
  input  logic clk,
  input  logic rst_n,
  // ---- in: front end -> back end (trimmed ibuf payload + Unified FTQ-64 write requests)
  input  logic [31:0]                    front2ftq_inst [BACKEND_FETCH_WIDTH],
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2ftq_page_fault_inst,
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2ftq_pf_inst_hi,
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2ftq_valid,
  input  logic [FTQ_IDX_WIDTH-1:0]       front2ftq_ftq_idx,
  input  fe_ftq_s0_t                     fe2ftq_s0,
  input  fe_ftq_s2_t                     fe2ftq_s2,
  input  fe_ftq_pd_t                     fe2ftq_pd,
  input  logic front_stall,
  input  logic [3:0] bpu_upd_free,
  input  logic [3:0] bpu_tq_free,
  output ftq_fe_view_t                   ftq2fe,
  // ---- in: MemSubsystem -> LSU
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
  // ---- in: interrupt injection (MemSubsystem -> Csr)
  input  logic interrupt_inject_software_irq_pending,
  input  logic interrupt_inject_software_irq_pending_valid,
  input  logic interrupt_inject_external_irq_pending,
  input  logic interrupt_inject_external_irq_pending_valid,
  input  logic interrupt_inject_supervisor_external_irq_pending,
  input  logic interrupt_inject_supervisor_external_irq_pending_valid,
  input  logic interrupt_inject_timer_irq_pending,
  input  logic interrupt_inject_timer_irq_pending_valid,
  // ---- in: MemSubsystem -> LSU (peripheral)
  input  logic peripheral_resp_is_mmio,
  input  logic [XLEN_BITS-1:0] peripheral_resp_mmio_rdata,
  input  logic peripheral_resp_ready,
  // ---- in: MemSubsystem PTW walk port -> DTLB
  input  logic ptw_walk_req_ready,
  input  logic ptw_walk_resp_fault,
  input  logic [LVL_W-1:0] ptw_walk_resp_leaf_level,
  input  logic [7:0] ptw_walk_resp_leaf_perm,
  input  logic [19:0] ptw_walk_resp_leaf_ppn,
  input  logic ptw_walk_resp_valid,
  input  logic [VPN_W-1:0] ptw_walk_resp_vpn,
  // ---- out: to core_top / front end
  output logic [COMMIT_WIDTH-1:0] commit_extra_is_ret,
  output logic [XLEN_BITS-1:0] csr_status_mstatus,
  output logic [1:0] csr_status_privilege,
  output logic [XLEN_BITS-1:0] csr_status_satp,
  output logic [XLEN_BITS-1:0] csr_status_sstatus,
  output logic [COMMIT_WIDTH-1:0] ftq_commit_info_resp_alt_pred,
  output logic [XLEN_BITS-1:0] ftq_commit_info_resp_pc [COMMIT_WIDTH],
  output logic [2:0] ftq_commit_info_resp_pcpn [COMMIT_WIDTH],
  output logic ftq_commit_info_resp_pred_taken [COMMIT_WIDTH],
  output logic ftq_commit_info_resp_is_rvc [COMMIT_WIDTH],
  output logic [9:0] ftq_commit_info_resp_blk_id [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0] ftq_commit_info_resp_valid,
  output logic [XLEN_BITS-1:0] out_commit_entry_uop_diag_val [COMMIT_WIDTH],
  output logic out_mispred,
  output logic out_no_mispred,
  output logic [XLEN_BITS-1:0] out_redirect_pc,
  output logic [9:0] out_rf_blk,
  output logic [XLEN_BITS-1:0] out_rf_pc,
  output logic out_rf_is_rvc,
  output logic [2:0] out_rf_type,
  output logic out_rf_valid,
  output logic out_stall,
  output logic [BACKEND_FETCH_WIDTH-1:0] ftq2front_fire,
  output logic ftq2front_ready,
  // ---- out: PMU
  output logic [DECODE_WIDTH-1:0] dis2rob_dis_fire,
  // ---- out: LSU -> MemSubsystem
  output logic [31:0] lsu2dcache_load_ports_addr [LSU_LDU_COUNT],
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
  output logic [30:0] lsu2dcache_load_ports_req_id [LSU_LDU_COUNT],
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
  output logic pmu_slot_valid [8],
  // ---- out: DTLB -> MemSubsystem PTW walk port
  output logic ptw_walk_flush,
  output logic [21:0] ptw_walk_req_root_ppn,
  output logic ptw_walk_req_valid,
  output logic [VPN_W-1:0] ptw_walk_req_vpn,
  output logic ptw_walk_resp_consumed,
  // ---- out: ROB broadcasts
  output logic rob_bcast_exception,
  output logic rob_bcast_fence,
  output logic rob_bcast_fence_i,
  output logic rob_bcast_flush,
  output logic rob_bcast_interrupt,
  output logic rob_bcast_mret,
  output logic [XLEN_BITS-1:0] rob_bcast_pc,
  output logic rob_bcast_sret,
  // ---- out: ROB commit
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

  // FLUSH_REG delayed flush / fence broadcasts
  logic rob_flush_q, rob_fence_q, rob_fence_i_q, rob_fence_raw, rob_fence_i_raw;

  // ---- ftq_ibuf -> idu / prf / rob / dispatch ----
  logic [XLEN_BITS-1:0]          ftq_prf_pc_resp_resp_next_pc [FTQ_PRF_PC_PORT_NUM];
  logic [XLEN_BITS-1:0]          ftq_prf_pc_resp_resp_pc      [FTQ_PRF_PC_PORT_NUM];
  logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_resp_resp_pred_taken;
  logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_resp_resp_is_rvc;
  logic [XLEN_BITS-1:0]          ftq_rob_pc_resp_resp_pc [1];
  logic [FTQ_ROB_PC_PORT_NUM-1:0] ftq_rob_pc_resp_resp_is_rvc;
  logic [DECODE_WIDTH-1:0]       ibuf2idu_valid;
  ib_entry_t                     ibuf2idu_entry [DECODE_WIDTH];
  logic [LSU_MDP_BITS-1:0]       ren2dis_uop_mdp [DECODE_WIDTH];
  logic [31:0]                   ren2dis_uop_pc  [DECODE_WIDTH];
  logic [DECODE_WIDTH-1:0]       ren2dis_uop_is_rvc;
  logic [FTQ_IDX_WIDTH-1:0]      ren2dis_ftq_idx [DECODE_WIDTH];
  logic [FTQ_OFFSET_WIDTH-1:0]   ren2dis_ftq_off [DECODE_WIDTH];
  logic [XLEN_BITS-1:0]          ftq_commit_info_resp_next_pc [COMMIT_WIDTH];
  logic [FTQ_IDX_WIDTH-1:0]      ftq_head_out;

  // ---- idu / br_redirect -> ren / global mispredict ----
  logic [XLEN_BITS-1:0]          br_redirect_br_pc;
  logic                          br_redirect_is_rvc;
  logic [5:0]                    br_redirect_ftq_idx;
  logic [FTQ_OFFSET_WIDTH-1:0]   br_redirect_ftq_offset;
  logic                          br_redirect_mispred;
  logic [XLEN_BITS-1:0]          br_redirect_pc;
  logic [DECODE_WIDTH-1:0]       dec2ren_valid;
  ren_inst_t                     dec2ren_uop [DECODE_WIDTH];
  logic                          dec_bcast_mispred;
  logic [ROB_IDX_WIDTH-1:0]      dec_bcast_redirect_rob_idx;
  logic                          dec_bcast_redirect_rob_flag;
  logic [DECODE_WIDTH-1:0]       idu_consume_fire;

  // ---- ren -> dispatch / rob ----
  logic                          ren2dec_ready;
  logic                          ren2rob_walking;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [PRF_IDX_WIDTH-1:0]      ren_commit_dest_preg [COMMIT_WIDTH];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [DECODE_WIDTH-1:0]       ren2dis_valid;
  ren_out_uop_t                  ren2dis_uop [DECODE_WIDTH];
  for (genvar i = 0; i < DECODE_WIDTH; i++) begin : g_ren_ftq
    assign ren2dis_ftq_idx[i] = ren2dis_uop[i].ftq_idx;
    assign ren2dis_ftq_off[i] = ren2dis_uop[i].ftq_offset;
  end

  // ---- dispatch -> isu / rob / lsu ----
  logic                          dis2ren_ready;
  dis_rob_uop_t                  dis2rob_uop [DECODE_WIDTH];
  logic                          dis2iss_req_valid [dis_pkg::IQ_NUM][DECODE_WIDTH];
  dis_iss_uop_t                  dis2iss_req_uop   [dis_pkg::IQ_NUM][DECODE_WIDTH];
  logic [DECODE_WIDTH-1:0]       dis2lsu_alloc_req;
  logic [DECODE_WIDTH-1:0]       dis2lsu_ldq_alloc_req;
  logic [5:0]                    dis2lsu_ldq_idx [DECODE_WIDTH];
  logic [DECODE_WIDTH-1:0]       dis2lsu_ldq_rob_flag;
  logic [LSU_MDP_BITS-1:0]       dis2lsu_ldq_mdp [DECODE_WIDTH];
  logic [31:0]                   dis2lsu_ldq_pc  [DECODE_WIDTH];
  logic [ROB_IDX_WIDTH-1:0]      dis2lsu_ldq_rob_idx [DECODE_WIDTH];
  logic [DECODE_WIDTH-1:0]       dis2lsu_rob_flag;
  logic [ROB_IDX_WIDTH-1:0]      dis2lsu_rob_idx [DECODE_WIDTH];

  // ---- isu -> prf / dispatch ----
  logic [IQ_READY_NUM_WIDTH-1:0] iss2dis_ready_num [dis_pkg::IQ_NUM];
  logic [ISSUE_WIDTH-1:0]        iss2prf_valid;
  isu_uop_t                      iss2prf_uop      [ISSUE_WIDTH];
  logic [ALU_NUM-1:0]            iss2prf_src1_byp [ISSUE_WIDTH];
  logic [ALU_NUM-1:0]            iss2prf_src2_byp [ISSUE_WIDTH];
  logic [PRF_IDX_WIDTH-1:0]      iss_awake_wake_preg [MAX_WAKEUP_PORTS];
  logic [MAX_WAKEUP_PORTS-1:0]   iss_awake_wake_valid;

  // ---- prf -> exu / ftq / isu ----
  logic [5:0]                    ftq_prf_pc_req_req_ftq_idx    [FTQ_PRF_PC_PORT_NUM];
  logic [FTQ_OFFSET_WIDTH-1:0]   ftq_prf_pc_req_req_ftq_offset [FTQ_PRF_PC_PORT_NUM];
  logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_req_req_valid;
  logic [ISSUE_WIDTH-1:0]        prf2exe_valid;
  xc_inst_t                      prf2exe_uop [ISSUE_WIDTH];
  logic [CSR_IDX_WIDTH-1:0]      prf2exe_csr_idx;
  logic [PRF_IDX_WIDTH-1:0]      prf_awake_wake_preg [LSU_LOAD_WB_WIDTH];
  logic [LSU_LOAD_WB_WIDTH-1:0]  prf_awake_wake_valid;

  // ---- exu -> prf / rob / csr / lsu / br_redirect ----
  logic [11:0]                   exe2csr_idx;
  logic                          exe2csr_re;
  logic [1:0]                    exe2csr_wcmd;
  logic [XLEN_BITS-1:0]          exe2csr_wdata;
  logic                          exe2csr_we;
  logic                          exe2iss_div_wb_next;
  logic                          exe2iss_div_wake_valid;
  logic [PRF_IDX_WIDTH-1:0]      exe2iss_div_wake_preg;
  xc_prf_wb_t                    exe2prf [WB_LANES];
  xc_rob_wb_t                    exu2rob [ROB_WB_WIDTH];
  xc_agu_req_t                   exe2lsu_agu [LSU_AGU_COUNT];
  logic [XLEN_BITS-1:0]          exe2lsu_sdu_req_uop_result    [LSU_SDU_COUNT];
  logic [LSU_SDU_COUNT-1:0]      exe2lsu_sdu_req_uop_rob_flag;
  logic [ROB_IDX_WIDTH-1:0]      exe2lsu_sdu_req_uop_rob_idx   [LSU_SDU_COUNT];
  logic [5:0]                    exe2lsu_sdu_req_uop_stq_idx   [LSU_SDU_COUNT];
  logic [LSU_SDU_COUNT-1:0]      exe2lsu_sdu_req_valid;
  logic [XLEN_BITS-1:0]          exu2id_br_pc;
  logic                          exu2id_br_is_rvc;
  logic [5:0]                    exu2id_ftq_idx;
  logic [FTQ_OFFSET_WIDTH-1:0]   exu2id_ftq_offset;
  logic                          exu2id_mispred;
  logic [XLEN_BITS-1:0]          exu2id_redirect_pc;
  logic [ROB_IDX_WIDTH-1:0]      exu2id_redirect_rob_idx;
  logic                          exu2id_redirect_rob_flag;

  // ---- csr / rob / dtlb / lsu / glue ----
  logic [XLEN_BITS-1:0]          csr2exe_rdata, csr2front_epc, csr2front_trap_pc;
  logic                          csr2rob_interrupt_req, csr2rob_fs_off;
  logic [2:0]                    csr2exe_frm;

  logic [5:0]                    ftq_rob_pc_req_req_ftq_idx [1];
  logic [FTQ_OFFSET_WIDTH-1:0]   ftq_rob_pc_req_req_ftq_offset [1];
  logic [0:0]                    ftq_rob_pc_req_req_valid;
  logic                          rob2csr_commit, rob2csr_fs_dirty, rob2csr_interrupt_resp;
  logic [4:0]                    rob2csr_fflags;
  logic                          rob2dis_empty, rob2dis_ready, rob2dis_rob_flag, rob2dis_stall;
  logic [ROB_IDX_WIDTH-1:0]      rob2dis_enq_idx;
  logic [ROB_IDX_WIDTH:0]        rob2dis_free;
  logic                          rob_bcast_breakpoint, rob_bcast_ecall, rob_bcast_head_incomplete_valid;
  logic                          rob_bcast_head_valid, rob_bcast_illegal_inst;
  logic                          rob_bcast_page_fault_inst, rob_bcast_page_fault_load, rob_bcast_page_fault_store;
  logic [ROB_IDX_WIDTH-1:0]      rob_bcast_head_incomplete_rob_idx, rob_bcast_head_rob_idx;
  logic [XLEN_BITS-1:0]          rob_bcast_trap_val;
  logic [5:0]                    rob_commit_commit_entry_uop_ftq_idx [COMMIT_WIDTH];
  logic [COMMIT_WIDTH-1:0]       rob_commit_commit_entry_uop_ftq_is_last;
  logic [FTQ_OFFSET_WIDTH-1:0]   rob_commit_commit_entry_uop_ftq_offset [COMMIT_WIDTH];
  logic [6:0]                    rob_commit_commit_entry_uop_func7 [COMMIT_WIDTH];
  logic [COMMIT_WIDTH-1:0]       rob_commit_commit_entry_uop_illegal_inst;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [COMMIT_WIDTH-1:0]       rob_commit_commit_entry_uop_dest_fp;
  /* verilator lint_on UNUSEDSIGNAL */

  logic [5:0]                    mmu2lsu_resp_entry_idx [LSU_AGU_COUNT];
  logic [31:0]                   mmu2lsu_resp_paddr     [LSU_AGU_COUNT];
  logic [28:0]                   mmu2lsu_resp_paddr_p1  [LSU_AGU_COUNT];
  logic [28:0]                   mmu2lsu_resp_paddr_m1  [LSU_AGU_COUNT];
  logic [1:0]                    mmu2lsu_resp_result    [LSU_AGU_COUNT];
  logic [LSU_AGU_COUNT-1:0]      mmu2lsu_resp_valid;
  logic                          dtlb_walk_next_v, dtlb_pf_page_set;
  logic [26:0]                   dtlb_walk_next_vpn, dtlb_pf_page_vpn;

  logic [5:0]                    lsu2dis_ldq_alloc_idx [DECODE_WIDTH];
  logic [DECODE_WIDTH-1:0]       lsu2dis_ldq_alloc_valid;
  logic [6:0]                    lsu2dis_ldq_free, lsu2dis_stq_free;
  logic [5:0]                    lsu2dis_stq_tail;
  logic                          lsu2dis_stq_tail_flag;
  logic [XLEN_BITS-1:0]          lsu2exe_sta_wb_req_uop_diag_val [LSU_STA_COUNT];
  logic [LSU_STA_COUNT-1:0]      lsu2exe_sta_wb_req_uop_page_fault_store;
  logic [XLEN_BITS-1:0]          lsu2exe_sta_wb_req_uop_result [LSU_STA_COUNT];
  logic [ROB_IDX_WIDTH-1:0]      lsu2exe_sta_wb_req_uop_rob_idx [LSU_STA_COUNT];
  logic [LSU_STA_COUNT-1:0]      lsu2exe_sta_wb_req_uop_rob_flag;
  logic [LSU_STA_COUNT-1:0]      lsu2exe_sta_wb_req_valid;
  logic [LSU_LOAD_WB_WIDTH-1:0]  lsu2exe_wb_req_uop_dest_en;
  logic [PRF_IDX_WIDTH-1:0]      lsu2exe_wb_req_uop_dest_preg [LSU_LOAD_WB_WIDTH];
  logic [XLEN_BITS-1:0]          lsu2exe_wb_req_uop_diag_val [LSU_LOAD_WB_WIDTH];
  logic [LSU_LOAD_WB_WIDTH-1:0]  lsu2exe_wb_req_uop_page_fault_load;
  logic [LSU_LOAD_WB_WIDTH-1:0]  lsu2exe_wb_req_uop_page_fault_store;
  logic [LSU_LOAD_WB_WIDTH-1:0]  lsu2exe_wb_req_uop_rob_defer;
  logic [LSU_LOAD_WB_WIDTH-1:0]  lsu2exe_wb_req_uop_flush_pipe;
  logic [LSU_LOAD_WB_WIDTH-1:0]  lsu2exe_wb_req_uop_is_w;
  logic [XLEN_BITS-1:0]          lsu2exe_wb_req_uop_result [LSU_LOAD_WB_WIDTH];
  logic [ROB_IDX_WIDTH-1:0]      lsu2exe_wb_req_uop_rob_idx [LSU_LOAD_WB_WIDTH];
  logic [LSU_LOAD_WB_WIDTH-1:0]  lsu2exe_wb_req_uop_rob_flag;
  logic [LSU_LOAD_WB_WIDTH-1:0]  lsu2exe_wb_req_valid;
  logic [5:0]                    lsu2mmu_req_entry_idx [LSU_AGU_COUNT];
  logic [XLEN_BITS-1:0]          lsu2mmu_req_vaddr     [LSU_AGU_COUNT];
  logic [LSU_AGU_COUNT-1:0]      lsu2mmu_req_valid, lsu2mmu_req_is_store;
  logic                          lsu2rob_committed_store_pending;
  logic [LSU_LOAD_WB_WIDTH-1:0]  lsu_byp_valid;
  always_comb begin
    for (int k = 0; k < LSU_LOAD_WB_WIDTH; k++)
      lsu_byp_valid[k] = lsu2exe_wb_req_valid[k] && lsu2exe_wb_req_uop_dest_en[k];
  end
  logic [2*LSU_LDU_COUNT-1:0]    lsu2iss_wake_valid;
  logic [PRF_IDX_WIDTH-1:0]      lsu2iss_wake_preg [2*LSU_LDU_COUNT];
  logic [LSU_LDU_COUNT-1:0]      lsu2iss_cancel_valid;
  logic [PRF_IDX_WIDTH-1:0]      lsu2iss_cancel_preg [LSU_LDU_COUNT];

  logic [1:0]                    csr_status_mstatus_mpp;
  logic                          csr_status_mstatus_mprv, csr_status_mstatus_mxr, csr_status_mstatus_sum;
  logic [4:0]                    rob_commit_commit_entry_uop_amo_op [COMMIT_WIDTH];

  /* verilator lint_off UNUSEDSIGNAL */
  logic                          nc_csr2exe_rdata_vld, nc_csr2front_epc_vld, nc_csr2front_trap_pc_vld;
  logic [FTQ_PRF_PC_PORT_NUM-1:0] nc_ftq_prf_pc_resp_resp_valid;
  logic [0:0]                    nc_ftq_rob_pc_resp_resp_valid;
  logic [LSU_AGU_COUNT-1:0]      nc_mmu2lsu_resp_hit;
  logic                          nc_rob_bcast_trap_val_valid;
  /* verilator lint_on UNUSEDSIGNAL */

  // ================= ftq_ibuf: FTQ + InstructionBuffer
  ftq_ibuf u_ftq_ibuf (
    .clk(clk), .rst_n(rst_n),
    .br_redirect_ftq_idx(br_redirect_ftq_idx), .br_redirect_ftq_offset(br_redirect_ftq_offset),
    .br_redirect_pc(br_redirect_pc), .br_redirect_mispred(br_redirect_mispred),
    .idu_consume_fire(idu_consume_fire),
    .ftq_prf_pc_req_req_ftq_idx(ftq_prf_pc_req_req_ftq_idx),
    .ftq_prf_pc_req_req_ftq_offset(ftq_prf_pc_req_req_ftq_offset),
    .ftq_prf_pc_req_req_valid(ftq_prf_pc_req_req_valid),
    .ftq_dis_req_ftq_idx(ren2dis_ftq_idx), .ftq_dis_req_ftq_offset(ren2dis_ftq_off),
    .ftq_dis_resp_mdp(ren2dis_uop_mdp), .ftq_dis_resp_pc(ren2dis_uop_pc), .ftq_dis_resp_is_rvc(ren2dis_uop_is_rvc),
    .ftq_rob_pc_req_req_ftq_idx(ftq_rob_pc_req_req_ftq_idx),
    .ftq_rob_pc_req_req_ftq_offset(ftq_rob_pc_req_req_ftq_offset),
    .ftq_rob_pc_req_req_valid(ftq_rob_pc_req_req_valid),
    .rob_bcast_flush(rob_flush_q),
    .rob_commit_commit_entry_uop_ftq_idx(rob_commit_commit_entry_uop_ftq_idx),
    .rob_commit_commit_entry_uop_ftq_is_last(rob_commit_commit_entry_uop_ftq_is_last),
    .rob_commit_commit_entry_uop_ftq_offset(rob_commit_commit_entry_uop_ftq_offset),
    .rob_commit_commit_entry_valid(rob_commit_commit_entry_valid),
    .front2ftq_inst(front2ftq_inst),
    .front2ftq_page_fault_inst(front2ftq_page_fault_inst), .front2ftq_pf_inst_hi(front2ftq_pf_inst_hi),
    .front2ftq_valid(front2ftq_valid), .front2ftq_ftq_idx(front2ftq_ftq_idx),
    .fe2ftq_s0(fe2ftq_s0), .fe2ftq_s2(fe2ftq_s2), .fe2ftq_pd(fe2ftq_pd), .ftq2fe(ftq2fe),
    .ftq_head_out(ftq_head_out),
    .ftq2front_ready(ftq2front_ready), .out_rf_blk(out_rf_blk), .out_rf_type(out_rf_type),
    .ftq2front_fire(ftq2front_fire),
    .ibuf2idu_valid(ibuf2idu_valid), .ibuf2idu_entry(ibuf2idu_entry),
    .ftq_prf_pc_resp_resp_valid(nc_ftq_prf_pc_resp_resp_valid),
    .ftq_prf_pc_resp_resp_pc(ftq_prf_pc_resp_resp_pc),
    .ftq_prf_pc_resp_resp_pred_taken(ftq_prf_pc_resp_resp_pred_taken),
    .ftq_prf_pc_resp_resp_is_rvc(ftq_prf_pc_resp_resp_is_rvc),
    .ftq_prf_pc_resp_resp_next_pc(ftq_prf_pc_resp_resp_next_pc),
    .ftq_rob_pc_resp_resp_valid(nc_ftq_rob_pc_resp_resp_valid),
    .ftq_rob_pc_resp_resp_pc(ftq_rob_pc_resp_resp_pc),
    .ftq_rob_pc_resp_resp_is_rvc(ftq_rob_pc_resp_resp_is_rvc),
    .ftq_commit_info_resp_valid(ftq_commit_info_resp_valid),
    .ftq_commit_info_resp_pc(ftq_commit_info_resp_pc),
    .ftq_commit_info_resp_next_pc(ftq_commit_info_resp_next_pc),
    .ftq_commit_info_resp_pred_taken(ftq_commit_info_resp_pred_taken),
    .ftq_commit_info_resp_is_rvc(ftq_commit_info_resp_is_rvc),
    .ftq_commit_info_resp_alt_pred(ftq_commit_info_resp_alt_pred),
    .ftq_commit_info_resp_pcpn(ftq_commit_info_resp_pcpn),
    .ftq_commit_info_resp_blk_id(ftq_commit_info_resp_blk_id)
  );

  // ================= br_redirect + idu
  back_br_redirect u_br_redirect (
    .clk(clk), .rst_n(rst_n), .rob_flush(rob_flush_q),
    .exu_mispred(exu2id_mispred), .exu_redirect_pc(exu2id_redirect_pc),
    .exu_redirect_rob_idx(exu2id_redirect_rob_idx), .exu_redirect_rob_flag(exu2id_redirect_rob_flag),
    .exu_ftq_idx(exu2id_ftq_idx), .exu_ftq_offset(exu2id_ftq_offset),
    .exu_br_pc(exu2id_br_pc), .exu_br_is_rvc(exu2id_br_is_rvc),
    .mispred(dec_bcast_mispred), .redirect_pc(br_redirect_pc),
    .redirect_rob_idx(dec_bcast_redirect_rob_idx), .redirect_rob_flag(dec_bcast_redirect_rob_flag),
    .ftq_idx(br_redirect_ftq_idx), .ftq_offset(br_redirect_ftq_offset),
    .br_pc(br_redirect_br_pc), .br_is_rvc(br_redirect_is_rvc)
  );
  assign br_redirect_mispred = dec_bcast_mispred;

  idu u_idu (
    .ibuf2idu_valid(ibuf2idu_valid), .ibuf2idu_entry(ibuf2idu_entry),
    .ren2dec_ready(ren2dec_ready), .rob_bcast_flush(rob_flush_q), .dec_bcast_mispred(dec_bcast_mispred),
    .dec2ren_valid(dec2ren_valid), .dec2ren_uop(dec2ren_uop), .idu_consume_fire(idu_consume_fire)
  );

  // ================= ren
  ren u_ren (
    .clk(clk), .rst_n(rst_n),
    .dis2ren_ready(dis2ren_ready),
    .dec2ren_valid(dec2ren_valid), .dec2ren_uop(dec2ren_uop),
    .dec_bcast_redirect_rob_idx(dec_bcast_redirect_rob_idx), .dec_bcast_mispred(dec_bcast_mispred),
    .rob_bcast_flush(rob_flush_q), .rob_bcast_interrupt(rob_bcast_interrupt),
    .rob_commit_commit_entry_uop_illegal_inst(rob_commit_commit_entry_uop_illegal_inst),
    .rob_commit_commit_entry_uop_page_fault_inst(rob_commit_commit_entry_uop_page_fault_inst),
    .rob_commit_commit_entry_uop_page_fault_load(rob_commit_commit_entry_uop_page_fault_load),
    .rob_commit_commit_entry_uop_page_fault_store(rob_commit_commit_entry_uop_page_fault_store),
    .rob_commit_commit_entry_uop_type(rob_commit_commit_entry_uop_type),
    .rob_commit_commit_entry_valid(rob_commit_commit_entry_valid),
    .ren2dec_ready(ren2dec_ready), .ren2rob_walking(ren2rob_walking),
    .ren_commit_dest_preg(ren_commit_dest_preg),
    .ren2dis_valid(ren2dis_valid), .ren2dis_uop(ren2dis_uop)
  );

  // ================= dispatch
  dispatch u_dis (
    .clk(clk), .rst_n(rst_n),
    .dec_bcast_mispred(dec_bcast_mispred),
    .iss2dis_ready_num(iss2dis_ready_num),
    .iss_awake_wake_preg(iss_awake_wake_preg), .iss_awake_wake_valid(iss_awake_wake_valid),
    .lsu2iss_wake_valid(lsu2iss_wake_valid), .lsu2iss_wake_preg(lsu2iss_wake_preg),
    .lsu2iss_cancel_valid(lsu2iss_cancel_valid), .lsu2iss_cancel_preg(lsu2iss_cancel_preg),
    .lsu2dis_ldq_alloc_idx(lsu2dis_ldq_alloc_idx), .lsu2dis_ldq_alloc_valid(lsu2dis_ldq_alloc_valid),
    .lsu2dis_ldq_free(lsu2dis_ldq_free), .lsu2dis_stq_free(lsu2dis_stq_free),
    .lsu2dis_stq_tail(lsu2dis_stq_tail), .lsu2dis_stq_tail_flag(lsu2dis_stq_tail_flag),
    .ren2dis_valid(ren2dis_valid), .ren2dis_uop(ren2dis_uop),
    .ren2dis_uop_mdp(ren2dis_uop_mdp), .ren2dis_uop_pc(ren2dis_uop_pc), .ren2dis_uop_is_rvc(ren2dis_uop_is_rvc),
    .rob2dis_empty(rob2dis_empty), .rob2dis_enq_idx(rob2dis_enq_idx), .rob2dis_free(rob2dis_free),
    .rob2dis_ready(rob2dis_ready), .rob2dis_rob_flag(rob2dis_rob_flag), .rob2dis_stall(rob2dis_stall),
    .rob_bcast_flush(rob_flush_q),
    .dis2ren_ready(dis2ren_ready), .pmu_slot_valid(pmu_slot_valid),
    .dis2rob_dis_fire(dis2rob_dis_fire), .dis2rob_uop(dis2rob_uop),
    .dis2iss_req_valid(dis2iss_req_valid), .dis2iss_req_uop(dis2iss_req_uop),
    .dis2lsu_alloc_req(dis2lsu_alloc_req), .dis2lsu_rob_idx(dis2lsu_rob_idx), .dis2lsu_rob_flag(dis2lsu_rob_flag),
    .dis2lsu_ldq_alloc_req(dis2lsu_ldq_alloc_req), .dis2lsu_ldq_idx(dis2lsu_ldq_idx),
    .dis2lsu_ldq_rob_idx(dis2lsu_ldq_rob_idx), .dis2lsu_ldq_rob_flag(dis2lsu_ldq_rob_flag),
    .dis2lsu_ldq_mdp(dis2lsu_ldq_mdp), .dis2lsu_ldq_pc(dis2lsu_ldq_pc)
  );

  // ================= isu
  isu u_isu (
    .clk(clk), .rst_n(rst_n),
    .lsu2iss_wake_valid(lsu2iss_wake_valid), .lsu2iss_wake_preg(lsu2iss_wake_preg),
    .lsu2iss_cancel_valid(lsu2iss_cancel_valid), .lsu2iss_cancel_preg(lsu2iss_cancel_preg),
    .dis2iss_req_valid(dis2iss_req_valid), .dis2iss_req_uop(dis2iss_req_uop),
    .exe2iss_div_wb_next(exe2iss_div_wb_next),
    .exe2iss_div_wake_valid(exe2iss_div_wake_valid), .exe2iss_div_wake_preg(exe2iss_div_wake_preg),
    .dec_bcast_mispred(dec_bcast_mispred),
    .dec_bcast_redirect_rob_idx(dec_bcast_redirect_rob_idx),
    .dec_bcast_redirect_rob_flag(dec_bcast_redirect_rob_flag),
    .prf_awake_wake_preg(prf_awake_wake_preg), .prf_awake_wake_valid(prf_awake_wake_valid),
    .rob_bcast_flush(rob_flush_q),
    .iss2dis_ready_num(iss2dis_ready_num),
    .iss2prf_valid(iss2prf_valid), .iss2prf_uop(iss2prf_uop),
    .iss2prf_src1_byp(iss2prf_src1_byp), .iss2prf_src2_byp(iss2prf_src2_byp),
    .iss_awake_wake_valid(iss_awake_wake_valid), .iss_awake_wake_preg(iss_awake_wake_preg)
  );

  // ================= prf
  prf u_prf (
    .clk(clk), .rst_n(rst_n),
    .lsu_byp_valid(lsu_byp_valid), .lsu_byp_dest_preg(lsu2exe_wb_req_uop_dest_preg),
    .lsu_byp_result(lsu2exe_wb_req_uop_result), .lsu_byp_is_w(lsu2exe_wb_req_uop_is_w),
    .exe2prf(exe2prf),
    .dec_bcast_mispred(dec_bcast_mispred),
    .dec_bcast_redirect_rob_idx(dec_bcast_redirect_rob_idx),
    .dec_bcast_redirect_rob_flag(dec_bcast_redirect_rob_flag),
    .iss2prf_valid(iss2prf_valid), .iss2prf_uop(iss2prf_uop),
    .iss2prf_src1_byp(iss2prf_src1_byp), .iss2prf_src2_byp(iss2prf_src2_byp),
    .ftq_prf_pc_resp_resp_next_pc(ftq_prf_pc_resp_resp_next_pc),
    .ftq_prf_pc_resp_resp_pc(ftq_prf_pc_resp_resp_pc),
    .ftq_prf_pc_resp_resp_pred_taken(ftq_prf_pc_resp_resp_pred_taken),
    .ftq_prf_pc_resp_resp_is_rvc(ftq_prf_pc_resp_resp_is_rvc),
    .rob_bcast_flush(rob_flush_q),
    .ftq_prf_pc_req_req_valid(ftq_prf_pc_req_req_valid),
    .ftq_prf_pc_req_req_ftq_idx(ftq_prf_pc_req_req_ftq_idx),
    .ftq_prf_pc_req_req_ftq_offset(ftq_prf_pc_req_req_ftq_offset),
    .prf_awake_wake_valid(prf_awake_wake_valid), .prf_awake_wake_preg(prf_awake_wake_preg),
    .prf2exe_valid(prf2exe_valid), .prf2exe_uop(prf2exe_uop), .prf2exe_csr_idx(prf2exe_csr_idx)
  );

  // ================= exu
  exu u_exu (
    .clk(clk), .rst_n(rst_n),
    .csr2exe_rdata(csr2exe_rdata), .csr2exe_frm(csr2exe_frm),
    .dec_bcast_mispred(dec_bcast_mispred),
    .dec_bcast_redirect_rob_idx(dec_bcast_redirect_rob_idx),
    .dec_bcast_redirect_rob_flag(dec_bcast_redirect_rob_flag),
    .lsu2exe_sta_wb_req_uop_diag_val(lsu2exe_sta_wb_req_uop_diag_val),
    .lsu2exe_sta_wb_req_uop_page_fault_store(lsu2exe_sta_wb_req_uop_page_fault_store),
    .lsu2exe_sta_wb_req_uop_result(lsu2exe_sta_wb_req_uop_result),
    .lsu2exe_sta_wb_req_uop_rob_idx(lsu2exe_sta_wb_req_uop_rob_idx),
    .lsu2exe_sta_wb_req_uop_rob_flag(lsu2exe_sta_wb_req_uop_rob_flag),
    .lsu2exe_sta_wb_req_valid(lsu2exe_sta_wb_req_valid),
    .lsu2exe_wb_req_uop_dest_en(lsu2exe_wb_req_uop_dest_en),
    .lsu2exe_wb_req_uop_dest_preg(lsu2exe_wb_req_uop_dest_preg),
    .lsu2exe_wb_req_uop_diag_val(lsu2exe_wb_req_uop_diag_val),
    .lsu2exe_wb_req_uop_page_fault_load(lsu2exe_wb_req_uop_page_fault_load),
    .lsu2exe_wb_req_uop_page_fault_store(lsu2exe_wb_req_uop_page_fault_store),
    .lsu2exe_wb_req_uop_rob_defer(lsu2exe_wb_req_uop_rob_defer),
    .lsu2exe_wb_req_uop_flush_pipe(lsu2exe_wb_req_uop_flush_pipe),
    .lsu2exe_wb_req_uop_is_w(lsu2exe_wb_req_uop_is_w),
    .lsu2exe_wb_req_uop_result(lsu2exe_wb_req_uop_result),
    .lsu2exe_wb_req_uop_rob_idx(lsu2exe_wb_req_uop_rob_idx),
    .lsu2exe_wb_req_uop_rob_flag(lsu2exe_wb_req_uop_rob_flag),
    .lsu2exe_wb_req_valid(lsu2exe_wb_req_valid),
    .prf2exe_valid(prf2exe_valid), .prf2exe_uop(prf2exe_uop), .prf2exe_csr_idx(prf2exe_csr_idx),
    .rob_bcast_flush(rob_flush_q),
    .exe2csr_we(exe2csr_we), .exe2csr_re(exe2csr_re), .exe2csr_idx(exe2csr_idx),
    .exe2csr_wdata(exe2csr_wdata), .exe2csr_wcmd(exe2csr_wcmd),
    .exe2iss_div_wb_next(exe2iss_div_wb_next),
    .exe2iss_div_wake_valid(exe2iss_div_wake_valid), .exe2iss_div_wake_preg(exe2iss_div_wake_preg),
    .exe2prf(exe2prf), .exu2rob(exu2rob),
    .exe2lsu_agu(exe2lsu_agu),
    .exe2lsu_sdu_req_valid(exe2lsu_sdu_req_valid),
    .exe2lsu_sdu_req_uop_result(exe2lsu_sdu_req_uop_result),
    .exe2lsu_sdu_req_uop_rob_idx(exe2lsu_sdu_req_uop_rob_idx),
    .exe2lsu_sdu_req_uop_rob_flag(exe2lsu_sdu_req_uop_rob_flag),
    .exe2lsu_sdu_req_uop_stq_idx(exe2lsu_sdu_req_uop_stq_idx),
    .exu2id_mispred(exu2id_mispred), .exu2id_redirect_pc(exu2id_redirect_pc),
    .exu2id_redirect_rob_idx(exu2id_redirect_rob_idx), .exu2id_redirect_rob_flag(exu2id_redirect_rob_flag),
    .exu2id_ftq_idx(exu2id_ftq_idx), .exu2id_ftq_offset(exu2id_ftq_offset),
    .exu2id_br_pc(exu2id_br_pc), .exu2id_br_is_rvc(exu2id_br_is_rvc)
  );

  // ================= csr
  csr u_csr (
    .clk(clk), .rst_n(rst_n),
    .exe2csr_idx(exe2csr_idx), .exe2csr_re(exe2csr_re), .exe2csr_wcmd(exe2csr_wcmd),
    .exe2csr_wdata(exe2csr_wdata), .exe2csr_we(exe2csr_we),
    .rob2csr_commit(rob2csr_commit), .rob2csr_fflags(rob2csr_fflags),
    .rob2csr_fs_dirty(rob2csr_fs_dirty), .rob2csr_interrupt_resp(rob2csr_interrupt_resp),
    .rob_bcast_breakpoint(rob_bcast_breakpoint), .rob_bcast_ecall(rob_bcast_ecall),
    .rob_bcast_illegal_inst(rob_bcast_illegal_inst), .rob_bcast_mret(rob_bcast_mret),
    .rob_bcast_page_fault_inst(rob_bcast_page_fault_inst),
    .rob_bcast_page_fault_load(rob_bcast_page_fault_load),
    .rob_bcast_page_fault_store(rob_bcast_page_fault_store),
    .rob_bcast_pc(rob_bcast_pc), .rob_bcast_sret(rob_bcast_sret), .rob_bcast_trap_val(rob_bcast_trap_val),
    .interrupt_inject_software_irq_pending(interrupt_inject_software_irq_pending),
    .interrupt_inject_software_irq_pending_valid(interrupt_inject_software_irq_pending_valid),
    .interrupt_inject_external_irq_pending(interrupt_inject_external_irq_pending),
    .interrupt_inject_external_irq_pending_valid(interrupt_inject_external_irq_pending_valid),
    .interrupt_inject_supervisor_external_irq_pending(interrupt_inject_supervisor_external_irq_pending),
    .interrupt_inject_supervisor_external_irq_pending_valid(interrupt_inject_supervisor_external_irq_pending_valid),
    .interrupt_inject_timer_irq_pending(interrupt_inject_timer_irq_pending),
    .interrupt_inject_timer_irq_pending_valid(interrupt_inject_timer_irq_pending_valid),
    .csr2exe_rdata_vld(nc_csr2exe_rdata_vld), .csr2exe_rdata(csr2exe_rdata), .csr2exe_frm(csr2exe_frm),
    .csr2rob_interrupt_req(csr2rob_interrupt_req), .csr2rob_fs_off(csr2rob_fs_off),
    .csr2front_epc_vld(nc_csr2front_epc_vld), .csr2front_epc(csr2front_epc),
    .csr2front_trap_pc_vld(nc_csr2front_trap_pc_vld), .csr2front_trap_pc(csr2front_trap_pc),
    .csr_status_sstatus(csr_status_sstatus), .csr_status_mstatus(csr_status_mstatus),
    .csr_status_satp(csr_status_satp), .csr_status_privilege(csr_status_privilege)
  );

  // ================= FLUSH_REG
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rob_flush_q   <= 1'b0;
      rob_fence_q   <= 1'b0;
      rob_fence_i_q <= 1'b0;
    end else begin
      rob_flush_q   <= rob_bcast_flush;
      rob_fence_q   <= rob_fence_raw;
      rob_fence_i_q <= rob_fence_i_raw;
    end
  end
  assign rob_bcast_fence   = rob_fence_q;
  assign rob_bcast_fence_i = rob_fence_i_q;

  // ================= rob
  rob u_rob (
    .clk(clk), .rst_n(rst_n),
    .csr2rob_interrupt_req(csr2rob_interrupt_req), .csr2rob_fs_off(csr2rob_fs_off),
    .dis2rob_dis_fire(dis2rob_dis_fire), .dis2rob_uop(dis2rob_uop),
    .exu2rob(exu2rob),
    .dec_bcast_mispred(dec_bcast_mispred), .ren2rob_walking(ren2rob_walking),
    .dec_bcast_redirect_rob_idx(dec_bcast_redirect_rob_idx),
    .lsu2rob_committed_store_pending(lsu2rob_committed_store_pending),
    .ftq_rob_pc_resp_resp_pc(ftq_rob_pc_resp_resp_pc),
    .front_stall(front_stall), .bpu_upd_free(bpu_upd_free), .bpu_tq_free(bpu_tq_free),
    .ftq_head(ftq_head_out),
    .rob2dis_stall(rob2dis_stall), .rob2dis_empty(rob2dis_empty), .rob2dis_ready(rob2dis_ready),
    .rob2dis_enq_idx(rob2dis_enq_idx), .rob2dis_free(rob2dis_free), .rob2dis_rob_flag(rob2dis_rob_flag),
    .rob2csr_commit(rob2csr_commit), .rob2csr_fflags(rob2csr_fflags),
    .rob2csr_fs_dirty(rob2csr_fs_dirty), .rob2csr_interrupt_resp(rob2csr_interrupt_resp),
    .rob_commit_commit_entry_valid(rob_commit_commit_entry_valid),
    .rob_commit_commit_entry_uop_dest_areg(rob_commit_commit_entry_uop_dest_areg),
    .rob_commit_commit_entry_uop_dest_fp(rob_commit_commit_entry_uop_dest_fp),
    .rob_commit_commit_entry_uop_ftq_idx(rob_commit_commit_entry_uop_ftq_idx),
    .rob_commit_commit_entry_uop_ftq_offset(rob_commit_commit_entry_uop_ftq_offset),
    .rob_commit_commit_entry_uop_ftq_is_last(rob_commit_commit_entry_uop_ftq_is_last),
    .rob_commit_commit_entry_uop_br_taken(rob_commit_commit_entry_uop_br_taken),
    .rob_commit_commit_entry_uop_dest_en(rob_commit_commit_entry_uop_dest_en),
    .rob_commit_commit_entry_uop_func7(rob_commit_commit_entry_uop_func7),
    .rob_commit_commit_entry_uop_rob_idx(rob_commit_commit_entry_uop_rob_idx),
    .rob_commit_commit_entry_uop_rob_flag(rob_commit_commit_entry_uop_rob_flag),
    .rob_commit_commit_entry_uop_stq_idx(rob_commit_commit_entry_uop_stq_idx),
    .rob_commit_commit_entry_uop_stq_flag(rob_commit_commit_entry_uop_stq_flag),
    .rob_commit_commit_entry_uop_page_fault_inst(rob_commit_commit_entry_uop_page_fault_inst),
    .rob_commit_commit_entry_uop_page_fault_load(rob_commit_commit_entry_uop_page_fault_load),
    .rob_commit_commit_entry_uop_page_fault_store(rob_commit_commit_entry_uop_page_fault_store),
    .rob_commit_commit_entry_uop_illegal_inst(rob_commit_commit_entry_uop_illegal_inst),
    .rob_commit_commit_entry_uop_type(rob_commit_commit_entry_uop_type),
    .commit_extra_is_ret(commit_extra_is_ret),
    .rob_bcast_flush(rob_bcast_flush), .flush_pend(rob_flush_q),
    .rob_bcast_mret(rob_bcast_mret), .rob_bcast_sret(rob_bcast_sret),
    .rob_bcast_ecall(rob_bcast_ecall), .rob_bcast_breakpoint(rob_bcast_breakpoint),
    .rob_bcast_exception(rob_bcast_exception),
    .rob_bcast_fence(rob_fence_raw), .rob_bcast_fence_i(rob_fence_i_raw),
    .rob_bcast_page_fault_inst(rob_bcast_page_fault_inst),
    .rob_bcast_page_fault_load(rob_bcast_page_fault_load),
    .rob_bcast_page_fault_store(rob_bcast_page_fault_store),
    .rob_bcast_illegal_inst(rob_bcast_illegal_inst), .rob_bcast_interrupt(rob_bcast_interrupt),
    .rob_bcast_trap_val_valid(nc_rob_bcast_trap_val_valid), .rob_bcast_trap_val(rob_bcast_trap_val),
    .rob_bcast_pc(rob_bcast_pc),
    .rob_bcast_head_rob_idx(rob_bcast_head_rob_idx), .rob_bcast_head_valid(rob_bcast_head_valid),
    .rob_bcast_head_incomplete_rob_idx(rob_bcast_head_incomplete_rob_idx),
    .rob_bcast_head_incomplete_valid(rob_bcast_head_incomplete_valid),
    .ftq_rob_pc_req_req_valid(ftq_rob_pc_req_req_valid),
    .ftq_rob_pc_req_req_ftq_idx(ftq_rob_pc_req_req_ftq_idx),
    .ftq_rob_pc_req_req_ftq_offset(ftq_rob_pc_req_req_ftq_offset)
  );

  // ================= dtlb
  tlb_mmu u_dtlb (
    .clk(clk), .rst_n(rst_n),
    .csr_status_privilege(csr_status_privilege), .csr_status_satp(csr_status_satp),
    .csr_status_mstatus_mpp(csr_status_mstatus_mpp), .csr_status_mstatus_mprv(csr_status_mstatus_mprv),
    .csr_status_mstatus_mxr(csr_status_mstatus_mxr), .csr_status_mstatus_sum(csr_status_mstatus_sum),
    .dec_bcast_mispred(dec_bcast_mispred),
    .req_entry_idx(lsu2mmu_req_entry_idx), .req_vaddr(lsu2mmu_req_vaddr),
    .req_valid(lsu2mmu_req_valid), .req_is_store(lsu2mmu_req_is_store),
    .rob_bcast_fence(rob_fence_q), .rob_bcast_flush(rob_flush_q),
    .ptw_walk_req_ready(ptw_walk_req_ready), .ptw_walk_resp_fault(ptw_walk_resp_fault),
    .ptw_walk_resp_leaf_level(ptw_walk_resp_leaf_level), .ptw_walk_resp_leaf_perm(ptw_walk_resp_leaf_perm),
    .ptw_walk_resp_leaf_ppn(ptw_walk_resp_leaf_ppn), .ptw_walk_resp_valid(ptw_walk_resp_valid),
    .ptw_walk_resp_vpn(ptw_walk_resp_vpn),
    .resp_valid(mmu2lsu_resp_valid), .resp_result(mmu2lsu_resp_result), .resp_hit(nc_mmu2lsu_resp_hit),
    .resp_paddr(mmu2lsu_resp_paddr), .resp_paddr_p1(mmu2lsu_resp_paddr_p1), .resp_paddr_m1(mmu2lsu_resp_paddr_m1),
    .resp_entry_idx(mmu2lsu_resp_entry_idx),
    .ptw_walk_req_valid(ptw_walk_req_valid), .ptw_walk_req_vpn(ptw_walk_req_vpn),
    .ptw_walk_req_root_ppn(ptw_walk_req_root_ppn), .ptw_walk_resp_consumed(ptw_walk_resp_consumed),
    .ptw_walk_flush(ptw_walk_flush),
    .pf_page_set(dtlb_pf_page_set), .pf_page_vpn(dtlb_pf_page_vpn),
    .walk_next_v(dtlb_walk_next_v), .walk_next_vpn(dtlb_walk_next_vpn)
  );

  // ================= lsu
  lsu u_lsu (
    .clk(clk), .rst_n(rst_n),
    .dis2lsu_alloc_req(dis2lsu_alloc_req), .dis2lsu_ldq_alloc_req(dis2lsu_ldq_alloc_req),
    .dis2lsu_ldq_idx(dis2lsu_ldq_idx), .dis2lsu_ldq_rob_flag(dis2lsu_ldq_rob_flag),
    .dis2lsu_ldq_mdp(dis2lsu_ldq_mdp), .dis2lsu_ldq_pc(dis2lsu_ldq_pc),
    .dis2lsu_ldq_rob_idx(dis2lsu_ldq_rob_idx), .dis2lsu_rob_flag(dis2lsu_rob_flag), .dis2lsu_rob_idx(dis2lsu_rob_idx),
    .mmu2lsu_resp_entry_idx(mmu2lsu_resp_entry_idx), .mmu2lsu_resp_paddr(mmu2lsu_resp_paddr),
    .mmu2lsu_resp_paddr_p1(mmu2lsu_resp_paddr_p1), .mmu2lsu_resp_paddr_m1(mmu2lsu_resp_paddr_m1),
    .mmu2lsu_resp_result(mmu2lsu_resp_result), .mmu2lsu_resp_valid(mmu2lsu_resp_valid),
    .exe2lsu_agu(exe2lsu_agu),
    .exe2lsu_sdu_req_uop_result(exe2lsu_sdu_req_uop_result),
    .exe2lsu_sdu_req_uop_rob_flag(exe2lsu_sdu_req_uop_rob_flag),
    .exe2lsu_sdu_req_uop_rob_idx(exe2lsu_sdu_req_uop_rob_idx),
    .exe2lsu_sdu_req_uop_stq_idx(exe2lsu_sdu_req_uop_stq_idx),
    .exe2lsu_sdu_req_valid(exe2lsu_sdu_req_valid),
    .rob_commit_commit_entry_uop_amo_op(rob_commit_commit_entry_uop_amo_op),
    .dec_bcast_mispred(dec_bcast_mispred),
    .dec_bcast_redirect_rob_idx(dec_bcast_redirect_rob_idx),
    .dec_bcast_redirect_rob_flag(dec_bcast_redirect_rob_flag),
    .rob_bcast_flush(rob_flush_q), .rob_flush_now(rob_bcast_flush),
    .rob_bcast_head_incomplete_rob_idx(rob_bcast_head_incomplete_rob_idx),
    .rob_bcast_head_incomplete_valid(rob_bcast_head_incomplete_valid),
    .rob_bcast_head_rob_idx(rob_bcast_head_rob_idx), .rob_bcast_head_valid(rob_bcast_head_valid),
    .rob_commit_commit_entry_uop_stq_idx(rob_commit_commit_entry_uop_stq_idx),
    .rob_commit_commit_entry_uop_rob_idx(rob_commit_commit_entry_uop_rob_idx),
    .rob_commit_commit_entry_uop_rob_flag(rob_commit_commit_entry_uop_rob_flag),
    .rob_commit_commit_entry_uop_type(rob_commit_commit_entry_uop_type),
    .rob_commit_commit_entry_valid(rob_commit_commit_entry_valid),
    .dcache2lsu_load_resps_data(dcache2lsu_load_resps_data),
    .dcache2lsu_load_resps_replay(dcache2lsu_load_resps_replay),
    .dcache2lsu_load_resps_req_id(dcache2lsu_load_resps_req_id),
    .dcache2lsu_load_resps_valid(dcache2lsu_load_resps_valid),
    .dcache2lsu_load_retry_busy(dcache2lsu_load_retry_busy),
    .dcache2lsu_store_retry_busy(dcache2lsu_store_retry_busy),
    .dcache2lsu_mshr_fill(dcache2lsu_mshr_fill), .dcache2lsu_mshr_fill_line(dcache2lsu_mshr_fill_line),
    .dcache2lsu_store_resps_replay(dcache2lsu_store_resps_replay),
    .dcache2lsu_store_resps_req_id(dcache2lsu_store_resps_req_id),
    .dcache2lsu_store_resps_valid(dcache2lsu_store_resps_valid),
    .peripheral_resp_is_mmio(peripheral_resp_is_mmio),
    .peripheral_resp_mmio_rdata(peripheral_resp_mmio_rdata),
    .peripheral_resp_ready(peripheral_resp_ready),
    .lsu2dis_stq_tail(lsu2dis_stq_tail), .lsu2dis_stq_tail_flag(lsu2dis_stq_tail_flag),
    .lsu2dis_stq_free(lsu2dis_stq_free), .lsu2dis_ldq_free(lsu2dis_ldq_free),
    .lsu2dis_ldq_alloc_valid(lsu2dis_ldq_alloc_valid), .lsu2dis_ldq_alloc_idx(lsu2dis_ldq_alloc_idx),
    .lsu2rob_committed_store_pending(lsu2rob_committed_store_pending),
    .lsu2iss_wake_valid(lsu2iss_wake_valid), .lsu2iss_wake_preg(lsu2iss_wake_preg),
    .lsu2iss_cancel_valid(lsu2iss_cancel_valid), .lsu2iss_cancel_preg(lsu2iss_cancel_preg),
    .lsu2exe_wb_req_valid(lsu2exe_wb_req_valid), .lsu2exe_wb_req_uop_diag_val(lsu2exe_wb_req_uop_diag_val),
    .lsu2exe_wb_req_uop_result(lsu2exe_wb_req_uop_result),
    .lsu2exe_wb_req_uop_dest_preg(lsu2exe_wb_req_uop_dest_preg),
    .lsu2exe_wb_req_uop_rob_idx(lsu2exe_wb_req_uop_rob_idx),
    .lsu2exe_wb_req_uop_rob_flag(lsu2exe_wb_req_uop_rob_flag),
    .lsu2exe_wb_req_uop_dest_en(lsu2exe_wb_req_uop_dest_en),
    .lsu2exe_wb_req_uop_page_fault_load(lsu2exe_wb_req_uop_page_fault_load),
    .lsu2exe_wb_req_uop_page_fault_store(lsu2exe_wb_req_uop_page_fault_store),
    .lsu2exe_wb_req_uop_rob_defer(lsu2exe_wb_req_uop_rob_defer),
    .lsu2exe_wb_req_uop_flush_pipe(lsu2exe_wb_req_uop_flush_pipe),
    .lsu2exe_wb_req_uop_is_w(lsu2exe_wb_req_uop_is_w),
    .lsu2exe_sta_wb_req_valid(lsu2exe_sta_wb_req_valid),
    .lsu2exe_sta_wb_req_uop_diag_val(lsu2exe_sta_wb_req_uop_diag_val),
    .lsu2exe_sta_wb_req_uop_result(lsu2exe_sta_wb_req_uop_result),
    .lsu2exe_sta_wb_req_uop_rob_idx(lsu2exe_sta_wb_req_uop_rob_idx),
    .lsu2exe_sta_wb_req_uop_rob_flag(lsu2exe_sta_wb_req_uop_rob_flag),
    .lsu2exe_sta_wb_req_uop_page_fault_store(lsu2exe_sta_wb_req_uop_page_fault_store),
    .peripheral_req_is_mmio(peripheral_req_is_mmio), .peripheral_req_wen(peripheral_req_wen),
    .peripheral_req_mmio_addr(peripheral_req_mmio_addr), .peripheral_req_mmio_wdata(peripheral_req_mmio_wdata),
    .peripheral_req_mmio_fun3(peripheral_req_mmio_fun3),
    .lsu2dcache_load_ports_valid(lsu2dcache_load_ports_valid),
    .lsu2dcache_load_ports_replay(lsu2dcache_load_ports_replay),
    .lsu2dcache_load_ports_pc(lsu2dcache_load_ports_pc), .lsu2dcache_load_ports_va(lsu2dcache_load_ports_va),
    .pf_xq_v, .pf_xq_va, .pf_xq_llc, .dtlb_walk_next_v, .dtlb_walk_next_vpn,
    .pf_xq_pop, .pf_xans_v, .pf_xans_line, .pf_xans_llc, .dtlb_pf_page_set, .dtlb_pf_page_vpn,
    .lsu2dcache_load_ports_addr(lsu2dcache_load_ports_addr),
    .lsu2dcache_load_ports_req_id(lsu2dcache_load_ports_req_id),
    .lsu2dcache_store_ports_valid(lsu2dcache_store_ports_valid),
    .lsu2dcache_store_ports_addr(lsu2dcache_store_ports_addr),
    .lsu2dcache_store_ports_data(lsu2dcache_store_ports_data),
    .lsu2dcache_store_ports_strb(lsu2dcache_store_ports_strb),
    .lsu2dcache_store_ports_l2(lsu2dcache_store_ports_l2),
    .lsu2dcache_store_ports_req_id(lsu2dcache_store_ports_req_id),
    .lsu2mmu_req_valid(lsu2mmu_req_valid), .lsu2mmu_req_vaddr(lsu2mmu_req_vaddr),
    .lsu2mmu_req_entry_idx(lsu2mmu_req_entry_idx), .lsu2mmu_req_is_store(lsu2mmu_req_is_store)
  );

  // ================= glue
  back_top_glue u_glue (
    .clk(clk), .rst_n(rst_n),
    .csr2front_epc(csr2front_epc), .csr2front_trap_pc(csr2front_trap_pc),
    .csr_status_mstatus(csr_status_mstatus),
    .br_redirect_br_pc(br_redirect_br_pc), .br_redirect_is_rvc(br_redirect_is_rvc),
    .br_redirect_pc(br_redirect_pc), .dec_bcast_mispred(dec_bcast_mispred),
    .ftq2front_ready(ftq2front_ready),
    .rob_bcast_exception(rob_bcast_exception), .rob_bcast_flush(rob_bcast_flush), .flush_q(rob_flush_q),
    .rob_bcast_mret(rob_bcast_mret), .rob_bcast_pc(rob_bcast_pc),
    .rob_bcast_is_rvc(ftq_rob_pc_resp_resp_is_rvc[0]), .rob_bcast_sret(rob_bcast_sret),
    .rob_commit_commit_entry_uop_type(rob_commit_commit_entry_uop_type),
    .rob_commit_commit_entry_uop_br_taken(rob_commit_commit_entry_uop_br_taken),
    .ftq_commit_pc(ftq_commit_info_resp_pc), .ftq_commit_next_pc(ftq_commit_info_resp_next_pc),
    .ftq_commit_is_rvc(ftq_commit_info_resp_is_rvc),
    .rob_commit_commit_entry_uop_func7(rob_commit_commit_entry_uop_func7),
    .rob_commit_commit_entry_valid(rob_commit_commit_entry_valid),
    .out_mispred(out_mispred), .out_no_mispred(out_no_mispred), .out_stall(out_stall),
    .out_redirect_pc(out_redirect_pc), .out_rf_valid(out_rf_valid),
    .out_rf_pc(out_rf_pc), .out_rf_is_rvc(out_rf_is_rvc),
    .out_commit_entry_uop_diag_val(out_commit_entry_uop_diag_val),
    .csr_status_mstatus_mxr(csr_status_mstatus_mxr), .csr_status_mstatus_sum(csr_status_mstatus_sum),
    .csr_status_mstatus_mprv(csr_status_mstatus_mprv), .csr_status_mstatus_mpp(csr_status_mstatus_mpp),
    .rob_commit_commit_entry_uop_amo_op(rob_commit_commit_entry_uop_amo_op)
  );

endmodule

`default_nettype wire
