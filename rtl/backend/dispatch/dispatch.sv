// Ref: back-end/Dispatch.cpp  class Dispatch
`default_nettype none

// Top-level wrapper for dispatch_core: adapts packed ren2dis / dis2rob / dis2iss structs and LSU ports.
module dispatch
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
  import ren_pkg::ren_out_uop_t;
(
  input  logic                          clk,
  input  logic                          rst_n,
  input  logic [DECODE_WIDTH-1:0]       ren2dis_valid,
  input  ren_out_uop_t                  ren2dis_uop [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0]       ren2dis_uop_is_rvc,
  input  logic [LSU_MDP_BITS-1:0]       ren2dis_uop_mdp [DECODE_WIDTH],
  input  logic [31:0]                   ren2dis_uop_pc [DECODE_WIDTH],
  input  logic                          rob2dis_ready,
  input  logic                          rob2dis_empty,
  input  logic                          rob2dis_stall,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [ROB_IDX_WIDTH-1:0]      rob2dis_enq_idx,
  input  logic [ROB_IDX_WIDTH:0]        rob2dis_free,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic                          rob2dis_rob_flag,
  input  logic [IQ_READY_NUM_WIDTH-1:0] iss2dis_ready_num [IQ_NUM],
  input  logic [5:0]                    lsu2dis_stq_tail,
  input  logic                          lsu2dis_stq_tail_flag,
  input  logic [6:0]                    lsu2dis_stq_free,
  input  logic [6:0]                    lsu2dis_ldq_free,
  input  logic [5:0]                    lsu2dis_ldq_alloc_idx [DECODE_WIDTH],
  input  logic [DECODE_WIDTH-1:0]       lsu2dis_ldq_alloc_valid,
  input  logic [MAX_WAKEUP_PORTS-1:0]   iss_awake_wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0]      iss_awake_wake_preg [MAX_WAKEUP_PORTS],
  input  logic [ALU_NUM-1:0]            iss_awake_cancel_valid,
  input  logic [PRF_IDX_WIDTH-1:0]      iss_awake_cancel_preg [ALU_NUM],
  input  logic [NUM_LSU_WAKE-1:0]       lsu2iss_wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0]      lsu2iss_wake_preg [NUM_LSU_WAKE],
  input  logic [LSU_LDU_COUNT-1:0]      lsu2iss_cancel_valid,
  input  logic [PRF_IDX_WIDTH-1:0]      lsu2iss_cancel_preg [LSU_LDU_COUNT],
  input  logic                          rob_bcast_flush,
  input  logic                          dec_bcast_mispred,
  output logic                          dis2ren_ready,
  output logic [DECODE_WIDTH-1:0]       dis2rob_dis_fire,
  output logic                          pmu_slot_valid [DECODE_WIDTH],
  output dis_rob_uop_t                  dis2rob_uop [DECODE_WIDTH],
  output logic                          dis2iss_req_valid [IQ_NUM][DECODE_WIDTH],
  output dis_iss_uop_t                  dis2iss_req_uop [IQ_NUM][DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0]       dis2lsu_alloc_req,
  output logic [ROB_IDX_WIDTH-1:0]      dis2lsu_rob_idx [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0]       dis2lsu_rob_flag,
  output logic [DECODE_WIDTH-1:0]       dis2lsu_ldq_alloc_req,
  output logic [5:0]                    dis2lsu_ldq_idx [DECODE_WIDTH],
  output logic [ROB_IDX_WIDTH-1:0]      dis2lsu_ldq_rob_idx [DECODE_WIDTH],
  output logic [DECODE_WIDTH-1:0]       dis2lsu_ldq_rob_flag,
  output logic [LSU_MDP_BITS-1:0]       dis2lsu_ldq_mdp [DECODE_WIDTH],
  output logic [31:0]                   dis2lsu_ldq_pc [DECODE_WIDTH]
);

  dis_inst_t                ren_inst [NUM_SLOTS];
  logic [NUM_SLOTS-1:0]     slot_valid_vec;
  dis_inst_t                rob_inst [NUM_SLOTS];
  dis_res_t                 rob_res  [NUM_SLOTS];
  logic [CPLT_MASK_W-1:0]   rob_expect_mask [NUM_SLOTS];
  /* verilator lint_off UNUSEDSIGNAL */
  logic [2:0]               unused_st_func3 [STQ_PORTS];
  logic [STQ_PORTS-1:0]     unused_st_stq_flag;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [NUM_WAKE-1:0]      wake_valid;
  logic [PRF_IDX_WIDTH-1:0] wake_preg [NUM_WAKE];

  always_comb begin
    for (int i = 0; i < NUM_SLOTS; i++) begin
      ren_inst[i] = '{
        diag_val:        ren2dis_uop[i].diag_val,
        dest_areg:       ren2dis_uop[i].dest_areg,
        src1_areg:       ren2dis_uop[i].src1_areg,
        dest_preg:       ren2dis_uop[i].dest_preg,
        src1_preg:       ren2dis_uop[i].src1_preg,
        src2_preg:       ren2dis_uop[i].src2_preg,
        src3_preg:       ren2dis_uop[i].src3_preg,
        me_elim:         ren2dis_uop[i].me_elim,
        dest_fp:         ren2dis_uop[i].dest_fp,
        src1_fp:         ren2dis_uop[i].src1_fp,
        src2_fp:         ren2dis_uop[i].src2_fp,
        src3_en:         ren2dis_uop[i].src3_en,
        fp_cls:          ren2dis_uop[i].fp_cls,
        ftq_idx:         ren2dis_uop[i].ftq_idx,
        ftq_offset:      ren2dis_uop[i].ftq_offset,
        ftq_is_last:     ren2dis_uop[i].ftq_is_last,
        itype:           inst_type_e'(ren2dis_uop[i].inst_type),
        dest_en:         ren2dis_uop[i].dest_en,
        src1_en:         ren2dis_uop[i].src1_en,
        src2_en:         ren2dis_uop[i].src2_en,
        is_atomic:       ren2dis_uop[i].is_atomic,
        src1_is_pc:      ren2dis_uop[i].src1_is_pc,
        src2_is_imm:     ren2dis_uop[i].src2_is_imm,
        is_word:         ren2dis_uop[i].is_word,
        func3:           ren2dis_uop[i].func3,
        func7:           ren2dis_uop[i].func7,
        imm:             ren2dis_uop[i].imm,
        csr_idx:         ren2dis_uop[i].csr_idx,
        page_fault_inst: ren2dis_uop[i].page_fault_inst,
        pf_inst_hi:      ren2dis_uop[i].pf_inst_hi,
        illegal_inst:    ren2dis_uop[i].illegal_inst,
        mdp:             ren2dis_uop_mdp[i],
        pc:              ren2dis_uop_pc[i],
        is_rvc:          ren2dis_uop_is_rvc[i]
      };
    end
    for (int w = 0; w < MAX_WAKEUP_PORTS; w++) begin
      wake_valid[w] = iss_awake_wake_valid[w];
      wake_preg[w]  = iss_awake_wake_preg[w];
    end
    for (int w = 0; w < NUM_LSU_WAKE; w++) begin
      wake_valid[MAX_WAKEUP_PORTS + w] = lsu2iss_wake_valid[w];
      wake_preg[MAX_WAKEUP_PORTS + w]  = lsu2iss_wake_preg[w];
    end
  end

  logic [TAG_NUM-1:0] cancel_v;
  always_comb begin
    cancel_v = '0;
    for (int k = 0; k < LSU_LDU_COUNT; k++)
      if (lsu2iss_cancel_valid[k]) cancel_v[lsu2iss_cancel_preg[k]] = 1'b1;
    for (int a = 0; a < ALU_NUM; a++)
      if (iss_awake_cancel_valid[a]) cancel_v[iss_awake_cancel_preg[a]] = 1'b1;
  end

  dispatch_core u_core (
    .clk(clk), .rst_n(rst_n), .cancel_v(cancel_v),
    .ren_valid(ren2dis_valid), .ren_inst(ren_inst), .dis2ren_ready(dis2ren_ready),
    .rob_ready(rob2dis_ready), .rob_empty(rob2dis_empty), .rob_stall(rob2dis_stall),
    .rob_enq_idx(rob2dis_enq_idx), .rob_free(rob2dis_free), .rob_enq_flag(rob2dis_rob_flag),
    .dis_fire(dis2rob_dis_fire), .slot_valid(slot_valid_vec), .rob_inst(rob_inst), .rob_res(rob_res),
    .rob_expect_mask(rob_expect_mask), .ready_num(iss2dis_ready_num),
    .req_valid(dis2iss_req_valid), .req_uop(dis2iss_req_uop),
    .stq_tail(lsu2dis_stq_tail), .stq_tail_flag(lsu2dis_stq_tail_flag), .stq_free(lsu2dis_stq_free),
    .ldq_free(lsu2dis_ldq_free), .ldq_alloc_idx(lsu2dis_ldq_alloc_idx), .ldq_alloc_valid(lsu2dis_ldq_alloc_valid),
    .st_req(dis2lsu_alloc_req), .st_func3(unused_st_func3), .st_rob_idx(dis2lsu_rob_idx),
    .st_rob_flag(dis2lsu_rob_flag), .st_stq_flag(unused_st_stq_flag),
    .ld_req(dis2lsu_ldq_alloc_req), .ld_idx(dis2lsu_ldq_idx),
    .ld_rob_idx(dis2lsu_ldq_rob_idx), .ld_rob_flag(dis2lsu_ldq_rob_flag),
    .ld_mdp(dis2lsu_ldq_mdp), .ld_pc(dis2lsu_ldq_pc),
    .wake_valid(wake_valid), .wake_preg(wake_preg), .rob_flush(rob_bcast_flush),
    .dec_mispred(dec_bcast_mispred)
  );

  always_comb begin
    for (int i = 0; i < NUM_SLOTS; i++) begin
      pmu_slot_valid[i] = slot_valid_vec[i];
      dis2rob_uop[i] = '{
        diag_val:        rob_inst[i].diag_val,
        dest_areg:       rob_inst[i].dest_areg,
        src1_areg:       rob_inst[i].src1_areg,
        dest_fp:         rob_inst[i].dest_fp,
        fs_need:         FP_EN && ((rob_inst[i].itype == INST_FPOP) ||
                                   (rob_inst[i].itype == INST_LOAD && rob_inst[i].dest_fp) ||
                                   (rob_inst[i].itype == INST_STORE && rob_inst[i].src2_fp) ||
                                   (rob_inst[i].itype == INST_CSR && rob_inst[i].csr_idx >= CSR_IDX_WIDTH'(1) &&
                                    rob_inst[i].csr_idx <= CSR_IDX_WIDTH'(3))),
        ftq_idx:         rob_inst[i].ftq_idx,
        ftq_offset:      rob_inst[i].ftq_offset,
        ftq_is_last:     rob_inst[i].ftq_is_last,
        itype:           rob_inst[i].itype,
        dest_en:         rob_inst[i].dest_en,
        is_amo_lr:       (rob_inst[i].func7[6:2] == AMO_LR),
        imm:             rob_inst[i].imm,
        rob_idx:         rob_res[i].rob_idx,
        stq_idx:         rob_res[i].stq_idx,
        stq_flag:        rob_res[i].stq_flag,
        expect_mask:     rob_expect_mask[i],
        rob_flag:        rob_res[i].rob_flag,
        page_fault_inst: rob_inst[i].page_fault_inst,
        pf_inst_hi:      rob_inst[i].pf_inst_hi,
        illegal_inst:    rob_inst[i].illegal_inst
      };
    end
  end

endmodule

`default_nettype wire
