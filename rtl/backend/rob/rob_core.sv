// Ref: back-end/Rob.cpp  class Rob  (comb_ready .. comb_flush + seq as one data flow)
`default_nettype none

module rob_core
  import ttg_cfg_pkg::*;
  import rob_pkg::*;
(
  input  logic                       clk,
  input  logic                       rst_n,
  // inputs
  input  logic                       dec_mispred,
  input  logic [ROB_IDX_WIDTH-1:0]   dec_redirect_rob_idx,
  input  logic                       interrupt_req,
  input  logic                       committed_store_pending,
  input  logic                       front_stall,
  input  logic [ROB_XLEN-1:0]            ftq_resp_pc,
  input  logic [ROB_BANK_NUM-1:0]    dis_fire,
  input  rob_entry_t                 dis_uop [ROB_BANK_NUM],
  input  rob_wb_t                    wb [ISSUE_WIDTH],
  // rob2dis
  output logic                       rob2dis_stall,
  output logic                       rob2dis_empty,
  output logic                       rob2dis_ready,
  output logic [ROB_LINE_IDX_W-1:0]  rob2dis_enq_line,
  output logic                       rob2dis_rob_flag,
  // rob2csr
  output logic                       rob2csr_commit,
  output logic                       rob2csr_interrupt_resp,
  // rob_commit
  output logic [ROB_BANK_NUM-1:0]    commit_valid,
  output rob_entry_t                 commit_uop [ROB_BANK_NUM],
  // rob_bcast
  output logic                       bcast_flush,
  output logic                       bcast_mret,
  output logic                       bcast_sret,
  output logic                       bcast_ecall,
  output logic                       bcast_breakpoint,
  output logic                       bcast_exception,
  output logic                       bcast_fence,
  output logic                       bcast_fence_i,
  output logic                       bcast_page_fault_inst,
  output logic                       bcast_page_fault_load,
  output logic                       bcast_page_fault_store,
  output logic                       bcast_illegal_inst,
  output logic                       bcast_interrupt,
  output logic                       bcast_trap_val_valid,
  output logic [ROB_XLEN-1:0]            bcast_trap_val,
  output logic [ROB_XLEN-1:0]            bcast_pc,
  output logic [ROB_IDX_WIDTH-1:0]   bcast_head_rob_idx,
  output logic                       bcast_head_valid,
  output logic [ROB_IDX_WIDTH-1:0]   bcast_head_incomplete_rob_idx,
  output logic                       bcast_head_incomplete_valid,
  // ftq_pc_req
  output logic                       ftq_req_valid,
  output logic [FTQ_IDX_WIDTH-1:0]   ftq_req_ftq_idx,
  output logic [FTQ_OFFSET_WIDTH-1:0] ftq_req_ftq_offset
);

  // pointers
  logic [ROB_LINE_IDX_W-1:0] enq_ptr, deq_ptr;
  logic                      enq_flag, full;
  logic [ROB_LINE_NUM-1:0]   enq_line_onehot, deq_line_onehot;
  // head line
  logic [ROB_BANK_NUM-1:0]   head_valid, head_complete, head_flush, head_fence, head_wfi;
  rob_entry_t                head_uop [ROB_BANK_NUM];
  // commit decision
  logic [ROB_BANK_NUM-1:0]   first_valid;
  logic                      single_commit, interrupt_fire, deq_advance;
  rob_entry_t                single_uop;
  logic [ROB_ENTRY_W-1:0]    head_bits [ROB_BANK_NUM];
  logic [ROB_ENTRY_W-1:0]    single_bits;
  // flush / write-back / recovery / enqueue
  logic                      flush_w;
  rob_event_t                wb_ev [ISSUE_WIDTH];
  logic [ROB_LINE_NUM-1:0]   branch_clr [ROB_BANK_NUM];
  logic [ROB_LINE_NUM-1:0]   mark_last  [ROB_BANK_NUM];
  logic                      recover;
  logic [ROB_BANK_NUM-1:0]   fire_bank;
  logic                      enq_any;

  // Rob::comb_ready
  assign rob2dis_ready    = !full;
  assign fire_bank        = dis_fire & {ROB_BANK_NUM{rob2dis_ready}};
  assign enq_any          = |fire_bank;
  assign recover          = dec_mispred && !flush_w;
  assign rob2dis_enq_line = enq_ptr;
  assign rob2dis_rob_flag = enq_flag;
  assign bcast_flush      = flush_w;
  assign bcast_interrupt  = interrupt_fire;
  assign rob2csr_interrupt_resp = interrupt_fire;

  rob_ptr u_ptr (
    .clk(clk), .rst_n(rst_n), .flush(flush_w), .recover(recover),
    .redirect_line(dec_redirect_rob_idx[ROB_IDX_WIDTH-1:ROB_BANK_IDX_W]),
    .enq_any(enq_any), .deq_advance(deq_advance),
    .enq_ptr(enq_ptr), .deq_ptr(deq_ptr), .enq_flag(enq_flag),
    .empty(rob2dis_empty), .full(full),
    .enq_line_onehot(enq_line_onehot), .deq_line_onehot(deq_line_onehot)
  );

  rob_wb_decode u_wb_decode (.wb(wb), .wb_ev(wb_ev));

  rob_branch_recovery u_recovery (
    .recover(recover), .redirect_rob_idx(dec_redirect_rob_idx), .enq_ptr(enq_ptr),
    .branch_clr(branch_clr), .mark_last(mark_last)
  );

  rob_store u_store (
    .clk(clk), .rst_n(rst_n), .flush(flush_w),
    .enq_line_onehot(enq_line_onehot), .deq_line_onehot(deq_line_onehot),
    .fire_bank(fire_bank), .fire_uop(dis_uop),
    .commit_clr_bank(commit_valid), .branch_clr(branch_clr), .mark_last(mark_last),
    .wb_ev(wb_ev), .head_valid(head_valid), .head_uop(head_uop)
  );

  rob_head_class u_class (
    .head_uop(head_uop), .is_complete(head_complete), .is_flush(head_flush),
    .is_fence(head_fence), .is_wfi(head_wfi)
  );

  rob_head_info u_head_info (
    .empty(rob2dis_empty), .deq_ptr(deq_ptr), .head_valid(head_valid), .head_complete(head_complete),
    .head_flush(head_flush), .head_uop(head_uop),
    .rob2dis_stall(rob2dis_stall),
    .ftq_req_valid(ftq_req_valid), .ftq_req_ftq_idx(ftq_req_ftq_idx), .ftq_req_ftq_offset(ftq_req_ftq_offset),
    .bcast_head_valid(bcast_head_valid), .bcast_head_rob_idx(bcast_head_rob_idx),
    .bcast_head_incomplete_valid(bcast_head_incomplete_valid),
    .bcast_head_incomplete_rob_idx(bcast_head_incomplete_rob_idx)
  );

  rob_commit_ctrl u_commit (
    .empty(rob2dis_empty), .mispred(dec_mispred), .front_stall(front_stall), .interrupt_req(interrupt_req),
    .committed_store_pending(committed_store_pending),
    .head_valid(head_valid), .head_complete(head_complete), .head_flush(head_flush),
    .head_fence(head_fence), .head_wfi(head_wfi),
    .commit_valid(commit_valid), .single_commit(single_commit), .first_valid(first_valid),
    .interrupt_fire(interrupt_fire), .deq_advance(deq_advance)
  );

  // the single-commit instruction is the first valid slot of the head line
  for (genvar b = 0; b < ROB_BANK_NUM; b++) begin : g_head_bits
    assign head_bits[b]   = head_uop[b];
    assign commit_uop[b]  = head_uop[b];
  end
  ttg_onehot_mux #(.N(ROB_BANK_NUM), .W(ROB_ENTRY_W)) u_single_mux (
    .sel(first_valid), .data(head_bits), .out(single_bits)
  );
  assign single_uop = single_bits;

  rob_trap_ctrl u_trap (
    .single_commit(single_commit), .interrupt_fire(interrupt_fire),
    .single_uop(single_uop), .ftq_resp_pc(ftq_resp_pc),
    .flush(flush_w), .exception(bcast_exception), .mret(bcast_mret), .sret(bcast_sret), .ecall(bcast_ecall),
    .fence(bcast_fence), .fence_i(bcast_fence_i),
    .page_fault_inst(bcast_page_fault_inst), .page_fault_load(bcast_page_fault_load),
    .page_fault_store(bcast_page_fault_store), .illegal_inst(bcast_illegal_inst), .breakpoint(bcast_breakpoint),
    .rob2csr_commit(rob2csr_commit), .trap_val_valid(bcast_trap_val_valid), .trap_val(bcast_trap_val), .pc(bcast_pc)
  );

endmodule

`default_nettype wire
