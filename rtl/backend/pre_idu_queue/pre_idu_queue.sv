// Ref: back-end/PreIduQueue.cpp  class PreIduQueue (+ InstructionBuffer.cpp, include/FTQ.h)
`default_nettype none

// PreIduQueue: port adapter only. Packs the flat spec ports into the internal structs and instantiates
//   pre_idu_ctrl     front-end handshake, group compaction ranks, pop counts
//   pre_idu_ibuf     instruction ring buffer (feeds the Idu issue group)
//   pre_idu_ftq_ptr  FTQ allocation pointer / occupancy
//   pre_idu_ftq_pc   FTQ pc storage with Prf / Rob / commit lookup ports
//   pre_idu_ftq_meta FTQ training-metadata storage with commit read ports
module pre_idu_queue import ttg_cfg_pkg::*; import pre_idu_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2pre_valid,
  input  logic [31:0] front2pre_inst [BACKEND_FETCH_WIDTH],
  input  logic [31:0] front2pre_pc [BACKEND_FETCH_WIDTH],
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2pre_page_fault_inst,
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2pre_predict_dir,
  input  logic [BACKEND_FETCH_WIDTH-1:0] front2pre_alt_pred,
  input  logic [PCPN_W-1:0] front2pre_altpcpn [BACKEND_FETCH_WIDTH],
  input  logic [PCPN_W-1:0] front2pre_pcpn [BACKEND_FETCH_WIDTH],
  input  logic [31:0] front2pre_predict_next_fetch_address,
  input  logic [TAGE_IDX_W-1:0] front2pre_tage_idx [BACKEND_FETCH_WIDTH] [TAGE_N],
  input  logic [TAGE_TAG_W-1:0] front2pre_tage_tag [BACKEND_FETCH_WIDTH] [TAGE_N],
  input  logic [DECODE_WIDTH-1:0] idu_consume_fire,
  input  logic idu_br_latch_mispred,
  input  logic [FTQ_IDX_WIDTH-1:0] idu_br_latch_ftq_idx,
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
  output logic pre2front_ready,
  output logic [BACKEND_FETCH_WIDTH-1:0] pre2front_fire,
  output logic [DECODE_WIDTH-1:0] pre_issue_entries_valid,
  output logic [31:0] pre_issue_entries_inst [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0] pre_issue_entries_page_fault_inst,
  output logic [FTQ_IDX_WIDTH-1:0] pre_issue_entries_ftq_idx [DECODE_WIDTH],
  output logic [FTQ_OFFSET_WIDTH-1:0] pre_issue_entries_ftq_offset [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0] pre_issue_entries_ftq_is_last,
  output logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_resp_resp_valid,
  output logic [31:0] ftq_prf_pc_resp_resp_pc [FTQ_PRF_PC_PORT_NUM],
  output logic [FTQ_PRF_PC_PORT_NUM-1:0] ftq_prf_pc_resp_resp_pred_taken,
  output logic [31:0] ftq_prf_pc_resp_resp_next_pc [FTQ_PRF_PC_PORT_NUM],
  output logic [FTQ_ROB_PC_PORT_NUM-1:0] ftq_rob_pc_resp_resp_valid,
  output logic [31:0] ftq_rob_pc_resp_resp_pc [FTQ_ROB_PC_PORT_NUM],
  output logic [COMMIT_WIDTH-1:0][TAGE_N-1:0] ftq_commit_info_resp_valid_t,
  output logic [COMMIT_WIDTH-1:0] ftq_commit_info_resp_valid,
  output logic [31:0] ftq_commit_info_resp_pc [COMMIT_WIDTH],
  output logic ftq_commit_info_resp_pred_taken [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0] ftq_commit_info_resp_alt_pred,
  output logic [PCPN_W-1:0] ftq_commit_info_resp_altpcpn [COMMIT_WIDTH],
  output logic [PCPN_W-1:0] ftq_commit_info_resp_pcpn [COMMIT_WIDTH],
  output logic [TAGE_IDX_W-1:0] ftq_commit_info_resp_tage_idx [COMMIT_WIDTH] [TAGE_N],
  output logic [TAGE_TAG_W-1:0] ftq_commit_info_resp_tage_tag [COMMIT_WIDTH] [TAGE_N]
);

  localparam int NPORT_PC = FTQ_PRF_PC_PORT_NUM + FTQ_ROB_PC_PORT_NUM + COMMIT_WIDTH;
  localparam int PORT_ROB = FTQ_PRF_PC_PORT_NUM;
  localparam int PORT_COMMIT = FTQ_PRF_PC_PORT_NUM + FTQ_ROB_PC_PORT_NUM;

  // ---- flat spec ports <-> internal vectors / structs ----
  logic [BACKEND_FETCH_WIDTH-1:0] front_valid;
  logic [BACKEND_FETCH_WIDTH-1:0] front_pred_taken;
  logic [DECODE_WIDTH-1:0]        idu_fire;
  logic [COMMIT_WIDTH-1:0]        commit_valid;
  logic [COMMIT_WIDTH-1:0]        commit_is_last;
  logic [31:0]                    front_slot_pc [BACKEND_FETCH_WIDTH];
  ftq_meta_t                      wr_meta [BACKEND_FETCH_WIDTH];
  ib_entry_t                      push_entry [BACKEND_FETCH_WIDTH];
  ib_entry_t                      issue_entry [DECODE_WIDTH];
  ftq_meta_t                      rd_meta [COMMIT_WIDTH];
  logic [DECODE_WIDTH-1:0]        issue_valid;

  logic [FTQ_IDX_WIDTH-1:0]       pc_rd_idx [NPORT_PC];
  logic [FTQ_OFFSET_WIDTH-1:0]    pc_rd_offset [NPORT_PC];
  logic [31:0]                    pc_rd_pc [NPORT_PC];
  logic                           pc_rd_pred_taken [NPORT_PC];
  logic [31:0]                    pc_rd_next_pc [NPORT_PC];

  logic                           ready;
  logic [BACKEND_FETCH_WIDTH-1:0] fire;
  logic                           alloc;
  logic [LANE_CNT_W-1:0]          lane_rank [BACKEND_FETCH_WIDTH];
  logic [BACKEND_FETCH_WIDTH-1:0] lane_is_last;
  logic [LANE_CNT_W-1:0]          push_cnt;
  logic                           queue_clear;
  logic [DECODE_CNT_W-1:0]        ib_pop_cnt;
  logic [COMMIT_CNT_W-1:0]        ftq_pop_cnt;
  logic [FTQ_IDX_WIDTH-1:0]       ftq_tail;
  logic [FTQ_COUNT_W-1:0]         ftq_count;
  logic [IB_COUNT_W-1:0]          ib_count;

  // Ref: wiring only (spec port <-> struct field)
  always_comb begin
    for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) begin
      front_valid[i]     = front2pre_valid[i];
      front_pred_taken[i] = front2pre_predict_dir[i];
      front_slot_pc[i]   = front2pre_pc[i];
      wr_meta[i].alt_pred  = front2pre_alt_pred[i];
      wr_meta[i].altpcpn   = front2pre_altpcpn[i];
      wr_meta[i].pcpn      = front2pre_pcpn[i];
      for (int k = 0; k < TAGE_N; k++) begin
        wr_meta[i].tage_idx[k] = front2pre_tage_idx[i][k];
        wr_meta[i].tage_tag[k] = front2pre_tage_tag[i][k];
      end
      push_entry[i].inst            = front2pre_inst[i];
      push_entry[i].page_fault_inst = front2pre_page_fault_inst[i];
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

  // Ref: FTQ pc read ports: Prf ports, then the Rob port, then one per commit slot
  always_comb begin
    for (int p = 0; p < FTQ_PRF_PC_PORT_NUM; p++) begin
      pc_rd_idx[p]    = ftq_prf_pc_req_req_ftq_idx[p];
      pc_rd_offset[p] = ftq_prf_pc_req_req_ftq_offset[p];
    end
    for (int p = 0; p < FTQ_ROB_PC_PORT_NUM; p++) begin
      pc_rd_idx[PORT_ROB+p]    = ftq_rob_pc_req_req_ftq_idx[p];
      pc_rd_offset[PORT_ROB+p] = ftq_rob_pc_req_req_ftq_offset[p];
    end
    for (int p = 0; p < COMMIT_WIDTH; p++) begin
      pc_rd_idx[PORT_COMMIT+p]    = rob_commit_commit_entry_uop_ftq_idx[p];
      pc_rd_offset[PORT_COMMIT+p] = rob_commit_commit_entry_uop_ftq_offset[p];
    end
  end

  pre_idu_ctrl u_ctrl (
    .clk, .rst_n,
    .front_valid, .br_mispred(idu_br_latch_mispred), .rob_flush(rob_bcast_flush),
    .ftq_count, .ib_count, .idu_fire, .commit_valid, .commit_is_last,
    .ready, .fire, .alloc, .lane_rank, .lane_is_last, .push_cnt, .queue_clear, .ib_pop_cnt, .ftq_pop_cnt
  );

  pre_idu_ibuf u_ibuf (
    .clk, .rst_n, .clear(queue_clear), .pop_cnt(ib_pop_cnt), .push_cnt, .push_en(fire), .push_rank(lane_rank),
    .push_entry, .count(ib_count), .issue_valid, .issue_entry
  );

  pre_idu_ftq_ptr u_ptr (
    .clk, .rst_n, .alloc, .flush(rob_bcast_flush), .recover(idu_br_latch_mispred),
    .recover_idx(idu_br_latch_ftq_idx), .pop_cnt(ftq_pop_cnt), .tail(ftq_tail), .count(ftq_count)
  );

  pre_idu_ftq_pc u_pc (
    .clk, .wr_en(alloc), .wr_idx(ftq_tail), .wr_slot_pc(front_slot_pc), .wr_pred_taken(front_pred_taken),
    .wr_next_pc(front2pre_predict_next_fetch_address),
    .rd_idx(pc_rd_idx), .rd_offset(pc_rd_offset), .rd_pc(pc_rd_pc), .rd_pred_taken(pc_rd_pred_taken),
    .rd_next_pc(pc_rd_next_pc)
  );

  pre_idu_ftq_meta u_meta (
    .clk, .wr_en(alloc), .wr_idx(ftq_tail), .wr_meta,
    .rd_idx(rob_commit_commit_entry_uop_ftq_idx), .rd_offset(rob_commit_commit_entry_uop_ftq_offset), .rd_meta
  );

  // ---- outputs ----
  assign pre2front_ready = ready;
  always_comb begin
    for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) pre2front_fire[i] = fire[i];
    for (int i = 0; i < DECODE_WIDTH; i++) begin
      pre_issue_entries_valid[i]           = issue_valid[i];
      pre_issue_entries_inst[i]            = issue_entry[i].inst;
      pre_issue_entries_page_fault_inst[i] = issue_entry[i].page_fault_inst;
      pre_issue_entries_ftq_idx[i]         = issue_entry[i].ftq_idx;
      pre_issue_entries_ftq_offset[i]      = issue_entry[i].ftq_offset;
      pre_issue_entries_ftq_is_last[i]     = issue_entry[i].ftq_is_last;
    end
    // resp.valid is the request valid; the spec qualifiers ftq_commit_info_resp_valid* mirror the commit valid
    for (int p = 0; p < FTQ_PRF_PC_PORT_NUM; p++) begin
      ftq_prf_pc_resp_resp_valid[p]      = ftq_prf_pc_req_req_valid[p];
      ftq_prf_pc_resp_resp_pc[p]         = pc_rd_pc[p];
      ftq_prf_pc_resp_resp_pred_taken[p] = pc_rd_pred_taken[p];
      ftq_prf_pc_resp_resp_next_pc[p]    = pc_rd_next_pc[p];
    end
    for (int p = 0; p < FTQ_ROB_PC_PORT_NUM; p++) begin
      ftq_rob_pc_resp_resp_valid[p] = ftq_rob_pc_req_req_valid[p];
      ftq_rob_pc_resp_resp_pc[p]    = pc_rd_pc[PORT_ROB+p];
    end
    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      ftq_commit_info_resp_valid[i]      = commit_valid[i];
      ftq_commit_info_resp_pc[i]         = pc_rd_pc[PORT_COMMIT+i];
      ftq_commit_info_resp_pred_taken[i] = pc_rd_pred_taken[PORT_COMMIT+i];
      ftq_commit_info_resp_alt_pred[i]   = rd_meta[i].alt_pred;
      ftq_commit_info_resp_altpcpn[i]    = rd_meta[i].altpcpn;
      ftq_commit_info_resp_pcpn[i]       = rd_meta[i].pcpn;
      for (int k = 0; k < TAGE_N; k++) begin
        ftq_commit_info_resp_valid_t[i][k]  = commit_valid[i];
        ftq_commit_info_resp_tage_idx[i][k] = rd_meta[i].tage_idx[k];
        ftq_commit_info_resp_tage_tag[i][k] = rd_meta[i].tage_tag[k];
      end
    end
  end

endmodule

`default_nettype wire
