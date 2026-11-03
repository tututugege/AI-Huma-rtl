// Ref: back-end/Isu.cpp  class Isu  (comb_begin/ready/awake/calc_latency_next/enq/issue/flush/seq)
`default_nettype none

// Issue unit: five issue queues (INT, LD, STA, STD, BR) plus the wake-up network. Port adapter only; logic is in
// isu_iq (queue), isu_wake_src (wake channels, delayed wake-ups) and isu_wake_bus (preg map).
module isu
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  // dispatch -> issue queues (Isu::comb_enq)
  input  logic dis2iss_req_valid [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] dis2iss_req_uop_dest_preg [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] dis2iss_req_uop_src1_preg [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] dis2iss_req_uop_src2_preg [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [FTQ_IDX_WIDTH-1:0] dis2iss_req_uop_ftq_idx [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] dis2iss_req_uop_ftq_offset [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_is_atomic [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_dest_en [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src1_en [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src2_en [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src1_busy [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src2_busy [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src1_is_pc [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_src2_is_imm [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [2:0] dis2iss_req_uop_func3 [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [6:0] dis2iss_req_uop_func7 [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [31:0] dis2iss_req_uop_imm [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [BR_TAG_WIDTH-1:0] dis2iss_req_uop_br_id [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [BR_MASK_WIDTH-1:0] dis2iss_req_uop_br_mask [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [CSR_IDX_WIDTH-1:0] dis2iss_req_uop_csr_idx [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [ROB_IDX_WIDTH-1:0] dis2iss_req_uop_rob_idx [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [STQ_IDX_WIDTH-1:0] dis2iss_req_uop_stq_idx [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_stq_flag [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [LDQ_IDX_WIDTH-1:0] dis2iss_req_uop_ldq_idx [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic dis2iss_req_uop_rob_flag [IQ_NUM][IQ_DISPATCH_WIDTH],
  input  logic [OP_W-1:0] dis2iss_req_uop_op [IQ_NUM][IQ_DISPATCH_WIDTH],
  // load write-back wake-ups, FU readiness, broadcasts
  input  logic prf_awake_wake_valid [LSU_LOAD_WB_WIDTH],
  input  logic [PRF_IDX_WIDTH-1:0] prf_awake_wake_preg [LSU_LOAD_WB_WIDTH],
  input  logic [OP_NUM-1:0] exe2iss_fu_ready_mask [ISSUE_WIDTH],
  input  logic rob_bcast_flush,
  input  logic dec_bcast_mispred,
  input  logic [BR_MASK_WIDTH-1:0] dec_bcast_br_mask,
  input  logic [BR_MASK_WIDTH-1:0] dec_bcast_clear_mask,
  // outputs
  output logic [READY_NUM_W-1:0] iss2dis_ready_num [IQ_NUM],
  output logic iss2prf_iss_entry_valid [ISSUE_WIDTH],
  output logic [PRF_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_dest_preg [ISSUE_WIDTH],
  output logic [PRF_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_src1_preg [ISSUE_WIDTH],
  output logic [PRF_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_src2_preg [ISSUE_WIDTH],
  output logic [FTQ_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_ftq_idx [ISSUE_WIDTH],
  output logic [FTQ_OFFSET_WIDTH-1:0] iss2prf_iss_entry_uop_ftq_offset [ISSUE_WIDTH],
  output logic iss2prf_iss_entry_uop_is_atomic [ISSUE_WIDTH],
  output logic iss2prf_iss_entry_uop_dest_en [ISSUE_WIDTH],
  output logic iss2prf_iss_entry_uop_src1_en [ISSUE_WIDTH],
  output logic iss2prf_iss_entry_uop_src2_en [ISSUE_WIDTH],
  output logic iss2prf_iss_entry_uop_src1_is_pc [ISSUE_WIDTH],
  output logic iss2prf_iss_entry_uop_src2_is_imm [ISSUE_WIDTH],
  output logic [2:0] iss2prf_iss_entry_uop_func3 [ISSUE_WIDTH],
  output logic [6:0] iss2prf_iss_entry_uop_func7 [ISSUE_WIDTH],
  output logic [31:0] iss2prf_iss_entry_uop_imm [ISSUE_WIDTH],
  output logic [BR_TAG_WIDTH-1:0] iss2prf_iss_entry_uop_br_id [ISSUE_WIDTH],
  output logic [BR_MASK_WIDTH-1:0] iss2prf_iss_entry_uop_br_mask [ISSUE_WIDTH],
  output logic [CSR_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_csr_idx [ISSUE_WIDTH],
  output logic [ROB_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_rob_idx [ISSUE_WIDTH],
  output logic [STQ_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_stq_idx [ISSUE_WIDTH],
  output logic iss2prf_iss_entry_uop_stq_flag [ISSUE_WIDTH],
  output logic [LDQ_IDX_WIDTH-1:0] iss2prf_iss_entry_uop_ldq_idx [ISSUE_WIDTH],
  output logic iss2prf_iss_entry_uop_rob_flag [ISSUE_WIDTH],
  output logic [OP_W-1:0] iss2prf_iss_entry_uop_op [ISSUE_WIDTH],
  output logic iss_awake_wake_valid [WAKE_NUM],
  output logic [PRF_IDX_WIDTH-1:0] iss_awake_wake_preg [WAKE_NUM]
);

`ifndef SYNTHESIS
  // the static layout below follows config.h: 5 queues, 22 issue ports, 15 wake channels
  if (ISSUE_WIDTH != 22 || WAKE_PORTS != ALU_NUM || FAST_WAKE_BASE + FAST_UNITS != WAKE_NUM ||
      IQ_DISPATCH_WIDTH != 8) begin : g_cfg_check
    $error("isu: config.h layout changed, isu_pkg port tables need updating");
  end
`endif

  logic                     flush_br;       // misprediction that is not already covered by the global flush
  logic                     issue_block;
  logic [ISSUE_WIDTH-1:0]   grant_valid;
  isu_uop_t [ISSUE_WIDTH-1:0] grant_uop;
  logic [WAKE_NUM-1:0]      wake_valid;
  logic [PRF_IDX_WIDTH-1:0] wake_preg [WAKE_NUM];
  logic [PRF_NUM-1:0]       woken;

  logic [LSU_LOAD_WB_WIDTH-1:0] prf_wake_valid;
  for (genvar k = 0; k < LSU_LOAD_WB_WIDTH; k++) begin : g_prf_wake
    assign prf_wake_valid[k] = prf_awake_wake_valid[k];
  end

  assign flush_br    = dec_bcast_mispred && !rob_bcast_flush;
  assign issue_block = rob_bcast_flush || dec_bcast_mispred;

  isu_wake_src u_wake_src (
    .clk(clk), .rst_n(rst_n),
    .prf_wake_valid(prf_wake_valid), .prf_wake_preg(prf_awake_wake_preg),
    .grant_valid(grant_valid[WAKE_PORTS-1:0]), .grant_uop(grant_uop[WAKE_PORTS-1:0]),
    .flush_all(rob_bcast_flush), .flush_br(flush_br),
    .flush_br_mask(dec_bcast_br_mask), .clear_mask(dec_bcast_clear_mask),
    .wake_valid(wake_valid), .wake_preg(wake_preg));

  isu_wake_bus u_wake_bus (.wake_valid(wake_valid), .wake_preg(wake_preg), .woken(woken));

  for (genvar k = 0; k < WAKE_NUM; k++) begin : g_awake_out
    assign iss_awake_wake_valid[k] = wake_valid[k];
    assign iss_awake_wake_preg[k]  = wake_preg[k];
  end

  // ---- one instance per issue queue ----
  for (genvar q = 0; q < IQ_NUM; q++) begin : g_iq
    localparam int SIZE = iq_size(q);
    localparam int NP   = iq_port_num(q);
    localparam int PB   = iq_port_base(q);

    logic [IQ_DISPATCH_WIDTH-1:0] enq_valid;
    isu_enq_t                     enq [IQ_DISPATCH_WIDTH];
    op_set_t                      fu_ready [NP];
    logic [NP-1:0]                g_valid;
    isu_uop_t                     g_uop [NP];

    for (genvar w = 0; w < IQ_DISPATCH_WIDTH; w++) begin : g_enq
      assign enq_valid[w] = dis2iss_req_valid[q][w];
      assign enq[w] = '{
        uop: '{
          dest_preg: dis2iss_req_uop_dest_preg[q][w],
          src1_preg: dis2iss_req_uop_src1_preg[q][w],
          src2_preg: dis2iss_req_uop_src2_preg[q][w],
          ftq_idx: dis2iss_req_uop_ftq_idx[q][w],
          ftq_offset: dis2iss_req_uop_ftq_offset[q][w],
          is_atomic: dis2iss_req_uop_is_atomic[q][w],
          dest_en: dis2iss_req_uop_dest_en[q][w],
          src1_en: dis2iss_req_uop_src1_en[q][w],
          src2_en: dis2iss_req_uop_src2_en[q][w],
          src1_is_pc: dis2iss_req_uop_src1_is_pc[q][w],
          src2_is_imm: dis2iss_req_uop_src2_is_imm[q][w],
          func3: dis2iss_req_uop_func3[q][w],
          func7: dis2iss_req_uop_func7[q][w],
          imm: dis2iss_req_uop_imm[q][w],
          br_id: dis2iss_req_uop_br_id[q][w],
          br_mask: dis2iss_req_uop_br_mask[q][w],
          csr_idx: dis2iss_req_uop_csr_idx[q][w],
          rob_idx: dis2iss_req_uop_rob_idx[q][w],
          stq_idx: dis2iss_req_uop_stq_idx[q][w],
          stq_flag: dis2iss_req_uop_stq_flag[q][w],
          ldq_idx: dis2iss_req_uop_ldq_idx[q][w],
          rob_flag: dis2iss_req_uop_rob_flag[q][w],
          op: dis2iss_req_uop_op[q][w]
        },
        src1_busy: dis2iss_req_uop_src1_busy[q][w],
        src2_busy: dis2iss_req_uop_src2_busy[q][w]
      };
    end

    for (genvar p = 0; p < NP; p++) begin : g_port
      assign fu_ready[p]          = exe2iss_fu_ready_mask[PB + p];
      assign grant_valid[PB + p]  = g_valid[p];
      assign grant_uop[PB + p]    = g_uop[p];
    end

    isu_iq #(.SIZE(SIZE), .DW(IQ_DISPATCH_WIDTH), .NP(NP), .PORT_BASE(PB)) u_iq (
      .clk(clk), .rst_n(rst_n), .enq_valid(enq_valid), .enq(enq), .woken(woken), .fu_ready(fu_ready),
      .issue_block(issue_block), .flush_all(rob_bcast_flush), .flush_br(flush_br),
      .flush_br_mask(dec_bcast_br_mask), .clear_mask(dec_bcast_clear_mask),
      .free_slots(iss2dis_ready_num[q]), .grant_valid(g_valid), .grant_uop(g_uop));
  end

  // ---- issue ports to the PRF ----
  for (genvar p = 0; p < ISSUE_WIDTH; p++) begin : g_prf
    assign iss2prf_iss_entry_valid[p] = grant_valid[p];
    assign iss2prf_iss_entry_uop_dest_preg[p] = grant_uop[p].dest_preg;
    assign iss2prf_iss_entry_uop_src1_preg[p] = grant_uop[p].src1_preg;
    assign iss2prf_iss_entry_uop_src2_preg[p] = grant_uop[p].src2_preg;
    assign iss2prf_iss_entry_uop_ftq_idx[p] = grant_uop[p].ftq_idx;
    assign iss2prf_iss_entry_uop_ftq_offset[p] = grant_uop[p].ftq_offset;
    assign iss2prf_iss_entry_uop_is_atomic[p] = grant_uop[p].is_atomic;
    assign iss2prf_iss_entry_uop_dest_en[p] = grant_uop[p].dest_en;
    assign iss2prf_iss_entry_uop_src1_en[p] = grant_uop[p].src1_en;
    assign iss2prf_iss_entry_uop_src2_en[p] = grant_uop[p].src2_en;
    assign iss2prf_iss_entry_uop_src1_is_pc[p] = grant_uop[p].src1_is_pc;
    assign iss2prf_iss_entry_uop_src2_is_imm[p] = grant_uop[p].src2_is_imm;
    assign iss2prf_iss_entry_uop_func3[p] = grant_uop[p].func3;
    assign iss2prf_iss_entry_uop_func7[p] = grant_uop[p].func7;
    assign iss2prf_iss_entry_uop_imm[p] = grant_uop[p].imm;
    assign iss2prf_iss_entry_uop_br_id[p] = grant_uop[p].br_id;
    assign iss2prf_iss_entry_uop_br_mask[p] = grant_uop[p].br_mask;
    assign iss2prf_iss_entry_uop_csr_idx[p] = grant_uop[p].csr_idx;
    assign iss2prf_iss_entry_uop_rob_idx[p] = grant_uop[p].rob_idx;
    assign iss2prf_iss_entry_uop_stq_idx[p] = grant_uop[p].stq_idx;
    assign iss2prf_iss_entry_uop_stq_flag[p] = grant_uop[p].stq_flag;
    assign iss2prf_iss_entry_uop_ldq_idx[p] = grant_uop[p].ldq_idx;
    assign iss2prf_iss_entry_uop_rob_flag[p] = grant_uop[p].rob_flag;
    assign iss2prf_iss_entry_uop_op[p] = grant_uop[p].op;
  end

endmodule

`default_nettype wire
