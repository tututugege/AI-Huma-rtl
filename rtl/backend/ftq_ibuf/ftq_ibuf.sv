// Ref: back-end/PreIduQueue.cpp  class PreIduQueue (+ InstructionBuffer.cpp, include/FTQ.h)
`default_nettype none

// FTQ + IBuf top: port adapter only. Packs the flat spec ports into the internal structs and instantiates
//   ftq_ibuf_ctrl    front-end handshake, group compaction ranks, pop counts
//   ibuf             instruction ring buffer (feeds the Idu issue group)
//   ftq_ptr          FTQ allocation pointer / occupancy
//   ftq_pc           FTQ pc storage with Prf / Rob / commit lookup ports
//   ftq_meta         FTQ training-metadata storage with commit read ports
module ftq_ibuf import ttg_cfg_pkg::*; import ftq_ibuf_pkg::*; import front_pkg::KIND_W;
  import bpu_types_pkg::FTB_BLK_ID_W; (
  input  logic clk,
  input  logic rst_n,
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2ftq_valid,
  input  logic [31:0] front2ftq_inst [BACKEND_FETCH_WIDTH],
  input  logic [XLEN_BITS-1:0] front2ftq_pc [BACKEND_FETCH_WIDTH],
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2ftq_page_fault_inst,
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2ftq_pf_inst_hi,
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2ftq_predict_dir,
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2ftq_alt_pred,
  input  logic [PCPN_W-1:0] front2ftq_pcpn [BACKEND_FETCH_WIDTH],
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2ftq_is_rvc,
  input  logic [XLEN_BITS-1:0] front2ftq_predict_next_fetch_address,
  input  logic [BLK_ID_W-1:0] front2ftq_blk_id,
  input  logic front2ftq_is_pair,
  input  logic [3:0] front2ftq_a_len,
  input  logic [FETCH_WIDTH-1:0][KIND_W-1:0] front2ftq_slot_kind,
  input  logic [DECODE_WIDTH-1:0] idu_consume_fire,
  input  logic br_redirect_mispred,
  input  logic [FTQ_IDX_WIDTH-1:0] br_redirect_ftq_idx,
  input  logic [FTQ_OFFSET_WIDTH-1:0] br_redirect_ftq_offset,
  input  logic [XLEN_BITS-1:0] br_redirect_pc,
  input  logic rob_bcast_flush,
  input  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_valid,
  input  logic [FTQ_IDX_WIDTH-1:0] rob_commit_commit_entry_uop_ftq_idx [COMMIT_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] rob_commit_commit_entry_uop_ftq_offset [COMMIT_WIDTH],
  input  logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_ftq_is_last,
  input  logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_req_req_valid,
  input  logic [FTQ_IDX_WIDTH-1:0] ftq_prf_pc_req_req_ftq_idx [FTQ_PRF_PC_PORT_NUM],
  input  logic [FTQ_OFFSET_WIDTH-1:0] ftq_prf_pc_req_req_ftq_offset [FTQ_PRF_PC_PORT_NUM],
  input  logic [FTQ_ROB_PC_PORT_NUM-1:0] ftq_rob_pc_req_req_valid,
  input  logic [FTQ_IDX_WIDTH-1:0] ftq_rob_pc_req_req_ftq_idx [FTQ_ROB_PC_PORT_NUM],
  input  logic [FTQ_OFFSET_WIDTH-1:0] ftq_rob_pc_req_req_ftq_offset [FTQ_ROB_PC_PORT_NUM],
  // wait-table index (PC hash) of the instructions entering dispatch (LSU_MEMSPEC; zero otherwise)
  /* verilator lint_off UNUSEDSIGNAL */  // the request ports are used only with LSU_MEMSPEC
  input  logic [FTQ_IDX_WIDTH-1:0] ftq_dis_req_ftq_idx [DECODE_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] ftq_dis_req_ftq_offset [DECODE_WIDTH],
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [LSU_MDP_BITS-1:0] ftq_dis_resp_mdp [DECODE_WIDTH],
  output logic [31:0] ftq_dis_resp_pc [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0] ftq_dis_resp_is_rvc,
  output logic [FTB_BLK_ID_W-1:0] out_rf_blk,
  output logic [2:0] out_rf_type,
  output logic ftq2front_ready,
  output logic [BACKEND_FETCH_WIDTH-1:0] ftq2front_fire,
  output logic [DECODE_WIDTH-1:0] ibuf2idu_valid,
  output ib_entry_t ibuf2idu_entry [DECODE_WIDTH],
  output logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_resp_resp_valid,
  output logic [XLEN_BITS-1:0] ftq_prf_pc_resp_resp_pc [FTQ_PRF_PC_PORT_NUM],
  output logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_resp_resp_pred_taken,
  output logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_resp_resp_is_rvc,
  output logic [XLEN_BITS-1:0] ftq_prf_pc_resp_resp_next_pc [FTQ_PRF_PC_PORT_NUM],
  output logic [FTQ_ROB_PC_PORT_NUM-1:0] ftq_rob_pc_resp_resp_valid,
  output logic [XLEN_BITS-1:0] ftq_rob_pc_resp_resp_pc [FTQ_ROB_PC_PORT_NUM],
  output logic [FTQ_ROB_PC_PORT_NUM-1:0] ftq_rob_pc_resp_resp_is_rvc,
  output logic [COMMIT_WIDTH-1:0] ftq_commit_info_resp_valid,
  output logic [XLEN_BITS-1:0] ftq_commit_info_resp_pc [COMMIT_WIDTH],
  output logic [XLEN_BITS-1:0] ftq_commit_info_resp_next_pc [COMMIT_WIDTH],
  output logic ftq_commit_info_resp_pred_taken [COMMIT_WIDTH],
  output logic ftq_commit_info_resp_is_rvc [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0] ftq_commit_info_resp_alt_pred,
  output logic [PCPN_W-1:0] ftq_commit_info_resp_pcpn [COMMIT_WIDTH],
  output logic [BLK_ID_W-1:0] ftq_commit_info_resp_blk_id [COMMIT_WIDTH]
);

  // ---- flat spec ports <-> internal vectors / structs ----
  logic [BACKEND_FETCH_WIDTH-1:0] front_valid;
  logic [BACKEND_FETCH_WIDTH-1:0] front_pred_taken;
  logic [BACKEND_FETCH_WIDTH-1:0] front_is_rvc;
  logic [DECODE_WIDTH-1:0]        idu_fire;
  logic [COMMIT_WIDTH-1:0]        commit_valid;
  logic [COMMIT_WIDTH-1:0]        commit_is_last;
  logic [XLEN_BITS-1:0]                    front_slot_pc [BACKEND_FETCH_WIDTH];
  ftq_meta_t                      wr_meta [BACKEND_FETCH_WIDTH];
  ib_entry_t                      push_entry [BACKEND_FETCH_WIDTH];
  ib_entry_t                      issue_entry [DECODE_WIDTH];
  ftq_meta_t                      rd_meta [COMMIT_WIDTH];
  logic [BLK_ID_W-1:0]            rd_blk_id [COMMIT_WIDTH];
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
  logic                           alloc;
  logic [LANE_CNT_W-1:0]          lane_rank [BACKEND_FETCH_WIDTH];
  logic [BACKEND_FETCH_WIDTH-1:0] lane_is_last;
  logic [LANE_CNT_W-1:0]          push_cnt;
  logic                           queue_clear;
  logic [DECODE_CNT_W-1:0]        ib_pop_cnt;
  logic [COMMIT_CNT_W-1:0]        ftq_pop_cnt;
  logic [FTQ_IDX_WIDTH-1:0]       ftq_head;
  logic [FTQ_IDX_WIDTH-1:0]       ftq_tail;
  logic [FTQ_COUNT_W-1:0]         ftq_count;
  logic [IB_COUNT_W-1:0]          ib_count;

  // Ref: wiring only (spec port <-> struct field)
  always_comb begin
    for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) begin
      front_valid[i]     = front2ftq_valid[i];
      front_pred_taken[i] = front2ftq_predict_dir[i];
      front_is_rvc[i]    = front2ftq_is_rvc[i];
      front_slot_pc[i]   = front2ftq_pc[i];
      wr_meta[i].alt_pred  = front2ftq_alt_pred[i];
      wr_meta[i].pcpn      = front2ftq_pcpn[i];
      push_entry[i].inst            = front2ftq_inst[i];
      push_entry[i].page_fault_inst = front2ftq_page_fault_inst[i];
      push_entry[i].pf_inst_hi      = front2ftq_pf_inst_hi[i];
      push_entry[i].ftq_idx         = ftq_tail;
      push_entry[i].ftq_offset      = FTQ_OFFSET_WIDTH'(i);
      push_entry[i].ftq_is_last     = lane_is_last[i];
    end
    for (int i = 0; i < DECODE_WIDTH; i++) idu_fire[i] = idu_consume_fire[i];
    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      commit_valid[i]   = rob_commit_commit_entry_valid[i];
      commit_is_last[i] = rob_commit_commit_entry_uop_ftq_is_last[i];
    end
  end

  logic [31:0]          dis_pc [DECODE_WIDTH];
  logic                 dis_is_rvc [DECODE_WIDTH];
  always_comb begin
    for (int p = 0; p < DECODE_WIDTH; p++) begin
      ftq_dis_resp_is_rvc[p] = dis_is_rvc[p];
      ftq_dis_resp_pc[p]     = dis_pc[p];
    end
  end
  for (genvar p = 0; p < DECODE_WIDTH; p++) begin : g_dis_pc
    if (LSU_MEMSPEC != 0) begin : g_on
      // wait-table index of the load PC: pc[S+B-1:S] ^ pc[S+2B-1:S+B] (model mdp_idx)
      assign ftq_dis_resp_mdp[p] = dis_pc[p][SLOT_SHIFT +: LSU_MDP_BITS] ^
                                   dis_pc[p][SLOT_SHIFT + LSU_MDP_BITS +: LSU_MDP_BITS];
    end else begin : g_off
      /* verilator lint_off UNUSEDSIGNAL */
      logic unused;
      assign unused = ^dis_pc[p];
      /* verilator lint_on UNUSEDSIGNAL */
      assign ftq_dis_resp_mdp[p] = '0;
    end
  end

  ftq_ibuf_ctrl u_ctrl (
    .clk, .rst_n,
    .front_valid, .br_mispred(br_redirect_mispred), .rob_flush(rob_bcast_flush),
    .ftq_count, .ib_count, .idu_fire, .commit_valid, .commit_is_last,
    .ready, .fire, .alloc, .lane_rank, .lane_is_last, .push_cnt, .queue_clear, .ib_pop_cnt, .ftq_pop_cnt
  );

  ibuf u_ibuf (
    .clk, .rst_n, .clear(queue_clear), .pop_cnt(ib_pop_cnt), .push_cnt, .push_en(fire), .push_rank(lane_rank),
    .push_entry, .count(ib_count), .issue_valid, .issue_entry
  );

  ftq_ptr u_ptr (
    .clk, .rst_n, .alloc, .flush(rob_bcast_flush), .recover(br_redirect_mispred),
    .recover_idx(br_redirect_ftq_idx), .pop_cnt(ftq_pop_cnt), .head(ftq_head), .tail(ftq_tail), .count(ftq_count)
  );

  ftq_pc u_pc (
    .clk, .wr_en(alloc), .wr_idx(ftq_tail), .wr_valid(front_valid), .wr_slot_pc(front_slot_pc),
    .wr_pred_taken(front_pred_taken), .wr_is_rvc(front_is_rvc),
    .wr_is_pair(front2ftq_is_pair), .wr_a_len(front2ftq_a_len),
    .wr_next_pc(front2ftq_predict_next_fetch_address),
    .mispred_en(br_redirect_mispred), .mispred_idx(br_redirect_ftq_idx),
    .mispred_off(br_redirect_ftq_offset), .mispred_target(br_redirect_pc),
    .ftq_head(ftq_head),
    .prf_idx(ftq_prf_pc_req_req_ftq_idx), .prf_off(ftq_prf_pc_req_req_ftq_offset),
    .prf_pc(prf_rd_pc), .prf_pred_taken(prf_rd_pred_taken), .prf_is_rvc(prf_rd_is_rvc), .prf_next_pc(prf_rd_next_pc),
    .rob_idx(ftq_rob_pc_req_req_ftq_idx[0]), .rob_off(ftq_rob_pc_req_req_ftq_offset[0]),
    .rob_pc(rob_rd_pc), .rob_is_rvc(rob_rd_is_rvc),
    .cm_idx(rob_commit_commit_entry_uop_ftq_idx), .cm_off(rob_commit_commit_entry_uop_ftq_offset),
    .cm_pc(cm_rd_pc), .cm_pred_taken(cm_rd_pred_taken), .cm_is_rvc(cm_rd_is_rvc), .cm_next_pc(cm_rd_next_pc),
    .dis_idx(ftq_dis_req_ftq_idx), .dis_off(ftq_dis_req_ftq_offset),
    .dis_pc(dis_pc), .dis_is_rvc(dis_is_rvc)
  );

  ftq_meta u_meta (
    .clk, .wr_en(alloc), .wr_idx(ftq_tail),
    .wr_blk_id(front2ftq_blk_id), .wr_is_pair(front2ftq_is_pair), .wr_a_len(front2ftq_a_len), .wr_meta,
    .ftq_head(ftq_head),
    .rd_idx(rob_commit_commit_entry_uop_ftq_idx), .rd_offset(rob_commit_commit_entry_uop_ftq_offset),
    .rd_meta, .rd_blk_id
  );

  ftq_bpu u_bpu (
    .clk, .wr_en(alloc), .wr_idx(ftq_tail),
    .wr_blk_id(front2ftq_blk_id), .wr_is_pair(front2ftq_is_pair), .wr_a_len(front2ftq_a_len),
    .wr_kind(front2ftq_slot_kind),
    .rd_idx(br_redirect_ftq_idx), .rd_offset(br_redirect_ftq_offset),
    .rd_blk(out_rf_blk), .rd_type(out_rf_type)
  );

  // ---- outputs ----
  assign ftq2front_ready = ready;
  always_comb begin
    for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) ftq2front_fire[i] = fire[i];
    for (int i = 0; i < DECODE_WIDTH; i++) begin
      ibuf2idu_valid[i] = issue_valid[i];
      ibuf2idu_entry[i] = issue_entry[i];
    end
    // resp.valid is the request valid; the spec qualifiers ftq_commit_info_resp_valid* mirror the commit valid
    for (int p = 0; p < FTQ_PRF_PC_PORT_NUM; p++) begin
      ftq_prf_pc_resp_resp_valid[p]      = ftq_prf_pc_req_req_valid[p];
      ftq_prf_pc_resp_resp_pc[p]         = prf_rd_pc[p];
      ftq_prf_pc_resp_resp_pred_taken[p] = prf_rd_pred_taken[p];
      ftq_prf_pc_resp_resp_is_rvc[p]     = prf_rd_is_rvc[p];
      ftq_prf_pc_resp_resp_next_pc[p]    = prf_rd_next_pc[p];
    end
    for (int p = 0; p < FTQ_ROB_PC_PORT_NUM; p++) begin
      ftq_rob_pc_resp_resp_valid[p] = ftq_rob_pc_req_req_valid[p];
      ftq_rob_pc_resp_resp_pc[p]    = rob_rd_pc;
      ftq_rob_pc_resp_resp_is_rvc[p] = rob_rd_is_rvc;
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
