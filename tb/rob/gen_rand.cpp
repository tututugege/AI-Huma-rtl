// Constrained-random trace generator for the Rob: drives the *reference* Rob class (back-end/Rob.cpp) directly in the
// BackTop::comb() order and records the spec/rob.io fields. Covers what the real programs never reach: front_stall,
// page faults, sfence.vma, flush_pipe, mispredict while enqueuing, full/wrap, interrupts with every head state.
//   usage: gen_rand <out.trc> <seed> <cycles> <profile 0..5>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <random>
#define private public
#include "Rob.h"
#undef private
#include "rob_fields.h"
using namespace ttg_io;

long long sim_time = 0;
static std::mt19937_64 rng;
static uint64_t rnd() { return rng(); }
static bool chance(int pm) { return int(rnd() % 1000) < pm; }  // per mille

// ISA-ish type mix: {type code, weight}
static int rand_type(int p_special) {
  if (chance(p_special)) {
    static const int sp[] = {7, 9, 10, 11, 12, 13, 14, 15, 8, 7, 7, 9};  // CSR ECALL EBREAK WFI SFENCE FENCE_I MRET SRET FENCE
    return sp[rnd() % 12];
  }
  static const int common[] = {3, 3, 3, 4, 4, 5, 5, 6, 1, 2, 16, 17, 18, 0, 19};
  return common[rnd() % 15];
}

// write-back port of completion group g for an instruction of this type: loads/AMO use LD ports, stores/AMO STA+STD,
// branches BR ports, everything else the ALU ports
static int group_ports(int g, int pick, int type) {
  bool mem = type == 5 || type == 18;
  if (g == 0) return mem ? 6 + pick % 4 : pick % 6;
  if (g == 1) return (type == 6 || type == 18) ? 10 + pick % 4 : 18 + pick % 4;
  return 14 + pick % 4;
}

int main(int argc, char **argv) {
  if (argc < 5) { std::fprintf(stderr, "usage: gen_rand out.trc seed cycles profile\n"); return 2; }
  uint64_t seed = std::strtoull(argv[2], 0, 0), cycles = std::strtoull(argv[3], 0, 0);
  int prof = std::atoi(argv[4]);
  rng.seed(seed);
  //                      0    1    2    3    4    5
  int p_fire[6]   =  {700, 900, 500, 950, 300, 900};   // dispatch a row
  int p_wb[6]     =  {400, 700, 250, 150, 900, 500};   // each pending uop completes this cycle
  int p_mp[6]     =  { 20,  60,  10,  30,   5, 120};   // mispredict
  int p_int[6]    =  {  3,   5,   2,   1,   0,  10};   // interrupt request
  int p_fs[6]     =  { 80,  30, 300,  50, 100, 500};   // front_stall
  int p_sp[6]     =  { 60,  40,  20,  30,  10, 150};   // special instruction share
  int p_pf[6]     =  { 30,  60,  10,  20,   0, 100};   // page fault / illegal / flush_pipe share
  int p_stq[6]    =  {500, 300, 800, 100, 500, 500};   // committed_store_pending
  int p_full[6]   =  {  0,   0,   0, 800,   0,   0};   // profile 3: hold completions to fill the ROB

  static SimContext ctx_obj;
  Rob rob(&ctx_obj);
  DisRobIO dis2rob; CsrRobIO csr2rob; LsuRobIO lsu2rob; DecBroadcastIO dec_bcast; ExuRobIO exu2rob; FtqRobPcRespIO ftq_resp;
  wire<1> front_stall = 0;
  RobDisIO rob2dis; RobCsrIO rob2csr; RobCommitIO rob_commit; RobBroadcastIO rob_bcast; FtqRobPcReqIO ftq_req;
  rob.in = {&dis2rob, &csr2rob, &lsu2rob, &dec_bcast, &exu2rob, &ftq_resp, &front_stall};
  rob.out = {&rob2dis, &rob2csr, &rob_commit, &rob_bcast, &ftq_req, {}};
  rob.init();

  ttg::TraceWriter<decltype(kFields)> tw(argv[1], kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  for (int k = 0; k < 3; ++k) tw.commit(0, ttg::kFlagReset);

  for (uint64_t cyc = 0; cyc < cycles; ++cyc) {
    // ---- inputs that do not depend on this cycle's outputs ----
    front_stall = chance(p_fs[prof]);
    csr2rob.interrupt_req = chance(p_int[prof]);
    lsu2rob.committed_store_pending = chance(p_stq[prof]);
    ftq_resp = {};
    ftq_resp.resp[0].valid = true; ftq_resp.resp[0].pc = rnd();
    // write-backs: only for valid entries and only for a still-pending completion group (a duplicate would assert)
    exu2rob = {};
    bool port_used[ISSUE_WIDTH] = {false};
    int wb_rate = chance(p_full[prof]) ? 0 : p_wb[prof];
    for (int l = 0; l < ROB_LINE_NUM; l++)
      for (int b = 0; b < ROB_BANK_NUM; b++) {
        auto &e = rob.entry[b][l];
        if (!e.valid) continue;
        for (int g = 0; g < 3; g++) {
          uint32_t bit = 1u << g;
          if (!(e.uop.expect_mask & bit) || (e.uop.cplt_mask & bit) || !chance(wb_rate)) continue;
          int p = group_ports(g, rnd() % 16, e.uop.type), tries = 0;
          while (port_used[p] && tries++ < 8) p = group_ports(g, rnd() % 16, e.uop.type);
          if (port_used[p]) continue;
          port_used[p] = true;
          auto &w = exu2rob.entry[p]; w.valid = true;
          w.uop.rob_idx = l * ROB_BANK_NUM + b; w.uop.diag_val = rnd(); w.uop.result = rnd();
          bool ld = p >= 6 && p < 10, sta = p >= 10 && p < 14, br = p >= 18;
          w.uop.op = br ? (chance(500) ? UOP_BR : UOP_JUMP) : ld ? UOP_LOAD : sta ? UOP_STA : g == 2 ? UOP_STD : UOP_ADD;
          w.uop.mispred = br && chance(300); w.uop.br_taken = br && chance(500);
          if (ld && chance(p_pf[prof])) { int k = rnd() % 3; w.uop.page_fault_load = k == 0; w.uop.page_fault_inst = k == 1; w.uop.page_fault_store = k == 2 && chance(200); if (!(w.uop.page_fault_load | w.uop.page_fault_inst | w.uop.page_fault_store)) w.uop.page_fault_load = true; }
          if (sta && chance(p_pf[prof])) w.uop.page_fault_store = true;
          w.uop.flush_pipe = chance(p_pf[prof] / 4);
        }
      }
    // mispredict: redirect at a currently valid entry
    dec_bcast = {};
    if (chance(p_mp[prof])) {
      int tries = 0; int l, b;
      do { l = rnd() % ROB_LINE_NUM; b = rnd() % ROB_BANK_NUM; } while (!rob.entry[b][l].valid && tries++ < 64);
      if (rob.entry[b][l].valid) { dec_bcast.mispred = true; dec_bcast.redirect_rob_idx = l * ROB_BANK_NUM + b; }
    }
    // dispatch payload (dis_fire decided after the commit stage, like Dispatch::comb_fire sees rob_bcast.flush)
    dis2rob = {};
    int n = chance(100) ? 0 : (chance(600) ? 8 : rnd() % 9);
    for (int i = 0; i < DECODE_WIDTH; i++) {
      auto &u = dis2rob.uop[i];
      int t = rand_type(p_sp[prof]);
      u.type = t; u.diag_val = rnd(); u.dest_areg = rnd() & 31; u.src1_areg = rnd() & 31; u.dest_preg = rnd() & 127;
      u.old_dest_preg = rnd() & 127; u.ftq_idx = rnd() & 63; u.ftq_offset = rnd() & 15; u.ftq_is_last = rnd() & 1;
      u.mispred = rnd() & 1; u.br_taken = rnd() & 1; u.dest_en = rnd() & 1; u.func7 = rnd() & 127; u.func3 = rnd() & 7;
      u.imm = chance(300) ? 0 : rnd(); u.stq_idx = rnd() & 63; u.stq_flag = rnd() & 1; u.rob_flag = rob.enq_flag;
      u.rob_idx = rob.enq_ptr * ROB_BANK_NUM + i;
      u.expect_mask = t == 6 ? 6 : t == 18 ? 7 : (t == 4 || t == 2 || t == 1) ? (chance(500) ? 2 : 3) : 1;
      u.cplt_mask = 0;
      u.page_fault_inst = chance(p_pf[prof] / 3); u.illegal_inst = chance(p_pf[prof] / 4); u.flush_pipe = chance(p_pf[prof] / 5);
      u.tma.mem_commit_is_store = (t == 6) || chance(30); u.tma.mem_commit_is_load = false;
      dis2rob.valid[i] = i < n;
    }
    // ---- comb (BackTop order) ----
    rob.comb_begin();
    rob.comb_ready();
    rob.comb_ftq_pc_req();
    rob.comb_commit();
    rob.comb_complete();
    bool allow = !rob_bcast.flush && !dec_bcast.mispred && !chance(20);
    for (int i = 0; i < DECODE_WIDTH; i++) dis2rob.dis_fire[i] = allow && i < n && chance(p_fire[prof] + (i == 0 ? 0 : 50 > 0 ? 0 : 0)) && rob2dis.ready;
    // a few rows with a hole (some slot not firing)
    if (chance(80)) dis2rob.dis_fire[rnd() % 8] = false;
    rob.comb_branch();
    rob.comb_fire();
    rob.comb_flush();
    // ---- record ----
    auto &W = tw;
    W.set(F_dec_bcast_mispred, 0, dec_bcast.mispred); W.set(F_dec_bcast_redirect_rob_idx, 0, dec_bcast.redirect_rob_idx);
    W.set(F_csr2rob_interrupt_req, 0, csr2rob.interrupt_req);
    W.set(F_lsu2rob_committed_store_pending, 0, lsu2rob.committed_store_pending);
    W.set(F_front_stall, 0, front_stall);
    W.set(F_ftq_rob_pc_resp_resp_pc, 0, ftq_resp.resp[0].pc);
    for (int i = 0; i < 8; i++) {
      auto &u = dis2rob.uop[i];
      W.set(F_dis2rob_dis_fire, i, dis2rob.dis_fire[i]);
      W.set(F_dis2rob_uop_diag_val, i, u.diag_val); W.set(F_dis2rob_uop_dest_areg, i, u.dest_areg);
      W.set(F_dis2rob_uop_src1_areg, i, u.src1_areg); W.set(F_dis2rob_uop_dest_preg, i, u.dest_preg);
      W.set(F_dis2rob_uop_old_dest_preg, i, u.old_dest_preg); W.set(F_dis2rob_uop_ftq_idx, i, u.ftq_idx);
      W.set(F_dis2rob_uop_ftq_offset, i, u.ftq_offset); W.set(F_dis2rob_uop_ftq_is_last, i, u.ftq_is_last);
      W.set(F_dis2rob_uop_mispred, i, u.mispred); W.set(F_dis2rob_uop_br_taken, i, u.br_taken);
      W.set(F_dis2rob_uop_type, i, u.type); W.set(F_dis2rob_uop_dest_en, i, u.dest_en);
      W.set(F_dis2rob_uop_func7, i, u.func7); W.set(F_dis2rob_uop_imm, i, u.imm);
      W.set(F_dis2rob_uop_rob_idx, i, u.rob_idx); W.set(F_dis2rob_uop_stq_idx, i, u.stq_idx);
      W.set(F_dis2rob_uop_stq_flag, i, u.stq_flag); W.set(F_dis2rob_uop_expect_mask, i, u.expect_mask);
      W.set(F_dis2rob_uop_rob_flag, i, u.rob_flag); W.set(F_dis2rob_uop_page_fault_inst, i, u.page_fault_inst);
      W.set(F_dis2rob_uop_illegal_inst, i, u.illegal_inst); W.set(F_dis2rob_uop_flush_pipe, i, u.flush_pipe);
      W.set(F_dis2rob_uop_tma_mem_commit_is_store, i, u.tma.mem_commit_is_store);
      auto &c = rob_commit.commit_entry[i];
      W.set(F_rob_commit_commit_entry_valid, i, c.valid);
      W.set(F_rob_commit_commit_entry_uop_diag_val, i, rob.entry[i][rob.deq_ptr].uop.diag_val);
      W.set(F_rob_commit_commit_entry_uop_dest_areg, i, c.uop.dest_areg); W.set(F_rob_commit_commit_entry_uop_dest_preg, i, c.uop.dest_preg);
      W.set(F_rob_commit_commit_entry_uop_old_dest_preg, i, c.uop.old_dest_preg); W.set(F_rob_commit_commit_entry_uop_ftq_idx, i, c.uop.ftq_idx);
      W.set(F_rob_commit_commit_entry_uop_ftq_offset, i, c.uop.ftq_offset); W.set(F_rob_commit_commit_entry_uop_ftq_is_last, i, c.uop.ftq_is_last);
      W.set(F_rob_commit_commit_entry_uop_mispred, i, c.uop.mispred); W.set(F_rob_commit_commit_entry_uop_br_taken, i, c.uop.br_taken);
      W.set(F_rob_commit_commit_entry_uop_dest_en, i, c.uop.dest_en); W.set(F_rob_commit_commit_entry_uop_func7, i, c.uop.func7);
      W.set(F_rob_commit_commit_entry_uop_rob_idx, i, c.uop.rob_idx); W.set(F_rob_commit_commit_entry_uop_rob_flag, i, c.uop.rob_flag);
      W.set(F_rob_commit_commit_entry_uop_stq_idx, i, c.uop.stq_idx); W.set(F_rob_commit_commit_entry_uop_stq_flag, i, c.uop.stq_flag);
      W.set(F_rob_commit_commit_entry_uop_page_fault_inst, i, c.uop.page_fault_inst);
      W.set(F_rob_commit_commit_entry_uop_page_fault_load, i, c.uop.page_fault_load);
      W.set(F_rob_commit_commit_entry_uop_page_fault_store, i, c.uop.page_fault_store);
      W.set(F_rob_commit_commit_entry_uop_illegal_inst, i, c.uop.illegal_inst); W.set(F_rob_commit_commit_entry_uop_type, i, c.uop.type);
      W.set(F_rob_commit_commit_entry_uop_tma_mem_commit_is_store, i, c.uop.tma.mem_commit_is_store);
      W.set(F_commit_extra_src1_areg, i, rob.out.commit_extra[i].src1_areg); W.set(F_commit_extra_imm, i, rob.out.commit_extra[i].imm);
    }
    for (int p = 0; p < ISSUE_WIDTH; p++) {
      auto &w = exu2rob.entry[p];
      W.set(F_exu2rob_entry_valid, p, w.valid);
      W.set(F_exu2rob_entry_uop_diag_val, p, w.uop.diag_val); W.set(F_exu2rob_entry_uop_result, p, w.uop.result);
      W.set(F_exu2rob_entry_uop_rob_idx, p, w.uop.rob_idx); W.set(F_exu2rob_entry_uop_mispred, p, w.uop.mispred);
      W.set(F_exu2rob_entry_uop_br_taken, p, w.uop.br_taken); W.set(F_exu2rob_entry_uop_page_fault_inst, p, w.uop.page_fault_inst);
      W.set(F_exu2rob_entry_uop_page_fault_load, p, w.uop.page_fault_load); W.set(F_exu2rob_entry_uop_page_fault_store, p, w.uop.page_fault_store);
      W.set(F_exu2rob_entry_uop_op, p, w.uop.op); W.set(F_exu2rob_entry_uop_flush_pipe, p, w.uop.flush_pipe);
    }
    W.set(F_rob2dis_stall, 0, rob2dis.stall); W.set(F_rob2dis_empty, 0, rob2dis.empty); W.set(F_rob2dis_ready, 0, rob2dis.ready);
    W.set(F_rob2dis_enq_idx, 0, rob2dis.enq_idx); W.set(F_rob2dis_rob_flag, 0, rob2dis.rob_flag);
    W.set(F_rob2csr_commit, 0, rob2csr.commit); W.set(F_rob2csr_interrupt_resp, 0, rob2csr.interrupt_resp);
    W.set(F_rob_bcast_flush, 0, rob_bcast.flush); W.set(F_rob_bcast_mret, 0, rob_bcast.mret); W.set(F_rob_bcast_sret, 0, rob_bcast.sret);
    W.set(F_rob_bcast_ecall, 0, rob_bcast.ecall); W.set(F_rob_bcast_exception, 0, rob_bcast.exception);
    W.set(F_rob_bcast_fence, 0, rob_bcast.fence); W.set(F_rob_bcast_fence_i, 0, rob_bcast.fence_i);
    W.set(F_rob_bcast_page_fault_inst, 0, rob_bcast.page_fault_inst); W.set(F_rob_bcast_page_fault_load, 0, rob_bcast.page_fault_load);
    W.set(F_rob_bcast_page_fault_store, 0, rob_bcast.page_fault_store); W.set(F_rob_bcast_illegal_inst, 0, rob_bcast.illegal_inst);
    W.set(F_rob_bcast_interrupt, 0, rob_bcast.interrupt);
    W.set(F_rob_bcast_trap_val_valid, 0, rob_bcast.page_fault_inst || rob_bcast.page_fault_load || rob_bcast.page_fault_store || rob_bcast.illegal_inst);
    W.set(F_rob_bcast_trap_val, 0, rob_bcast.trap_val); W.set(F_rob_bcast_pc, 0, rob_bcast.pc);
    W.set(F_rob_bcast_head_rob_idx, 0, rob_bcast.head_rob_idx); W.set(F_rob_bcast_head_valid, 0, rob_bcast.head_valid);
    W.set(F_rob_bcast_head_incomplete_rob_idx, 0, rob_bcast.head_incomplete_rob_idx);
    W.set(F_rob_bcast_head_incomplete_valid, 0, rob_bcast.head_incomplete_valid);
    W.set(F_ftq_rob_pc_req_req_valid, 0, ftq_req.req[0].valid); W.set(F_ftq_rob_pc_req_req_ftq_idx, 0, ftq_req.req[0].ftq_idx);
    W.set(F_ftq_rob_pc_req_req_ftq_offset, 0, ftq_req.req[0].ftq_offset);
    W.commit(cyc + 3);
    rob.seq();
  }
  tw.flush();
  return 0;
}
