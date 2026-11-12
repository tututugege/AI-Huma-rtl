// Ref: back-end/Rob.cpp  class Rob  (top level: flat spec ports <-> packed structs; no logic)
`default_nettype none

module rob
  import ttg_cfg_pkg::*;
  import rob_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic dec_bcast_mispred,
  input  logic [6:0] dec_bcast_redirect_rob_idx,
  input  logic csr2rob_interrupt_req,
  input  logic lsu2rob_committed_store_pending,
  input  logic front_stall,
  input  logic [3:0] bpu_upd_free,   // compact ROB commit credits (EXP-028): BPU update queue free entries (registered)
  input  logic [3:0] bpu_tq_free,    // uBTB train queue free entries (registered)
  input  logic [XLEN_BITS-1:0] ftq_rob_pc_resp_resp_pc [1],

  input  logic [DECODE_WIDTH-1:0] dis2rob_dis_fire,
  input  logic [XLEN_BITS-1:0] dis2rob_uop_diag_val [DECODE_WIDTH],
  input  logic [5:0] dis2rob_uop_dest_areg [DECODE_WIDTH],
  input  logic [5:0] dis2rob_uop_src1_areg [DECODE_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] dis2rob_uop_dest_preg [DECODE_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] dis2rob_uop_old_dest_preg [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0] dis2rob_uop_me_elim,
  input  logic [DECODE_WIDTH-1:0] dis2rob_uop_dest_fp,
  input  logic [DECODE_WIDTH-1:0] dis2rob_uop_fs_need,
  input  logic [5:0] dis2rob_uop_ftq_idx [DECODE_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] dis2rob_uop_ftq_offset [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0] dis2rob_uop_ftq_is_last,
  input  logic [4:0] dis2rob_uop_type [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0] dis2rob_uop_dest_en,
  input  logic [6:0] dis2rob_uop_func7 [DECODE_WIDTH],
  input  logic [31:0] dis2rob_uop_imm [DECODE_WIDTH],
  input  logic [6:0] dis2rob_uop_rob_idx [DECODE_WIDTH],
  input  logic [5:0] dis2rob_uop_stq_idx [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0] dis2rob_uop_stq_flag,
  input  logic [2:0] dis2rob_uop_expect_mask [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0] dis2rob_uop_rob_flag,
  input  logic [DECODE_WIDTH-1:0] dis2rob_uop_page_fault_inst,
  input  logic [DECODE_WIDTH-1:0] dis2rob_uop_illegal_inst,
  input  logic [ISSUE_WIDTH-1:0] exu2rob_entry_valid,
  input  logic [XLEN_BITS-1:0] exu2rob_entry_uop_diag_val [ISSUE_WIDTH],
  input  logic [XLEN_BITS-1:0] exu2rob_entry_uop_result [ISSUE_WIDTH],
  input  logic [6:0] exu2rob_entry_uop_rob_idx [ISSUE_WIDTH],
  input  logic [ISSUE_WIDTH-1:0] exu2rob_entry_uop_mispred,
  input  logic exu2rob_entry_uop_br_taken [ISSUE_WIDTH],
  input  logic [ISSUE_WIDTH-1:0] exu2rob_entry_uop_page_fault_load,
  input  logic [ISSUE_WIDTH-1:0] exu2rob_entry_uop_page_fault_store,
  input  logic [ISSUE_WIDTH-1:0] exu2rob_entry_uop_rob_defer,    // LSU_MEMSPEC: write-back does not complete
  input  logic [ISSUE_WIDTH-1:0] exu2rob_entry_uop_flush_pipe,   // LSU_MEMSPEC: flush the pipe at commit
  input  logic [ISSUE_WIDTH-1:0] exu2rob_entry_uop_illegal,      // F/D: illegal found at execute
  input  logic [4:0] exu2rob_entry_uop_fflags [ISSUE_WIDTH],
  input  logic csr2rob_fs_off,
  input  logic [4:0] exu2rob_entry_uop_op [ISSUE_WIDTH],
  output logic rob2dis_stall,
  output logic rob2dis_empty,
  output logic rob2dis_ready,
  output logic [6:0] rob2dis_enq_idx,
  output logic [7:0] rob2dis_free,    // compact ROB: free entries (line ROB: unused, ROB_NUM)
  output logic rob2dis_rob_flag,
  output logic rob2csr_commit,
  output logic [4:0] rob2csr_fflags,
  output logic rob2csr_fs_dirty,
  output logic rob2csr_interrupt_resp,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_valid,
  output logic [XLEN_BITS-1:0] rob_commit_commit_entry_uop_diag_val [COMMIT_WIDTH],
  output logic [5:0] rob_commit_commit_entry_uop_dest_areg [COMMIT_WIDTH],
  output logic [PRF_IDX_WIDTH-1:0] rob_commit_commit_entry_uop_dest_preg [COMMIT_WIDTH],
  output logic [PRF_IDX_WIDTH-1:0] rob_commit_commit_entry_uop_old_dest_preg [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_me_elim,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_dest_fp,
  output logic [5:0] rob_commit_commit_entry_uop_ftq_idx [COMMIT_WIDTH],
  output logic [FTQ_OFFSET_WIDTH-1:0] rob_commit_commit_entry_uop_ftq_offset [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_ftq_is_last,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_mispred,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_br_taken,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_dest_en,
  output logic [6:0] rob_commit_commit_entry_uop_func7 [COMMIT_WIDTH],
  output logic [6:0] rob_commit_commit_entry_uop_rob_idx [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_rob_flag,
  output logic [5:0] rob_commit_commit_entry_uop_stq_idx [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_stq_flag,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_page_fault_inst,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_page_fault_load,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_page_fault_store,
  output logic [COMMIT_WIDTH-1:0] rob_commit_commit_entry_uop_illegal_inst,
  output logic [4:0] rob_commit_commit_entry_uop_type [COMMIT_WIDTH],
  output logic [5:0] commit_extra_src1_areg [COMMIT_WIDTH],
  output logic [31:0] commit_extra_imm [COMMIT_WIDTH],
  output logic rob_bcast_flush,
  output logic rob_bcast_mret,
  output logic rob_bcast_sret,
  output logic rob_bcast_ecall,
  output logic rob_bcast_breakpoint,
  output logic rob_bcast_exception,
  output logic rob_bcast_fence,
  output logic rob_bcast_fence_i,
  output logic rob_bcast_page_fault_inst,
  output logic rob_bcast_page_fault_load,
  output logic rob_bcast_page_fault_store,
  output logic rob_bcast_illegal_inst,
  output logic rob_bcast_interrupt,
  output logic rob_bcast_trap_val_valid,
  output logic [XLEN_BITS-1:0] rob_bcast_trap_val,
  output logic [XLEN_BITS-1:0] rob_bcast_pc,
  output logic [6:0] rob_bcast_head_rob_idx,
  output logic rob_bcast_head_valid,
  output logic [6:0] rob_bcast_head_incomplete_rob_idx,
  output logic rob_bcast_head_incomplete_valid,
  output logic [0:0] ftq_rob_pc_req_req_valid,
  output logic [5:0] ftq_rob_pc_req_req_ftq_idx [1],
  output logic [FTQ_OFFSET_WIDTH-1:0] ftq_rob_pc_req_req_ftq_offset [1]
);

  // ---- spec ports -> internal structs ----
  rob_entry_t              dis_uop [ROB_BANK_NUM];
  logic [ROB_BANK_NUM-1:0] dis_fire;
  rob_wb_t                 wb [ISSUE_WIDTH];

  for (genvar b = 0; b < ROB_BANK_NUM; b++) begin : g_dispatch
    assign dis_fire[b] = dis2rob_dis_fire[b];
    // RobStoredInst::from_dis_rob_inst: cplt_mask restarts at 0, page_fault_load/store at 0
    assign dis_uop[b] = '{
      diag_val:      dis2rob_uop_diag_val[b],
      dest_areg:     dis2rob_uop_dest_areg[b],
      src1_areg:     dis2rob_uop_src1_areg[b],
      dest_preg:     dis2rob_uop_dest_preg[b],
      old_dest_preg: dis2rob_uop_old_dest_preg[b],
      me_elim:       dis2rob_uop_me_elim[b],
      dest_fp:       dis2rob_uop_dest_fp[b],
      dest_en:       dis2rob_uop_dest_en[b],
      ftq_idx:       dis2rob_uop_ftq_idx[b],
      ftq_offset:    dis2rob_uop_ftq_offset[b],
      ftq_is_last:   dis2rob_uop_ftq_is_last[b],
      mispred:       1'b0,   // Dispatch never sets it; the Rob overwrites it at enqueue
      br_taken:      1'b0,   // written by the branch unit at writeback
      func7:         dis2rob_uop_func7[b],
      imm:           dis2rob_uop_imm[b],
      rob_idx:       dis2rob_uop_rob_idx[b],
      rob_flag:      dis2rob_uop_rob_flag[b],
      stq_idx:       dis2rob_uop_stq_idx[b],
      stq_flag:      dis2rob_uop_stq_flag[b],
      pend_mask:     dis2rob_uop_expect_mask[b],  // cplt_mask restarts at 0
      pf_inst:       dis2rob_uop_page_fault_inst[b],
      pf_load:       1'b0,
      pf_store:      1'b0,
      illegal_inst:  dis2rob_uop_illegal_inst[b],
      fs_need:       dis2rob_uop_fs_need[b],
      fflags:        '0,
      flush_pipe:    1'b0,
      itype:         dis2rob_uop_type[b]
    };
  end

  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_writeback
    assign wb[p] = '{
      valid:      exu2rob_entry_valid[p],
      diag_val:   exu2rob_entry_uop_diag_val[p],
      result:     exu2rob_entry_uop_result[p],
      rob_idx:    exu2rob_entry_uop_rob_idx[p],
      mispred:    exu2rob_entry_uop_mispred[p],
      br_taken:   exu2rob_entry_uop_br_taken[p],
      pf_inst:    1'b0,   // no writer in the back end (instruction page faults come from the front end)
      pf_load:    exu2rob_entry_uop_page_fault_load[p],
      pf_store:   exu2rob_entry_uop_page_fault_store[p],
      defer:      exu2rob_entry_uop_rob_defer[p],
      flush_pipe: exu2rob_entry_uop_flush_pipe[p],
      illegal:    exu2rob_entry_uop_illegal[p],
      fflags:     exu2rob_entry_uop_fflags[p],
      fs_off:     csr2rob_fs_off,
      op:         exu2rob_entry_uop_op[p]
    };
  end

  // ---- core ----
  logic [ROB_LINE_IDX_W-1:0] enq_line;
  logic [ROB_BANK_NUM-1:0]   commit_valid;
  rob_entry_t                commit_uop [ROB_BANK_NUM];

  logic [ROB_IDX_WIDTH-1:0] enq_idx_cpt;
  if (ROB_COMPACT != 0) begin : g_cpt   // compact ROB (EXP-028)
    assign enq_line = '0;
    rob_core_cpt u_core (
      .clk(clk), .rst_n(rst_n),
      .dec_mispred(dec_bcast_mispred), .dec_redirect_rob_idx(dec_bcast_redirect_rob_idx),
      .interrupt_req(csr2rob_interrupt_req), .committed_store_pending(lsu2rob_committed_store_pending),
      .front_stall(front_stall), .bpu_upd_free(bpu_upd_free), .bpu_tq_free(bpu_tq_free),
      .ftq_resp_pc(ftq_rob_pc_resp_resp_pc[0]),
      .dis_fire(dis_fire), .dis_uop(dis_uop), .wb(wb),
      .rob2dis_stall(rob2dis_stall), .rob2dis_empty(rob2dis_empty), .rob2dis_ready(rob2dis_ready),
      .rob2dis_enq_idx(enq_idx_cpt), .rob2dis_rob_flag(rob2dis_rob_flag), .rob2dis_free(rob2dis_free),
      .rob2csr_commit(rob2csr_commit), .rob2csr_interrupt_resp(rob2csr_interrupt_resp),
      .commit_valid(commit_valid), .commit_uop(commit_uop),
      .bcast_flush(rob_bcast_flush), .bcast_mret(rob_bcast_mret), .bcast_sret(rob_bcast_sret),
      .bcast_ecall(rob_bcast_ecall), .bcast_breakpoint(rob_bcast_breakpoint),
      .bcast_exception(rob_bcast_exception), .bcast_fence(rob_bcast_fence),
      .bcast_fence_i(rob_bcast_fence_i), .bcast_page_fault_inst(rob_bcast_page_fault_inst),
      .bcast_page_fault_load(rob_bcast_page_fault_load), .bcast_page_fault_store(rob_bcast_page_fault_store),
      .bcast_illegal_inst(rob_bcast_illegal_inst), .bcast_interrupt(rob_bcast_interrupt),
      .bcast_trap_val_valid(rob_bcast_trap_val_valid), .bcast_trap_val(rob_bcast_trap_val), .bcast_pc(rob_bcast_pc),
      .bcast_head_rob_idx(rob_bcast_head_rob_idx), .bcast_head_valid(rob_bcast_head_valid),
      .bcast_head_incomplete_rob_idx(rob_bcast_head_incomplete_rob_idx),
      .bcast_head_incomplete_valid(rob_bcast_head_incomplete_valid),
      .ftq_req_valid(ftq_rob_pc_req_req_valid[0]), .ftq_req_ftq_idx(ftq_rob_pc_req_req_ftq_idx[0]),
      .ftq_req_ftq_offset(ftq_rob_pc_req_req_ftq_offset[0])
    );
  end else begin : g_line               // line ROB: one dispatch group per line
    rob_core u_core (
      .clk(clk), .rst_n(rst_n),
      .dec_mispred(dec_bcast_mispred), .dec_redirect_rob_idx(dec_bcast_redirect_rob_idx),
      .interrupt_req(csr2rob_interrupt_req), .committed_store_pending(lsu2rob_committed_store_pending),
      .front_stall(front_stall), .ftq_resp_pc(ftq_rob_pc_resp_resp_pc[0]),
      .dis_fire(dis_fire), .dis_uop(dis_uop), .wb(wb),
      .rob2dis_stall(rob2dis_stall), .rob2dis_empty(rob2dis_empty), .rob2dis_ready(rob2dis_ready),
      .rob2dis_enq_line(enq_line), .rob2dis_rob_flag(rob2dis_rob_flag),
      .rob2csr_commit(rob2csr_commit), .rob2csr_interrupt_resp(rob2csr_interrupt_resp),
      .commit_valid(commit_valid), .commit_uop(commit_uop),
      .bcast_flush(rob_bcast_flush), .bcast_mret(rob_bcast_mret), .bcast_sret(rob_bcast_sret),
      .bcast_ecall(rob_bcast_ecall), .bcast_breakpoint(rob_bcast_breakpoint),
      .bcast_exception(rob_bcast_exception), .bcast_fence(rob_bcast_fence),
      .bcast_fence_i(rob_bcast_fence_i), .bcast_page_fault_inst(rob_bcast_page_fault_inst),
      .bcast_page_fault_load(rob_bcast_page_fault_load), .bcast_page_fault_store(rob_bcast_page_fault_store),
      .bcast_illegal_inst(rob_bcast_illegal_inst), .bcast_interrupt(rob_bcast_interrupt),
      .bcast_trap_val_valid(rob_bcast_trap_val_valid), .bcast_trap_val(rob_bcast_trap_val), .bcast_pc(rob_bcast_pc),
      .bcast_head_rob_idx(rob_bcast_head_rob_idx), .bcast_head_valid(rob_bcast_head_valid),
      .bcast_head_incomplete_rob_idx(rob_bcast_head_incomplete_rob_idx),
      .bcast_head_incomplete_valid(rob_bcast_head_incomplete_valid),
      .ftq_req_valid(ftq_rob_pc_req_req_valid[0]), .ftq_req_ftq_idx(ftq_rob_pc_req_req_ftq_idx[0]),
      .ftq_req_ftq_offset(ftq_rob_pc_req_req_ftq_offset[0])
    );
    assign rob2dis_free = 8'(ROB_NUM);
    assign enq_idx_cpt = '0;
    logic [7:0] unused_credit;
    assign unused_credit = {bpu_upd_free, bpu_tq_free};
  end

  // ---- internal structs -> spec ports ----
  // RobDisIO::enq_idx: the line number (zero extended), or the tail entry of the compact ROB
  assign rob2dis_enq_idx = (ROB_COMPACT != 0) ? enq_idx_cpt : ROB_IDX_WIDTH'(enq_line);

  // F/D: exception flags of the instructions that retire normally this cycle, and whether one of them makes FS Dirty
  // (it writes an FP register or raised a flag); a trapping instruction or an interrupt retires nothing
  always_comb begin
    rob2csr_fflags   = '0;
    rob2csr_fs_dirty = 1'b0;
    for (int b = 0; b < ROB_BANK_NUM; b++) begin
      if (commit_valid[b] && !rob_is_exception(commit_uop[b]) && !rob_bcast_interrupt) begin
        rob2csr_fflags   = rob2csr_fflags | commit_uop[b].fflags;
        rob2csr_fs_dirty = rob2csr_fs_dirty | commit_uop[b].dest_fp | (|commit_uop[b].fflags);
      end
    end
  end

  for (genvar b = 0; b < ROB_BANK_NUM; b++) begin : g_commit
    assign rob_commit_commit_entry_valid[b]                 = commit_valid[b];
    assign rob_commit_commit_entry_uop_diag_val[b]          = commit_uop[b].diag_val;
    assign rob_commit_commit_entry_uop_dest_areg[b]         = commit_uop[b].dest_areg;
    assign rob_commit_commit_entry_uop_dest_preg[b]         = commit_uop[b].dest_preg;
    assign rob_commit_commit_entry_uop_old_dest_preg[b]     = commit_uop[b].old_dest_preg;
    assign rob_commit_commit_entry_uop_me_elim[b]           = commit_uop[b].me_elim;
    assign rob_commit_commit_entry_uop_dest_fp[b]           = commit_uop[b].dest_fp;
    assign rob_commit_commit_entry_uop_ftq_idx[b]           = commit_uop[b].ftq_idx;
    assign rob_commit_commit_entry_uop_ftq_offset[b]        = commit_uop[b].ftq_offset;
    assign rob_commit_commit_entry_uop_ftq_is_last[b]       = commit_uop[b].ftq_is_last;
    assign rob_commit_commit_entry_uop_mispred[b]           = commit_uop[b].mispred;
    assign rob_commit_commit_entry_uop_br_taken[b]          = commit_uop[b].br_taken;
    assign rob_commit_commit_entry_uop_dest_en[b]           = commit_uop[b].dest_en;
    assign rob_commit_commit_entry_uop_func7[b]             = commit_uop[b].func7;
    assign rob_commit_commit_entry_uop_rob_idx[b]           = commit_uop[b].rob_idx;
    assign rob_commit_commit_entry_uop_rob_flag[b]          = commit_uop[b].rob_flag;
    assign rob_commit_commit_entry_uop_stq_idx[b]           = commit_uop[b].stq_idx;
    assign rob_commit_commit_entry_uop_stq_flag[b]          = commit_uop[b].stq_flag;
    assign rob_commit_commit_entry_uop_page_fault_inst[b]   = commit_uop[b].pf_inst;
    assign rob_commit_commit_entry_uop_page_fault_load[b]   = commit_uop[b].pf_load;
    assign rob_commit_commit_entry_uop_page_fault_store[b]  = commit_uop[b].pf_store;
    assign rob_commit_commit_entry_uop_illegal_inst[b]      = commit_uop[b].illegal_inst;
    assign rob_commit_commit_entry_uop_type[b]              = commit_uop[b].itype;
    assign commit_extra_src1_areg[b]                        = commit_uop[b].src1_areg;
    assign commit_extra_imm[b]                              = commit_uop[b].imm;
  end

endmodule

`default_nettype wire
