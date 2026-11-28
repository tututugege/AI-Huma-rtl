// Ref: back-end/PreIduQueue.cpp  class PreIduQueue (+ InstructionBuffer.cpp, include/FTQ.h) — Unified FTQ-64
`default_nettype none

// Unified FTQ-64 + IBuf top:
//   ftq_ibuf_ctrl    front-end ibuf handshake, group compaction ranks, ibuf pop count
//   ibuf             instruction ring buffer (feeds the Idu issue group)
//   ftq_ptr          Unified FTQ-64 5-pointer ring (comm_ptr/pd_ptr/s2_ptr/ifu_ptr/bpu_ptr)
//   ftq_pc           Unified FTQ-64 PC storage (FE + PRF + ROB + Commit + Dispatch)
//   ftq_meta         8 x (8 x 74b) strict sync 1R1W SRAM for BPU training metadata (pre-launched on next_comm_ptr)
//   ftq_bpu          Block ID (S2) + slot kind (PD) lookup for mispredict repair
module ftq_ibuf import ttg_cfg_pkg::*; import ftq_ibuf_pkg::*; import front_pkg::*;
  import bpu_types_pkg::FTB_BLK_ID_W; (
  input  logic clk,
  input  logic rst_n,
  // Trimmed instruction payload from core_front2back
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2ftq_valid,
  input  logic [31:0]                    front2ftq_inst [BACKEND_FETCH_WIDTH],
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2ftq_page_fault_inst,
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2ftq_pf_inst_hi,
  input  logic [FTQ_IDX_WIDTH-1:0]       front2ftq_ftq_idx,
  // Unified FTQ-64 frontend write requests (bypass stall hold) + registered view back to front_top
  input  fe_ftq_s0_t                     fe2ftq_s0,
  input  fe_ftq_s2_t                     fe2ftq_s2,
  input  fe_ftq_pd_t                     fe2ftq_pd,
  output ftq_fe_view_t                   ftq2fe,
  // Backend control / commit / lookup ports
  input  logic [DECODE_WIDTH-1:0] idu_consume_fire,
  input  logic br_redirect_mispred,
  input  logic [FTQ_IDX_WIDTH-1:0] br_redirect_ftq_idx,
  input  logic [FTQ_OFFSET_WIDTH-1:0] br_redirect_ftq_offset,
  input  logic [XLEN_BITS-1:0] br_redirect_pc,
  input  logic rob_bcast_flush,
  input  logic [COMMIT_WIDTH-1:0] rob_commit_valid,
  input  logic [FTQ_IDX_WIDTH-1:0] rob_commit_uop_ftq_idx [COMMIT_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] rob_commit_uop_ftq_offset [COMMIT_WIDTH],
  input  logic [COMMIT_WIDTH-1:0] rob_commit_uop_ftq_is_last,
  input  logic [FTQ_IDX_WIDTH-1:0] ftq_prf_pc_req_ftq_idx [FTQ_PRF_PC_PORT_NUM],
  input  logic [FTQ_OFFSET_WIDTH-1:0] ftq_prf_pc_req_ftq_offset [FTQ_PRF_PC_PORT_NUM],
  input  logic [FTQ_IDX_WIDTH-1:0] ftq_rob_pc_req_ftq_idx [FTQ_ROB_PC_PORT_NUM],
  input  logic [FTQ_OFFSET_WIDTH-1:0] ftq_rob_pc_req_ftq_offset [FTQ_ROB_PC_PORT_NUM],
  input  logic [FTQ_IDX_WIDTH-1:0] ftq_dis_req_ftq_idx [DECODE_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] ftq_dis_req_ftq_offset [DECODE_WIDTH],
  output logic [LSU_MDP_BITS-1:0] ftq_dis_resp_mdp [DECODE_WIDTH],
  output logic [31:0] ftq_dis_resp_pc [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0] ftq_dis_resp_is_rvc,
  output logic [FTQ_IDX_WIDTH-1:0] ftq_head_out,
  output logic [FTB_BLK_ID_W-1:0] out_rf_blk,
  output logic [2:0] out_rf_type,
  output logic ftq2front_ready,
  output logic [BACKEND_FETCH_WIDTH-1:0] ftq2front_fire,
  output logic [DECODE_WIDTH-1:0] ibuf2idu_valid,
  output ib_entry_t ibuf2idu_entry [DECODE_WIDTH],
  output logic [XLEN_BITS-1:0] ftq_prf_pc_resp_pc [FTQ_PRF_PC_PORT_NUM],
  output logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_resp_pred_taken,
  output logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_resp_is_rvc,
  output logic [XLEN_BITS-1:0] ftq_prf_pc_resp_next_pc [FTQ_PRF_PC_PORT_NUM],
  output logic [XLEN_BITS-1:0] ftq_rob_pc_resp_pc [FTQ_ROB_PC_PORT_NUM],
  output logic [FTQ_ROB_PC_PORT_NUM-1:0] ftq_rob_pc_resp_is_rvc,
  output logic [COMMIT_WIDTH-1:0] ftq_commit_info_resp_valid,
  output logic [XLEN_BITS-1:0] ftq_commit_info_resp_pc [COMMIT_WIDTH],
  output logic [XLEN_BITS-1:0] ftq_commit_info_resp_next_pc [COMMIT_WIDTH],
  output logic ftq_commit_info_resp_pred_taken [COMMIT_WIDTH],
  output logic ftq_commit_info_resp_is_rvc [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0] ftq_commit_info_resp_alt_pred,
  output logic [ftq_ibuf_pkg::PCPN_W-1:0] ftq_commit_info_resp_pcpn [COMMIT_WIDTH],
  output logic [ftq_ibuf_pkg::BLK_ID_W-1:0] ftq_commit_info_resp_blk_id [COMMIT_WIDTH]
);

  logic [DECODE_WIDTH-1:0]        idu_fire;
  logic [COMMIT_WIDTH-1:0]        commit_valid;
  logic [COMMIT_WIDTH-1:0]        commit_is_last;
  ftq_meta_t                      s2_meta [BACKEND_FETCH_WIDTH];
  ib_entry_t                      push_entry [BACKEND_FETCH_WIDTH];
  ib_entry_t                      issue_entry [DECODE_WIDTH];
  ftq_meta_t                      rd_meta [COMMIT_WIDTH];
  logic [ftq_ibuf_pkg::BLK_ID_W-1:0] rd_blk_id [COMMIT_WIDTH];
  logic [DECODE_WIDTH-1:0]        issue_valid;

  logic [XLEN_BITS-1:0]           prf_rd_pc [FTQ_PRF_PC_PORT_NUM];
  logic                           prf_rd_pred_taken [FTQ_PRF_PC_PORT_NUM];
  logic                           prf_rd_is_rvc [FTQ_PRF_PC_PORT_NUM];
  logic [XLEN_BITS-1:0]           prf_rd_next_pc [FTQ_PRF_PC_PORT_NUM];
  logic [XLEN_BITS-1:0]           rob_rd_pc;
  logic                           rob_rd_is_rvc;
  logic [XLEN_BITS-1:0]           cm_rd_pc [COMMIT_WIDTH];
  logic                           cm_rd_pred_taken [COMMIT_WIDTH];
  logic                           cm_rd_is_rvc [COMMIT_WIDTH];
  logic [XLEN_BITS-1:0]           cm_rd_next_pc [COMMIT_WIDTH];

  logic                           ready;
  logic [BACKEND_FETCH_WIDTH-1:0] fire;
  logic [LANE_CNT_W-1:0]          lane_rank [BACKEND_FETCH_WIDTH];
  logic [BACKEND_FETCH_WIDTH-1:0] lane_is_last;
  logic [LANE_CNT_W-1:0]          push_cnt;
  logic                           queue_clear;
  logic [DECODE_CNT_W-1:0]        ib_pop_cnt;
  logic [IB_COUNT_W-1:0]          ib_count;

  // Unified FTQ-64 pointers & frontend feedback
  logic [FTQ_IDX_WIDTH-1:0]       comm_ptr, next_comm_ptr, pd_ptr, s2_ptr, ifu_ptr, bpu_ptr_unused, s0_wr_idx;
  logic                           ftq_full, ifu_empty, s2_empty;
  logic [1:0]                     ifu_cnt_sat;
  logic [XLEN_BITS-1:0]           ifu_addr, pd_base_pc, pd_out_next_pc;
  logic [5:0]                     ifu_next_set_idx;
  logic [BACKEND_FETCH_WIDTH-1:0] pd_out_pred_dir;

  // Gate frontend writes against backend flush/mispred (matches PreIduQueue::seq early return)
  logic s0_wr_eff, s2_wr_eff, pd_fire_eff;
  assign s0_wr_eff   = fe2ftq_s0.wr_en && !rob_bcast_flush && !br_redirect_mispred;
  assign s2_wr_eff   = fe2ftq_s2.wr_en && !rob_bcast_flush && !br_redirect_mispred;
  assign pd_fire_eff = fe2ftq_pd.fire  && !rob_bcast_flush && !br_redirect_mispred;

  logic unused_s2_base_bpu;
  assign unused_s2_base_bpu = ^{fe2ftq_s2.base_pc, bpu_ptr_unused};

  always_comb begin
    for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) begin
      s2_meta[i].alt_pred           = fe2ftq_s2.alt_pred[i];
      s2_meta[i].pcpn               = fe2ftq_s2.pcpn[i];
      push_entry[i].inst            = front2ftq_inst[i];
      push_entry[i].page_fault_inst = front2ftq_page_fault_inst[i];
      push_entry[i].pf_inst_hi      = front2ftq_pf_inst_hi[i];
      push_entry[i].ftq_idx         = front2ftq_ftq_idx;
      push_entry[i].ftq_offset      = FTQ_OFFSET_WIDTH'(i);
      push_entry[i].ftq_is_last     = lane_is_last[i];
    end
    for (int i = 0; i < DECODE_WIDTH; i++) idu_fire[i] = idu_consume_fire[i];
    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      commit_valid[i]   = rob_commit_valid[i];
      commit_is_last[i] = rob_commit_uop_ftq_is_last[i];
    end
  end

  logic [31:0] dis_pc     [DECODE_WIDTH];
  logic        dis_is_rvc [DECODE_WIDTH];
  always_comb begin
    for (int p = 0; p < DECODE_WIDTH; p++) begin
      ftq_dis_resp_is_rvc[p] = dis_is_rvc[p];
      ftq_dis_resp_pc[p]     = dis_pc[p];
    end
  end
  // wait-table index of a load (memory-dependence prediction): two folded PC fields above the slot offset
  for (genvar p = 0; p < DECODE_WIDTH; p++) begin : g_dis_pc
    assign ftq_dis_resp_mdp[p] = dis_pc[p][SLOT_SHIFT +: LSU_MDP_BITS] ^
                                 dis_pc[p][SLOT_SHIFT + LSU_MDP_BITS +: LSU_MDP_BITS];
  end

  ftq_ibuf_ctrl u_ctrl (
    .clk, .rst_n,
    .front_valid (front2ftq_valid),
    .br_mispred  (br_redirect_mispred),
    .rob_flush   (rob_bcast_flush),
    .ib_count, .idu_fire,
    .ready, .fire, .lane_rank, .lane_is_last, .push_cnt, .queue_clear, .ib_pop_cnt
  );

  ibuf u_ibuf (
    .clk, .rst_n, .clear(queue_clear), .pop_cnt(ib_pop_cnt), .push_cnt, .push_en(fire), .push_rank(lane_rank),
    .push_entry, .count(ib_count), .issue_valid, .issue_entry
  );

  ftq_ptr u_ptr (
    .clk, .rst_n,
    .flush          (rob_bcast_flush),
    .recover        (br_redirect_mispred),
    .recover_idx    (br_redirect_ftq_idx),
    .s0_wr_en       (fe2ftq_s0.wr_en),
    .s0_drop_tail_n (fe2ftq_s0.drop_tail_n),
    .s0_ifu_pop     (fe2ftq_s0.ifu_pop),
    .s2_wr_en       (fe2ftq_s2.wr_en),
    .pd_fire        (fe2ftq_pd.fire),
    .pd_flush       (fe2ftq_pd.flush),
    .pd_empty_blk   (fe2ftq_pd.empty_blk),
    .commit_valid, .commit_is_last,
    .commit_ftq_idx (rob_commit_uop_ftq_idx),
    .comm_ptr, .next_comm_ptr, .pd_ptr, .s2_ptr, .ifu_ptr,
    .bpu_ptr        (bpu_ptr_unused),
    .s0_wr_idx,
    .ftq_full, .ifu_empty, .ifu_cnt_sat, .s2_empty
  );

  ftq_pc u_pc (
    .clk,
    .s0_wr_en       (s0_wr_eff),
    .s0_idx         (s0_wr_idx),
    .s0_addr        (fe2ftq_s0.addr),
    .s2_wr_en       (s2_wr_eff),
    .s2_idx         (s2_ptr),
    .s2_pred_dir    (fe2ftq_s2.pred_dir),
    .s2_next_pc     (fe2ftq_s2.next_pc),
    .pd_fire        (pd_fire_eff),
    .pd_idx         (pd_ptr),
    .pd_carry       (fe2ftq_pd.carry),
    .pd_pc0         (fe2ftq_pd.pc0),
    .pd_pred_dir    (fe2ftq_pd.pred_dir),
    .pd_is_rvc      (fe2ftq_pd.is_rvc),
    .pd_next_pc     (fe2ftq_pd.next_pc),
    .mispred_en     (br_redirect_mispred && !rob_bcast_flush),
    .mispred_idx    (br_redirect_ftq_idx),
    .mispred_target (br_redirect_pc),
    .ifu_ptr, .ifu_addr, .ifu_next_set_idx,
    .pd_base_pc, .pd_out_pred_dir, .pd_out_next_pc,
    .ftq_head       (comm_ptr),
    .prf_idx(ftq_prf_pc_req_ftq_idx), .prf_off(ftq_prf_pc_req_ftq_offset),
    .prf_pc(prf_rd_pc), .prf_pred_taken(prf_rd_pred_taken), .prf_is_rvc(prf_rd_is_rvc), .prf_next_pc(prf_rd_next_pc),
    .rob_idx(ftq_rob_pc_req_ftq_idx[0]), .rob_off(ftq_rob_pc_req_ftq_offset[0]),
    .rob_pc(rob_rd_pc), .rob_is_rvc(rob_rd_is_rvc),
    .cm_idx(rob_commit_uop_ftq_idx), .cm_off(rob_commit_uop_ftq_offset),
    .cm_pc(cm_rd_pc), .cm_pred_taken(cm_rd_pred_taken), .cm_is_rvc(cm_rd_is_rvc), .cm_next_pc(cm_rd_next_pc),
    .dis_idx(ftq_dis_req_ftq_idx), .dis_off(ftq_dis_req_ftq_offset),
    .dis_pc(dis_pc), .dis_is_rvc(dis_is_rvc)
  );

  ftq_meta u_meta (
    .clk, .rst_n,
    .wr_en         (s2_wr_eff),
    .wr_idx        (s2_ptr),
    .wr_blk_id     (fe2ftq_s2.blk_id),
    .wr_meta       (s2_meta),
    .next_comm_ptr (next_comm_ptr),
    .rd_idx        (rob_commit_uop_ftq_idx),
    .rd_offset     (rob_commit_uop_ftq_offset),
    .rd_meta, .rd_blk_id
  );

  ftq_bpu u_bpu (
    .clk,
    .s2_wr_en   (s2_wr_eff),
    .s2_idx     (s2_ptr),
    .s2_blk_id  (fe2ftq_s2.blk_id),
    .pd_fire    (pd_fire_eff),
    .pd_idx     (pd_ptr),
    .pd_kind    (fe2ftq_pd.slot_kind),
    .rd_idx     (br_redirect_ftq_idx),
    .rd_offset  (br_redirect_ftq_offset),
    .rd_blk     (out_rf_blk),
    .rd_type    (out_rf_type)
  );

  // ---- registered frontend feedback bundle ----
  always_comb begin
    ftq2fe.ftq_full        = ftq_full;
    ftq2fe.ifu_empty       = ifu_empty;
    ftq2fe.ifu_cnt_sat     = ifu_cnt_sat;
    ftq2fe.s2_empty        = s2_empty;
    ftq2fe.ifu_addr        = ifu_addr;
    ftq2fe.ifu_next_set_idx = ifu_next_set_idx;
    ftq2fe.pd_idx          = pd_ptr;
    ftq2fe.pd_base_pc      = pd_base_pc;
    ftq2fe.pd_pred_dir     = pd_out_pred_dir;
    ftq2fe.pd_next_pc      = pd_out_next_pc;
  end

  // ---- outputs ----
  assign ftq_head_out    = comm_ptr;
  assign ftq2front_ready = ready;
  always_comb begin
    for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) ftq2front_fire[i] = fire[i];
    for (int i = 0; i < DECODE_WIDTH; i++) begin
      ibuf2idu_valid[i] = issue_valid[i];
      ibuf2idu_entry[i] = issue_entry[i];
    end
    for (int p = 0; p < FTQ_PRF_PC_PORT_NUM; p++) begin
      ftq_prf_pc_resp_pc[p]         = prf_rd_pc[p];
      ftq_prf_pc_resp_pred_taken[p] = prf_rd_pred_taken[p];
      ftq_prf_pc_resp_is_rvc[p]     = prf_rd_is_rvc[p];
      ftq_prf_pc_resp_next_pc[p]    = prf_rd_next_pc[p];
    end
    for (int p = 0; p < FTQ_ROB_PC_PORT_NUM; p++) begin
      ftq_rob_pc_resp_pc[p]     = rob_rd_pc;
      ftq_rob_pc_resp_is_rvc[p] = rob_rd_is_rvc;
    end
    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      ftq_commit_info_resp_valid[i]      = commit_valid[i];
      ftq_commit_info_resp_pc[i]         = cm_rd_pc[i];
      ftq_commit_info_resp_next_pc[i]    = cm_rd_next_pc[i];
      ftq_commit_info_resp_pred_taken[i] = cm_rd_pred_taken[i];
      ftq_commit_info_resp_is_rvc[i]     = cm_rd_is_rvc[i];
      ftq_commit_info_resp_alt_pred[i]   = rd_meta[i].alt_pred;
      ftq_commit_info_resp_pcpn[i]       = rd_meta[i].pcpn;
      ftq_commit_info_resp_blk_id[i]     = rd_blk_id[i];
    end
  end

endmodule

`default_nettype wire
