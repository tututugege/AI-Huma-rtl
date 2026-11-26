// Ref: back-end/Rob.cpp  class Rob  (top level: adapts packed dis2rob / exu2rob structs to rob_core_cpt)
`default_nettype none

module rob
  import ttg_cfg_pkg::*;
  import rob_pkg::*;
  import dis_pkg::dis_rob_uop_t;
  import exu_ctrl_pkg::xc_rob_wb_t;
(
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      dec_bcast_mispred,
  input  logic                      ren2rob_walking,
  input  logic                      flush_pend,
  input  logic [ROB_IDX_WIDTH-1:0]  dec_bcast_redirect_rob_idx,
  input  logic                      csr2rob_interrupt_req,
  input  logic                      lsu2rob_committed_store_pending,
  input  logic                      front_stall,
  input  logic [3:0]                bpu_upd_free,
  input  logic [3:0]                bpu_tq_free,
  input  logic [FTQ_IDX_WIDTH-1:0]  ftq_head,
  input  logic [XLEN_BITS-1:0]      ftq_rob_pc_resp_resp_pc [1],
  input  logic [DECODE_WIDTH-1:0]   dis2rob_dis_fire,
  input  dis_rob_uop_t              dis2rob_uop [DECODE_WIDTH],
  input  xc_rob_wb_t                exu2rob     [ISSUE_WIDTH],
  input  logic                      csr2rob_fs_off,
  output logic                      rob2dis_stall,
  output logic                      rob2dis_empty,
  output logic                      rob2dis_ready,
  output logic [ROB_IDX_WIDTH-1:0]  rob2dis_enq_idx,
  output logic [ROB_IDX_WIDTH:0]    rob2dis_free,
  output logic                      rob2dis_rob_flag,
  output logic                      rob2csr_commit,
  output logic [4:0]                rob2csr_fflags,
  output logic                      rob2csr_fs_dirty,
  output logic                      rob2csr_interrupt_resp,
  output logic [COMMIT_WIDTH-1:0]   rob_commit_commit_entry_valid,
  output logic [5:0]                rob_commit_commit_entry_uop_dest_areg [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0]   rob_commit_commit_entry_uop_dest_fp,
  output logic [5:0]                rob_commit_commit_entry_uop_ftq_idx [COMMIT_WIDTH],
  output logic [FTQ_OFFSET_WIDTH-1:0] rob_commit_commit_entry_uop_ftq_offset [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0]   rob_commit_commit_entry_uop_ftq_is_last,
  output logic [COMMIT_WIDTH-1:0]   rob_commit_commit_entry_uop_br_taken,
  output logic [COMMIT_WIDTH-1:0]   rob_commit_commit_entry_uop_dest_en,
  output logic [6:0]                rob_commit_commit_entry_uop_func7 [COMMIT_WIDTH],
  output logic [ROB_IDX_WIDTH-1:0]  rob_commit_commit_entry_uop_rob_idx [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0]   rob_commit_commit_entry_uop_rob_flag,
  output logic [5:0]                rob_commit_commit_entry_uop_stq_idx [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0]   rob_commit_commit_entry_uop_stq_flag,
  output logic [COMMIT_WIDTH-1:0]   rob_commit_commit_entry_uop_page_fault_inst,
  output logic [COMMIT_WIDTH-1:0]   rob_commit_commit_entry_uop_page_fault_load,
  output logic [COMMIT_WIDTH-1:0]   rob_commit_commit_entry_uop_page_fault_store,
  output logic [COMMIT_WIDTH-1:0]   rob_commit_commit_entry_uop_illegal_inst,
  output logic [4:0]                rob_commit_commit_entry_uop_type [COMMIT_WIDTH],
  output logic [COMMIT_WIDTH-1:0]   commit_extra_is_ret,
  output logic                      rob_bcast_flush,
  output logic                      rob_bcast_mret,
  output logic                      rob_bcast_sret,
  output logic                      rob_bcast_ecall,
  output logic                      rob_bcast_breakpoint,
  output logic                      rob_bcast_exception,
  output logic                      rob_bcast_fence,
  output logic                      rob_bcast_fence_i,
  output logic                      rob_bcast_page_fault_inst,
  output logic                      rob_bcast_page_fault_load,
  output logic                      rob_bcast_page_fault_store,
  output logic                      rob_bcast_illegal_inst,
  output logic                      rob_bcast_interrupt,
  output logic                      rob_bcast_trap_val_valid,
  output logic [XLEN_BITS-1:0]      rob_bcast_trap_val,
  output logic [XLEN_BITS-1:0]      rob_bcast_pc,
  output logic [ROB_IDX_WIDTH-1:0]  rob_bcast_head_rob_idx,
  output logic                      rob_bcast_head_valid,
  output logic [ROB_IDX_WIDTH-1:0]  rob_bcast_head_incomplete_rob_idx,
  output logic                      rob_bcast_head_incomplete_valid,
  output logic [0:0]                ftq_rob_pc_req_req_valid,
  output logic [5:0]                ftq_rob_pc_req_req_ftq_idx [1],
  output logic [FTQ_OFFSET_WIDTH-1:0] ftq_rob_pc_req_req_ftq_offset [1]
);

  rob_entry_t               dis_uop      [ROB_BANK_NUM];
  logic [ROB_IDX_WIDTH-1:0] dis_rob_idx  [ROB_BANK_NUM];
  logic [XLEN_BITS-1:0]     dis_trap_val [ROB_BANK_NUM];
  rob_wb_t                  wb           [ISSUE_WIDTH];

  for (genvar b = 0; b < ROB_BANK_NUM; b++) begin : g_dispatch
    assign dis_rob_idx[b]  = dis2rob_uop[b].rob_idx;
    assign dis_trap_val[b] = dis2rob_uop[b].diag_val;
    assign dis_uop[b] = '{
      dest_areg:    dis2rob_uop[b].dest_areg,
      dest_fp:      dis2rob_uop[b].dest_fp,
      dest_en:      dis2rob_uop[b].dest_en,
      ftq_idx:      dis2rob_uop[b].ftq_idx,
      ftq_offset:   dis2rob_uop[b].ftq_offset,
      ftq_is_last:  dis2rob_uop[b].ftq_is_last,
      br_taken:     1'b0,
      is_ret:       (dis2rob_uop[b].itype == ITYPE_JALR) && (dis2rob_uop[b].src1_areg == 6'd1) &&
                    (dis2rob_uop[b].dest_areg == 6'd0) && (dis2rob_uop[b].imm == 32'd0),
      is_amo_lr:    dis2rob_uop[b].is_amo_lr,
      rob_flag:     dis2rob_uop[b].rob_flag,
      stq_idx:      dis2rob_uop[b].stq_idx,
      stq_flag:     dis2rob_uop[b].stq_flag,
      pend_mask:    dis2rob_uop[b].expect_mask,
      pf_inst:      dis2rob_uop[b].page_fault_inst,
      pf_inst_hi:   dis2rob_uop[b].pf_inst_hi,
      pf_load:      1'b0,
      pf_store:     1'b0,
      illegal_inst: dis2rob_uop[b].illegal_inst,
      fs_need:      dis2rob_uop[b].fs_need,
      fflags:       '0,
      flush_pipe:   1'b0,
      itype:        dis2rob_uop[b].itype
    };
  end

  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_writeback
    assign wb[p] = '{
      valid:      exu2rob[p].valid,
      result:     exu2rob[p].result,
      rob_idx:    exu2rob[p].rob_idx,
      br_taken:   exu2rob[p].br_taken,
      pf_inst:    1'b0,
      pf_load:    exu2rob[p].page_fault_load,
      pf_store:   exu2rob[p].page_fault_store,
      defer:      exu2rob[p].rob_defer,
      flush_pipe: exu2rob[p].flush_pipe,
      illegal:    exu2rob[p].illegal,
      fflags:     exu2rob[p].fflags,
      fs_off:     csr2rob_fs_off,
      op:         exu2rob[p].op
    };
  end

  logic [ROB_BANK_NUM-1:0]  commit_valid;
  logic [ROB_IDX_WIDTH-1:0] commit_rob_idx [ROB_BANK_NUM];
  rob_entry_t               commit_uop [ROB_BANK_NUM];

  logic dec_mispred_eff;
  assign dec_mispred_eff = dec_bcast_mispred && !flush_pend;

  rob_core_cpt u_core (
    .clk(clk), .rst_n(rst_n),
    .dec_mispred(dec_mispred_eff), .ren_walking(ren2rob_walking), .dec_redirect_rob_idx(dec_bcast_redirect_rob_idx),
    .interrupt_req(csr2rob_interrupt_req), .committed_store_pending(lsu2rob_committed_store_pending),
    .front_stall(front_stall), .bpu_upd_free(bpu_upd_free), .bpu_tq_free(bpu_tq_free),
    .ftq_head(ftq_head),
    .ftq_resp_pc(ftq_rob_pc_resp_resp_pc[0]),
    .dis_fire(dis2rob_dis_fire), .dis_rob_idx(dis_rob_idx), .dis_trap_val(dis_trap_val),
    .csr_fs_off(csr2rob_fs_off), .dis_uop(dis_uop), .wb(wb),
    .rob2dis_stall(rob2dis_stall), .rob2dis_empty(rob2dis_empty), .rob2dis_ready(rob2dis_ready),
    .rob2dis_enq_idx(rob2dis_enq_idx), .rob2dis_rob_flag(rob2dis_rob_flag), .rob2dis_free(rob2dis_free),
    .rob2csr_commit(rob2csr_commit), .rob2csr_interrupt_resp(rob2csr_interrupt_resp),
    .commit_valid(commit_valid), .commit_rob_idx(commit_rob_idx), .commit_uop(commit_uop),
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
    assign rob_commit_commit_entry_valid[b]                = commit_valid[b];
    assign rob_commit_commit_entry_uop_dest_areg[b]        = commit_uop[b].dest_areg;
    assign rob_commit_commit_entry_uop_dest_fp[b]          = commit_uop[b].dest_fp;
    assign rob_commit_commit_entry_uop_ftq_idx[b]          = commit_uop[b].ftq_idx;
    assign rob_commit_commit_entry_uop_ftq_offset[b]       = commit_uop[b].ftq_offset;
    assign rob_commit_commit_entry_uop_ftq_is_last[b]      = commit_uop[b].ftq_is_last;
    assign rob_commit_commit_entry_uop_br_taken[b]         = commit_uop[b].br_taken;
    assign rob_commit_commit_entry_uop_dest_en[b]          = commit_uop[b].dest_en;
    assign rob_commit_commit_entry_uop_func7[b]            = {commit_uop[b].is_amo_lr ? 5'b00010 : 5'b00000, 2'b00};
    assign rob_commit_commit_entry_uop_rob_idx[b]          = commit_rob_idx[b];
    assign rob_commit_commit_entry_uop_rob_flag[b]         = commit_uop[b].rob_flag;
    assign rob_commit_commit_entry_uop_stq_idx[b]          = commit_uop[b].stq_idx;
    assign rob_commit_commit_entry_uop_stq_flag[b]         = commit_uop[b].stq_flag;
    assign rob_commit_commit_entry_uop_page_fault_inst[b]  = commit_uop[b].pf_inst;
    assign rob_commit_commit_entry_uop_page_fault_load[b]  = commit_uop[b].pf_load;
    assign rob_commit_commit_entry_uop_page_fault_store[b] = commit_uop[b].pf_store;
    assign rob_commit_commit_entry_uop_illegal_inst[b]     = commit_uop[b].illegal_inst;
    assign rob_commit_commit_entry_uop_type[b]             = commit_uop[b].itype;
    assign commit_extra_is_ret[b]                          = commit_uop[b].is_ret;
  end

endmodule

`default_nettype wire
