// Ref: back-end/Dispatch.cpp  class Dispatch
`default_nettype none

// Port adapter only: packs the flat spec ports into the dis_pkg structs, instantiates dispatch_core
// and unpacks its results. Generated from spec/dispatch.io by a helper script, then maintained by hand.
module dispatch
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic ren2dis_valid [8],
  input  logic [31:0] ren2dis_uop_diag_val [8],
  input  logic [5:0] ren2dis_uop_dest_areg [8],
  input  logic [5:0] ren2dis_uop_src1_areg [8],
  input  logic [6:0] ren2dis_uop_dest_preg [8],
  input  logic [6:0] ren2dis_uop_src1_preg [8],
  input  logic [6:0] ren2dis_uop_src2_preg [8],
  input  logic [6:0] ren2dis_uop_old_dest_preg [8],
  input  logic [5:0] ren2dis_uop_ftq_idx [8],
  input  logic [3:0] ren2dis_uop_ftq_offset [8],
  input  logic ren2dis_uop_ftq_is_last [8],
  input  logic [4:0] ren2dis_uop_type [8],
  input  logic ren2dis_uop_dest_en [8],
  input  logic ren2dis_uop_src1_en [8],
  input  logic ren2dis_uop_src2_en [8],
  input  logic ren2dis_uop_is_atomic [8],
  input  logic ren2dis_uop_src1_busy [8],
  input  logic ren2dis_uop_src2_busy [8],
  input  logic ren2dis_uop_src1_is_pc [8],
  input  logic ren2dis_uop_src2_is_imm [8],
  input  logic [2:0] ren2dis_uop_func3 [8],
  input  logic [6:0] ren2dis_uop_func7 [8],
  input  logic [31:0] ren2dis_uop_imm [8],
  input  logic [5:0] ren2dis_uop_br_id [8],
  input  logic [63:0] ren2dis_uop_br_mask [8],
  input  logic [11:0] ren2dis_uop_csr_idx [8],
  input  logic ren2dis_uop_page_fault_inst [8],
  input  logic ren2dis_uop_illegal_inst [8],
  input  logic rob2dis_ready,
  input  logic rob2dis_empty,
  input  logic rob2dis_stall,
  // ROB enq_idx is a 4-bit line pointer carried in a 7-bit IO field; bits 6:4 are always 0 and ignored
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [6:0] rob2dis_enq_idx,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic rob2dis_rob_flag,
  input  logic [7:0] iss2dis_ready_num [5],
  input  logic [5:0] lsu2dis_stq_tail,
  input  logic lsu2dis_stq_tail_flag,
  input  logic [6:0] lsu2dis_stq_free,
  input  logic [6:0] lsu2dis_ldq_free,
  input  logic [5:0] lsu2dis_ldq_alloc_idx [8],
  input  logic lsu2dis_ldq_alloc_valid [8],
  input  logic prf_awake_wake_valid [4],
  input  logic [6:0] prf_awake_wake_preg [4],
  input  logic iss_awake_wake_valid [15],
  input  logic [6:0] iss_awake_wake_preg [15],
  input  logic rob_bcast_flush,
  input  logic dec_bcast_mispred,
  input  logic [63:0] dec_bcast_clear_mask,
  output logic dis2ren_ready,
  output logic dis2rob_valid [8],
  output logic dis2rob_dis_fire [8],
  output logic [31:0] dis2rob_uop_diag_val [8],
  output logic [5:0] dis2rob_uop_dest_areg [8],
  output logic [5:0] dis2rob_uop_src1_areg [8],
  output logic [6:0] dis2rob_uop_dest_preg [8],
  output logic [6:0] dis2rob_uop_old_dest_preg [8],
  output logic [5:0] dis2rob_uop_ftq_idx [8],
  output logic [3:0] dis2rob_uop_ftq_offset [8],
  output logic dis2rob_uop_ftq_is_last [8],
  output logic dis2rob_uop_mispred [8],
  output logic dis2rob_uop_br_taken [8],
  output logic [4:0] dis2rob_uop_type [8],
  output logic dis2rob_uop_dest_en [8],
  output logic dis2rob_uop_is_atomic [8],
  output logic [2:0] dis2rob_uop_func3 [8],
  output logic [6:0] dis2rob_uop_func7 [8],
  output logic [31:0] dis2rob_uop_imm [8],
  output logic [63:0] dis2rob_uop_br_mask [8],
  output logic [6:0] dis2rob_uop_rob_idx [8],
  output logic [5:0] dis2rob_uop_stq_idx [8],
  output logic dis2rob_uop_stq_flag [8],
  output logic [5:0] dis2rob_uop_ldq_idx [8],
  output logic [2:0] dis2rob_uop_expect_mask [8],
  output logic [2:0] dis2rob_uop_cplt_mask [8],
  output logic dis2rob_uop_rob_flag [8],
  output logic dis2rob_uop_page_fault_inst [8],
  output logic dis2rob_uop_illegal_inst [8],
  output logic dis2rob_uop_flush_pipe [8],
  output logic dis2iss_req_valid [5] [8],
  output logic [6:0] dis2iss_req_uop_dest_preg [5] [8],
  output logic [6:0] dis2iss_req_uop_src1_preg [5] [8],
  output logic [6:0] dis2iss_req_uop_src2_preg [5] [8],
  output logic [5:0] dis2iss_req_uop_ftq_idx [5] [8],
  output logic [3:0] dis2iss_req_uop_ftq_offset [5] [8],
  output logic dis2iss_req_uop_is_atomic [5] [8],
  output logic dis2iss_req_uop_dest_en [5] [8],
  output logic dis2iss_req_uop_src1_en [5] [8],
  output logic dis2iss_req_uop_src2_en [5] [8],
  output logic dis2iss_req_uop_src1_busy [5] [8],
  output logic dis2iss_req_uop_src2_busy [5] [8],
  output logic dis2iss_req_uop_src1_is_pc [5] [8],
  output logic dis2iss_req_uop_src2_is_imm [5] [8],
  output logic [2:0] dis2iss_req_uop_func3 [5] [8],
  output logic [6:0] dis2iss_req_uop_func7 [5] [8],
  output logic [31:0] dis2iss_req_uop_imm [5] [8],
  output logic [5:0] dis2iss_req_uop_br_id [5] [8],
  output logic [63:0] dis2iss_req_uop_br_mask [5] [8],
  output logic [11:0] dis2iss_req_uop_csr_idx [5] [8],
  output logic [6:0] dis2iss_req_uop_rob_idx [5] [8],
  output logic [5:0] dis2iss_req_uop_stq_idx [5] [8],
  output logic dis2iss_req_uop_stq_flag [5] [8],
  output logic [5:0] dis2iss_req_uop_ldq_idx [5] [8],
  output logic dis2iss_req_uop_rob_flag [5] [8],
  output logic [4:0] dis2iss_req_uop_op [5] [8],
  output logic dis2lsu_alloc_req [8],
  output logic [63:0] dis2lsu_br_mask [8],
  output logic [2:0] dis2lsu_func3 [8],
  output logic [6:0] dis2lsu_rob_idx [8],
  output logic dis2lsu_rob_flag [8],
  output logic dis2lsu_stq_flag [8],
  output logic dis2lsu_ldq_alloc_req [8],
  output logic [63:0] dis2lsu_ldq_br_mask [8],
  output logic [5:0] dis2lsu_ldq_idx [8],
  output logic [6:0] dis2lsu_ldq_rob_idx [8],
  output logic dis2lsu_ldq_rob_flag [8]
);

  logic                          ren_valid [NUM_SLOTS];
  dis_inst_t                     ren_inst  [NUM_SLOTS];
  logic                          core_ready;
  logic                          rob_valid [NUM_SLOTS];
  logic                          dis_fire  [NUM_SLOTS];
  dis_inst_t                     rob_inst  [NUM_SLOTS];
  dis_res_t                      rob_res   [NUM_SLOTS];
  logic [CPLT_MASK_W-1:0]        rob_expect_mask [NUM_SLOTS];
  logic [IQ_READY_NUM_WIDTH-1:0] ready_num [IQ_NUM];
  logic                          req_valid [IQ_NUM][IQ_PORTS];
  dis_iss_uop_t                  req_uop   [IQ_NUM][IQ_PORTS];
  logic [LDQ_IDX_WIDTH-1:0]      ldq_alloc_idx   [LDQ_PORTS];
  logic                          ldq_alloc_valid [LDQ_PORTS];
  logic                          st_req      [STQ_PORTS];
  logic [BR_MASK_WIDTH-1:0]      st_br_mask  [STQ_PORTS];
  logic [2:0]                    st_func3    [STQ_PORTS];
  logic [ROB_IDX_WIDTH-1:0]      st_rob_idx  [STQ_PORTS];
  logic                          st_rob_flag [STQ_PORTS];
  logic                          st_stq_flag [STQ_PORTS];
  logic                          ld_req      [LDQ_PORTS];
  logic [LDQ_IDX_WIDTH-1:0]      ld_idx      [LDQ_PORTS];
  logic [BR_MASK_WIDTH-1:0]      ld_br_mask  [LDQ_PORTS];
  logic [ROB_IDX_WIDTH-1:0]      ld_rob_idx  [LDQ_PORTS];
  logic                          ld_rob_flag [LDQ_PORTS];
  logic                          wake_valid [NUM_WAKE];
  logic [PRF_IDX_WIDTH-1:0]      wake_preg  [NUM_WAKE];

  // ---- inputs: pack ----
  // Ref: Dispatch::in (ren2dis, iss2dis, lsu2dis, prf_awake, iss_awake)
  always_comb begin
    for (int i = 0; i < NUM_SLOTS; i++) begin
      ren_valid[i] = ren2dis_valid[i];
      ren_inst[i].diag_val = ren2dis_uop_diag_val[i];
      ren_inst[i].dest_areg = ren2dis_uop_dest_areg[i];
      ren_inst[i].src1_areg = ren2dis_uop_src1_areg[i];
      ren_inst[i].dest_preg = ren2dis_uop_dest_preg[i];
      ren_inst[i].src1_preg = ren2dis_uop_src1_preg[i];
      ren_inst[i].src2_preg = ren2dis_uop_src2_preg[i];
      ren_inst[i].old_dest_preg = ren2dis_uop_old_dest_preg[i];
      ren_inst[i].ftq_idx = ren2dis_uop_ftq_idx[i];
      ren_inst[i].ftq_offset = ren2dis_uop_ftq_offset[i];
      ren_inst[i].ftq_is_last = ren2dis_uop_ftq_is_last[i];
      ren_inst[i].dest_en = ren2dis_uop_dest_en[i];
      ren_inst[i].src1_en = ren2dis_uop_src1_en[i];
      ren_inst[i].src2_en = ren2dis_uop_src2_en[i];
      ren_inst[i].is_atomic = ren2dis_uop_is_atomic[i];
      ren_inst[i].src1_busy = ren2dis_uop_src1_busy[i];
      ren_inst[i].src2_busy = ren2dis_uop_src2_busy[i];
      ren_inst[i].src1_is_pc = ren2dis_uop_src1_is_pc[i];
      ren_inst[i].src2_is_imm = ren2dis_uop_src2_is_imm[i];
      ren_inst[i].func3 = ren2dis_uop_func3[i];
      ren_inst[i].func7 = ren2dis_uop_func7[i];
      ren_inst[i].imm = ren2dis_uop_imm[i];
      ren_inst[i].br_id = ren2dis_uop_br_id[i];
      ren_inst[i].br_mask = ren2dis_uop_br_mask[i];
      ren_inst[i].csr_idx = ren2dis_uop_csr_idx[i];
      ren_inst[i].page_fault_inst = ren2dis_uop_page_fault_inst[i];
      ren_inst[i].illegal_inst = ren2dis_uop_illegal_inst[i];
      ren_inst[i].itype = inst_type_e'(ren2dis_uop_type[i]);
    end
    for (int q = 0; q < IQ_NUM; q++) ready_num[q] = iss2dis_ready_num[q];
    for (int k = 0; k < LDQ_PORTS; k++) begin
      ldq_alloc_idx[k]   = lsu2dis_ldq_alloc_idx[k];
      ldq_alloc_valid[k] = lsu2dis_ldq_alloc_valid[k];
    end
    for (int w = 0; w < LSU_LOAD_WB_WIDTH; w++) begin
      wake_valid[w] = prf_awake_wake_valid[w];
      wake_preg[w]  = prf_awake_wake_preg[w];
    end
    for (int w = 0; w < MAX_WAKEUP_PORTS; w++) begin
      wake_valid[LSU_LOAD_WB_WIDTH + w] = iss_awake_wake_valid[w];
      wake_preg[LSU_LOAD_WB_WIDTH + w]  = iss_awake_wake_preg[w];
    end
  end

  dispatch_core u_core (
    .clk(clk), .rst_n(rst_n),
    .ren_valid(ren_valid), .ren_inst(ren_inst), .dis2ren_ready(core_ready),
    .rob_ready(rob2dis_ready), .rob_empty(rob2dis_empty), .rob_stall(rob2dis_stall),
    .rob_enq_line(rob2dis_enq_idx[ROB_LINE_W-1:0]), .rob_enq_flag(rob2dis_rob_flag),
    .rob_valid(rob_valid), .dis_fire(dis_fire), .rob_inst(rob_inst), .rob_res(rob_res),
    .rob_expect_mask(rob_expect_mask), .ready_num(ready_num), .req_valid(req_valid), .req_uop(req_uop),
    .stq_tail(lsu2dis_stq_tail), .stq_tail_flag(lsu2dis_stq_tail_flag), .stq_free(lsu2dis_stq_free),
    .ldq_free(lsu2dis_ldq_free), .ldq_alloc_idx(ldq_alloc_idx), .ldq_alloc_valid(ldq_alloc_valid),
    .st_req(st_req), .st_br_mask(st_br_mask), .st_func3(st_func3), .st_rob_idx(st_rob_idx),
    .st_rob_flag(st_rob_flag), .st_stq_flag(st_stq_flag), .ld_req(ld_req), .ld_idx(ld_idx),
    .ld_br_mask(ld_br_mask), .ld_rob_idx(ld_rob_idx), .ld_rob_flag(ld_rob_flag),
    .wake_valid(wake_valid), .wake_preg(wake_preg), .rob_flush(rob_bcast_flush),
    .dec_mispred(dec_bcast_mispred), .dec_clear_mask(dec_bcast_clear_mask));

  // ---- outputs: unpack ----
  // Ref: Dispatch::comb_alloc / comb_fire (dis2ren, dis2rob)
  always_comb begin
    dis2ren_ready = core_ready;
    for (int i = 0; i < NUM_SLOTS; i++) begin
      dis2rob_valid[i]    = rob_valid[i];
      dis2rob_dis_fire[i] = dis_fire[i];
      dis2rob_uop_diag_val[i] = rob_inst[i].diag_val;
      dis2rob_uop_dest_areg[i] = rob_inst[i].dest_areg;
      dis2rob_uop_src1_areg[i] = rob_inst[i].src1_areg;
      dis2rob_uop_dest_preg[i] = rob_inst[i].dest_preg;
      dis2rob_uop_old_dest_preg[i] = rob_inst[i].old_dest_preg;
      dis2rob_uop_ftq_idx[i] = rob_inst[i].ftq_idx;
      dis2rob_uop_ftq_offset[i] = rob_inst[i].ftq_offset;
      dis2rob_uop_ftq_is_last[i] = rob_inst[i].ftq_is_last;
      dis2rob_uop_dest_en[i] = rob_inst[i].dest_en;
      dis2rob_uop_is_atomic[i] = rob_inst[i].is_atomic;
      dis2rob_uop_func3[i] = rob_inst[i].func3;
      dis2rob_uop_func7[i] = rob_inst[i].func7;
      dis2rob_uop_imm[i] = rob_inst[i].imm;
      dis2rob_uop_br_mask[i] = rob_inst[i].br_mask;
      dis2rob_uop_page_fault_inst[i] = rob_inst[i].page_fault_inst;
      dis2rob_uop_illegal_inst[i] = rob_inst[i].illegal_inst;
      dis2rob_uop_type[i]        = rob_inst[i].itype;
      dis2rob_uop_rob_idx[i]     = rob_res[i].rob_idx;
      dis2rob_uop_rob_flag[i]    = rob_res[i].rob_flag;
      dis2rob_uop_stq_idx[i]     = rob_res[i].stq_idx;
      dis2rob_uop_stq_flag[i]    = rob_res[i].stq_flag;
      dis2rob_uop_ldq_idx[i]     = rob_res[i].ldq_idx;
      dis2rob_uop_expect_mask[i] = rob_expect_mask[i];
      dis2rob_uop_cplt_mask[i]   = '0;    // the ROB receives instructions with nothing completed
      dis2rob_uop_mispred[i]     = 1'b0;  // mispred / br_taken / flush_pipe are only set by later ROB updates
      dis2rob_uop_br_taken[i]    = 1'b0;
      dis2rob_uop_flush_pipe[i]  = 1'b0;
    end
  end

  // Ref: Dispatch::comb_dispatch / comb_fire (dis2iss)
  always_comb begin
    for (int q = 0; q < IQ_NUM; q++) begin
      for (int s = 0; s < IQ_PORTS; s++) begin
        dis2iss_req_valid[q][s] = req_valid[q][s];
        dis2iss_req_uop_dest_preg[q][s] = req_uop[q][s].dest_preg;
        dis2iss_req_uop_src1_preg[q][s] = req_uop[q][s].src1_preg;
        dis2iss_req_uop_src2_preg[q][s] = req_uop[q][s].src2_preg;
        dis2iss_req_uop_ftq_idx[q][s] = req_uop[q][s].ftq_idx;
        dis2iss_req_uop_ftq_offset[q][s] = req_uop[q][s].ftq_offset;
        dis2iss_req_uop_is_atomic[q][s] = req_uop[q][s].is_atomic;
        dis2iss_req_uop_dest_en[q][s] = req_uop[q][s].dest_en;
        dis2iss_req_uop_src1_en[q][s] = req_uop[q][s].src1_en;
        dis2iss_req_uop_src2_en[q][s] = req_uop[q][s].src2_en;
        dis2iss_req_uop_src1_busy[q][s] = req_uop[q][s].src1_busy;
        dis2iss_req_uop_src2_busy[q][s] = req_uop[q][s].src2_busy;
        dis2iss_req_uop_src1_is_pc[q][s] = req_uop[q][s].src1_is_pc;
        dis2iss_req_uop_src2_is_imm[q][s] = req_uop[q][s].src2_is_imm;
        dis2iss_req_uop_func3[q][s] = req_uop[q][s].func3;
        dis2iss_req_uop_func7[q][s] = req_uop[q][s].func7;
        dis2iss_req_uop_imm[q][s] = req_uop[q][s].imm;
        dis2iss_req_uop_br_id[q][s] = req_uop[q][s].br_id;
        dis2iss_req_uop_br_mask[q][s] = req_uop[q][s].br_mask;
        dis2iss_req_uop_csr_idx[q][s] = req_uop[q][s].csr_idx;
        dis2iss_req_uop_rob_idx[q][s] = req_uop[q][s].rob_idx;
        dis2iss_req_uop_stq_idx[q][s] = req_uop[q][s].stq_idx;
        dis2iss_req_uop_stq_flag[q][s] = req_uop[q][s].stq_flag;
        dis2iss_req_uop_ldq_idx[q][s] = req_uop[q][s].ldq_idx;
        dis2iss_req_uop_rob_flag[q][s] = req_uop[q][s].rob_flag;
        dis2iss_req_uop_op[q][s] = req_uop[q][s].op;
      end
    end
  end

  // Ref: Dispatch::comb_fire steps 3-4 (dis2lsu)
  always_comb begin
    for (int k = 0; k < STQ_PORTS; k++) begin
      dis2lsu_alloc_req[k] = st_req[k];
      dis2lsu_br_mask[k]   = st_br_mask[k];
      dis2lsu_func3[k]     = st_func3[k];
      dis2lsu_rob_idx[k]   = st_rob_idx[k];
      dis2lsu_rob_flag[k]  = st_rob_flag[k];
      dis2lsu_stq_flag[k]  = st_stq_flag[k];
    end
    for (int k = 0; k < LDQ_PORTS; k++) begin
      dis2lsu_ldq_alloc_req[k] = ld_req[k];
      dis2lsu_ldq_idx[k]       = ld_idx[k];
      dis2lsu_ldq_br_mask[k]   = ld_br_mask[k];
      dis2lsu_ldq_rob_idx[k]   = ld_rob_idx[k];
      dis2lsu_ldq_rob_flag[k]  = ld_rob_flag[k];
    end
  end

endmodule

`default_nettype wire
