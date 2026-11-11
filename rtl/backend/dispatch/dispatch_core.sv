// Ref: back-end/Dispatch.cpp  class Dispatch (comb_begin/alloc/wake/dispatch/fire/pipeline/seq)
`default_nettype none

// Dispatch core, structured by hardware function (see docs/modules/dispatch.md):
//   inst_stage -> lsu_alloc -> wake_match/src_busy -> decompose -> iq_alloc -> fire_ctl -> iq_req/lsu_req
//   busy_table (state) feeds src_busy and is updated by fire_ctl + wakeups.
module dispatch_core
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  logic                          clk,
  input  logic                          rst_n,
  // rename
  input  logic [NUM_SLOTS-1:0] ren_valid,
  input  dis_inst_t                     ren_inst  [NUM_SLOTS],
  output logic                          dis2ren_ready,
  // rob
  input  logic                          rob_ready,
  input  logic                          rob_empty,
  input  logic                          rob_stall,
  input  logic [ROB_IDX_WIDTH-1:0]      rob_enq_idx,    // line ROB: the line the group will occupy (zero extended);
                                                        // compact ROB: the tail entry
  input  logic [ROB_IDX_WIDTH:0]        rob_free,       // compact ROB: free entries
  input  logic                          rob_enq_flag,
  output logic [NUM_SLOTS-1:0] dis_fire,
  output logic [NUM_SLOTS-1:0] slot_valid,  // PMU: the dispatch stage register holds an instruction in this slot
  output dis_inst_t                     rob_inst  [NUM_SLOTS],
  output dis_res_t                      rob_res   [NUM_SLOTS],
  output logic [CPLT_MASK_W-1:0]        rob_expect_mask [NUM_SLOTS],
  // issue queues
  input  logic [IQ_READY_NUM_WIDTH-1:0] ready_num [IQ_NUM],
  output logic                          req_valid [IQ_NUM][IQ_PORTS],
  output dis_iss_uop_t                  req_uop   [IQ_NUM][IQ_PORTS],
  // lsu
  input  logic [STQ_IDX_WIDTH-1:0]      stq_tail,
  input  logic                          stq_tail_flag,
  input  logic [STQ_FREE_W-1:0]         stq_free,
  input  logic [LDQ_FREE_W-1:0]         ldq_free,
  input  logic [LDQ_IDX_WIDTH-1:0]      ldq_alloc_idx   [LDQ_PORTS],
  input  logic [LDQ_PORTS-1:0] ldq_alloc_valid,
  output logic [STQ_PORTS-1:0] st_req,
  output logic [BR_MASK_WIDTH-1:0]      st_br_mask  [STQ_PORTS],
  output logic [2:0]                    st_func3    [STQ_PORTS],
  output logic [ROB_IDX_WIDTH-1:0]      st_rob_idx  [STQ_PORTS],
  output logic [STQ_PORTS-1:0] st_rob_flag,
  output logic [STQ_PORTS-1:0] st_stq_flag,
  output logic [LDQ_PORTS-1:0] ld_req,
  output logic [LDQ_IDX_WIDTH-1:0]      ld_idx      [LDQ_PORTS],
  output logic [BR_MASK_WIDTH-1:0]      ld_br_mask  [LDQ_PORTS],
  output logic [ROB_IDX_WIDTH-1:0]      ld_rob_idx  [LDQ_PORTS],
  output logic [LDQ_PORTS-1:0] ld_rob_flag,
  output logic [LSU_MDP_BITS-1:0]       ld_mdp      [LDQ_PORTS],
  // wakeups (prf_awake ports first, then iss_awake ports) and branch / flush broadcasts
  input  logic [PRF_NUM-1:0] cancel_v,
  input  logic [NUM_WAKE-1:0] wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0]      wake_preg  [NUM_WAKE],
  input  logic                          rob_flush,
  input  logic                          dec_mispred,
  input  logic [BR_MASK_WIDTH-1:0]      dec_clear_mask
);

  // ---- register stage and static classification ----
  logic [NUM_SLOTS-1:0] inst_valid;
  dis_inst_t  inst_q     [NUM_SLOTS];
  dis_inst_t  alloc_inst [NUM_SLOTS];   // inst_alloc[]: br_mask cleaned
  dis_class_t cls        [NUM_SLOTS];
  logic [NUM_SLOTS-1:0] is_load;
  logic [NUM_SLOTS-1:0] is_store;
  logic [NUM_SLOTS-1:0] is_csr_like;
  logic [NUM_SLOTS-1:0] is_amo;
  logic [NUM_SLOTS-1:0] is_wfi;

  always_comb begin
    for (int i = 0; i < NUM_SLOTS; i++) begin
      alloc_inst[i] = inst_q[i];
      alloc_inst[i].br_mask = inst_q[i].br_mask & ~dec_clear_mask;
      cls[i]         = dis_classify(inst_q[i].itype, inst_q[i].func7[6:2]);
      is_load[i]     = cls[i].is_load;
      is_store[i]    = cls[i].is_store;
      is_csr_like[i] = dis_is_csr_like(inst_q[i].itype);
      is_amo[i]      = cls[i].is_amo;
      is_wfi[i]      = (inst_q[i].itype == INST_WFI);
    end
  end

  // ---- comb_alloc: ROB slot + LSU entries ----
  logic [STQ_IDX_WIDTH-1:0] stq_idx [NUM_SLOTS];
  logic [NUM_SLOTS-1:0] stq_flag;
  logic [LDQ_IDX_WIDTH-1:0] ldq_idx [NUM_SLOTS];
  logic [STQ_PORTS-1:0]     st_port_sel [NUM_SLOTS];
  logic [LDQ_PORTS-1:0]     ld_port_sel [NUM_SLOTS];
  dis_res_t                 res [NUM_SLOTS];
  logic [NUM_SLOTS-1:0] lsu_ok;   // load/store got its LSU entry

  dispatch_lsu_alloc u_lsu_alloc (
    .inst_valid(inst_valid), .is_load(is_load), .is_store(is_store), .stq_tail(stq_tail),
    .stq_tail_flag(stq_tail_flag), .stq_free(stq_free), .ldq_free(ldq_free),
    .ldq_alloc_idx(ldq_alloc_idx), .ldq_alloc_valid(ldq_alloc_valid), .lsu_ok(lsu_ok),
    .stq_idx(stq_idx), .stq_flag(stq_flag), .ldq_idx(ldq_idx),
    .st_port_sel(st_port_sel), .ld_port_sel(ld_port_sel));

  // Ref: Dispatch::comb_alloc make_rob_idx(enq_idx, i): {ROB line, lane within line}; compact ROB: tail + rank of
  // the lane among the valid lanes (the lanes that fire are the first valid ones), the flag flips past the ring end
  always_comb begin
    int unsigned rank;
    logic [ROB_IDX_WIDTH:0] pos;
    rank = 0;
    for (int i = 0; i < NUM_SLOTS; i++) begin
      pos = {1'b0, rob_enq_idx} + (ROB_IDX_WIDTH+1)'(rank);
      if (ROB_COMPACT != 0) begin
        res[i].rob_idx  = pos[ROB_IDX_WIDTH-1:0];
        res[i].rob_flag = rob_enq_flag ^ pos[ROB_IDX_WIDTH];
      end else begin
        res[i].rob_idx  = {rob_enq_idx[ROB_LINE_W-1:0], SLOT_IDX_W'(i)};
        res[i].rob_flag = rob_enq_flag;
      end
      rank = rank + (inst_valid[i] ? 1 : 0);
      res[i].stq_idx  = stq_idx[i];
      res[i].stq_flag = stq_flag[i];
      res[i].ldq_idx  = ldq_idx[i];
    end
  end

  // ---- comb_wake: wakeup CAM and source busy bits ----
  logic [PRF_NUM-1:0]      busy_table;
  logic [PRF_IDX_WIDTH-1:0] src_preg [2 * NUM_SLOTS];   // {src2, src1} of lane i at 2i+1, 2i
  logic                    woken_all [2 * NUM_SLOTS];
  logic [NUM_SLOTS-1:0] woken1;
  logic [NUM_SLOTS-1:0] woken2;
  logic [NUM_SLOTS-1:0] busy1;
  logic [NUM_SLOTS-1:0] busy2;

  always_comb begin
    for (int i = 0; i < NUM_SLOTS; i++) begin
      src_preg[2*i]   = inst_q[i].src1_preg;
      src_preg[2*i+1] = inst_q[i].src2_preg;
      woken1[i] = woken_all[2*i];
      woken2[i] = woken_all[2*i+1];
    end
  end

  dispatch_wake_match u_wake_match (
    .wake_valid(wake_valid), .wake_preg(wake_preg), .src_preg(src_preg), .woken(woken_all));

  dispatch_src_busy u_src_busy (
    .busy_table(busy_table | cancel_v), .inst(alloc_inst), .inst_valid(inst_valid),
    .woken1(woken1), .woken2(woken2), .busy1(busy1), .busy2(busy2));

  // ---- comb_dispatch: uop split and IQ port allocation ----
  logic [IQ_NUM-1:0]       has_iq [NUM_SLOTS];
  dis_iss_uop_t            uop_iq [NUM_SLOTS][IQ_NUM];
  logic [CPLT_MASK_W-1:0]  expect_mask [NUM_SLOTS];
  logic [IQ_PORT_W-1:0]    port_idx [NUM_SLOTS][IQ_NUM];
  logic [NUM_SLOTS-1:0] fit;

  for (genvar i = 0; i < NUM_SLOTS; i++) begin : g_decompose
    dis_iss_uop_t lane_uop [IQ_NUM];
    dis_iss_uop_t base_uop;
    // Ref: Dispatch::make_dis_iss_uop
    always_comb begin
      base_uop = '{dest_preg: alloc_inst[i].dest_preg, src1_preg: alloc_inst[i].src1_preg,
                   src2_preg: alloc_inst[i].src2_preg, ftq_idx: alloc_inst[i].ftq_idx,
                   ftq_offset: alloc_inst[i].ftq_offset, is_atomic: alloc_inst[i].is_atomic,
                   dest_en: alloc_inst[i].dest_en, src1_en: alloc_inst[i].src1_en,
                   src2_en: alloc_inst[i].src2_en, src1_busy: busy1[i], src2_busy: busy2[i],
                   src1_is_pc: alloc_inst[i].src1_is_pc, src2_is_imm: alloc_inst[i].src2_is_imm,
                   is_word: alloc_inst[i].is_word,
                   func3: alloc_inst[i].func3, func7: alloc_inst[i].func7, imm: alloc_inst[i].imm,
                   br_id: alloc_inst[i].br_id, br_mask: alloc_inst[i].br_mask,
                   csr_idx: alloc_inst[i].csr_idx, rob_idx: res[i].rob_idx, stq_idx: res[i].stq_idx,
                   stq_flag: res[i].stq_flag, ldq_idx: res[i].ldq_idx, rob_flag: res[i].rob_flag,
                   op: UOP_ADD};
    end
    dispatch_decompose u_decompose (
      .base(base_uop), .itype(alloc_inst[i].itype), .cls(cls[i]), .me_elim(alloc_inst[i].me_elim),
      .has_iq(has_iq[i]), .uop_iq(lane_uop), .expect_mask(expect_mask[i]));
    always_comb begin
      for (int q = 0; q < IQ_NUM; q++) uop_iq[i][q] = lane_uop[q];
    end
  end

  dispatch_iq_alloc u_iq_alloc (
    .inst_valid(inst_valid), .has_iq(has_iq), .ready_num(ready_num),
    .port_idx(port_idx), .fit(fit));

  // ---- comb_fire ----
  dispatch_fire_ctl u_fire_ctl (
    .inst_valid(inst_valid), .lsu_ok(lsu_ok), .fit(fit), .is_csr_like(is_csr_like),
    .is_amo(is_amo), .is_wfi(is_wfi), .rob_ready(rob_ready), .rob_free(rob_free), .rob_empty(rob_empty),
    .rob_stall(rob_stall), .rob_flush(rob_flush), .dec_mispred(dec_mispred),
    .dis_fire(dis_fire), .dis2ren_ready(dis2ren_ready));

  dispatch_iq_req u_iq_req (
    .fire(dis_fire), .has_iq(has_iq), .port_idx(port_idx), .uop_iq(uop_iq),
    .req_valid(req_valid), .req_uop(req_uop));

  logic [LSU_MDP_BITS-1:0] inst_mdp [NUM_SLOTS];
  always_comb begin
    for (int i = 0; i < NUM_SLOTS; i++) inst_mdp[i] = inst_q[i].mdp;
  end
  dispatch_lsu_req u_lsu_req (
    .fire(dis_fire), .st_port_sel(st_port_sel), .ld_port_sel(ld_port_sel), .inst(alloc_inst), .res(res), .mdp(inst_mdp),
    .st_req(st_req), .st_br_mask(st_br_mask), .st_func3(st_func3), .st_rob_idx(st_rob_idx),
    .st_rob_flag(st_rob_flag), .st_stq_flag(st_stq_flag), .ld_req(ld_req), .ld_idx(ld_idx),
    .ld_br_mask(ld_br_mask), .ld_rob_idx(ld_rob_idx), .ld_rob_flag(ld_rob_flag), .ld_mdp(ld_mdp));

  logic [NUM_SLOTS-1:0] busy_set_valid;
  logic [PRF_IDX_WIDTH-1:0] busy_set_preg  [NUM_SLOTS];
  always_comb begin
    for (int i = 0; i < NUM_SLOTS; i++) begin
      // an eliminated move owns no register: its destination is its source's
      busy_set_valid[i] = dis_fire[i] && inst_q[i].dest_en && !inst_q[i].me_elim;
      busy_set_preg[i]  = inst_q[i].dest_preg;
    end
  end

  dispatch_busy_table u_busy_table (
    .clk(clk), .rst_n(rst_n), .cancel_v(cancel_v), .wake_valid(wake_valid), .wake_preg(wake_preg),
    .set_valid(busy_set_valid), .set_preg(busy_set_preg), .busy_q(busy_table));

  // ---- outputs towards the ROB (consumed only for lanes that fire) ----
  always_comb begin
    for (int i = 0; i < NUM_SLOTS; i++) begin
      rob_inst[i] = alloc_inst[i];
      rob_res[i]  = res[i];
      rob_expect_mask[i] = expect_mask[i];
    end
  end

  // ---- comb_pipeline / seq ----
  assign slot_valid = inst_valid;

  dispatch_inst_stage u_inst_stage (
    .clk(clk), .rst_n(rst_n), .kill(rob_flush || dec_mispred), .ready(dis2ren_ready),
    .clear_mask(dec_clear_mask), .ren_valid(ren_valid), .ren_inst(ren_inst), .fire(dis_fire),
    .alloc_src1_busy(busy1), .alloc_src2_busy(busy2), .woken1(woken1), .woken2(woken2),
    .valid_q(inst_valid), .inst_q(inst_q));

endmodule

`default_nettype wire
