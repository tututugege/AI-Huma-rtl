// Constrained-random trace generator for the Idu: drives the *reference* Idu class (back-end/Idu.cpp) directly with
// random inputs in the same cycle order as BackTop::comb() and records the spec/idu.io fields into a .trc file.
// Purpose: cover paths the real programs never reach (tag exhaustion/stall, page-fault entries, AMO rd=x0, CSR immediate
// forms, SFENCE.VMA, flush with branches in flight, mispredict while rename ready, gaps in the issue group, ...).
//   usage: gen_rand <out.trc> <seed> <cycles> <profile 0..7>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <random>
#include "Idu.h"
#include "idu_fields.h"
using namespace ttg_io;

long long sim_time = 0;   // referenced by the reference model's Assert()
static std::mt19937_64 rng;
static uint64_t rnd() { return rng(); }
static bool chance(int pct_x10) { return int(rnd() % 1000) < pct_x10; }   // per mille

static const uint32_t kCsr[21] = {0x305,0x341,0x342,0x304,0x344,0x343,0x340,0x300,0x303,0x302,0x141,
                                  0x105,0x142,0x140,0x143,0x100,0x104,0x144,0x180,0xf14,0x301};

static uint32_t rv(int hi, int lo, uint32_t v) { return (v & ((1u << (hi - lo + 1)) - 1)) << lo; }

static uint32_t rand_inst() {
  uint32_t r = rnd(), f3 = r & 7, rd = (r >> 3) & 31, rs1 = (r >> 8) & 31, rs2 = (r >> 13) & 31, hi = rnd() & 0xfffff000u;
  int pick = rnd() % 100;
  if (pick < 24) return 0x63 | (hi & 0xfe000000u) | (rs2 << 20) | (rs1 << 15) | ((f3 & 7) << 12) | (rd << 7);       // BR
  if (pick < 34) return 0x67 | (rs1 << 15) | (f3 << 12) | (rd << 7) | (chance(300) ? 0 : (hi & 0xfff00000u));     // JALR
  if (pick < 36) return 0x6f | (hi & 0xfffff000u) | (rd << 7);                                                   // JAL
  if (pick < 40) return 0x37 | (hi & 0xfffff000u) | (rd << 7);                                                   // LUI
  if (pick < 43) return 0x17 | (hi & 0xfffff000u) | (rd << 7);                                                   // AUIPC
  if (pick < 50) return 0x03 | (hi & 0xfff00000u) | (rs1 << 15) | (f3 << 12) | (rd << 7);                         // LOAD
  if (pick < 56) return 0x23 | (hi & 0xfe000000u) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7);          // STORE
  if (pick < 62) return 0x13 | (hi & 0xfff00000u) | (rs1 << 15) | (f3 << 12) | (rd << 7);                         // OP-IMM
  if (pick < 70) {                                                                                               // OP
    uint32_t f7 = chance(300) ? 1 : (rnd() & 0x7f);
    return 0x33 | (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7);
  }
  if (pick < 72) return 0x0f | (f3 << 12) | (hi & 0xfff00000u) | (rd << 7) | (rs1 << 15);                          // FENCE*
  if (pick < 80) {                                                                                               // CSR
    uint32_t c = chance(150) ? (chance(500) ? 0xc01 : 0xc81) : (chance(100) ? (rnd() & 0xfff) : kCsr[rnd() % 21]);
    uint32_t ff3 = 1 + rnd() % 7; if (ff3 == 4) ff3 = 5;
    return 0x73 | (c << 20) | (rs1 << 15) | (ff3 << 12) | (rd << 7);
  }
  if (pick < 85) {                                                                                               // plain SYSTEM
    static const uint32_t s[] = {0x00000073, 0x00100073, 0x30200073, 0x10200073, 0x10500073};
    uint32_t i = chance(700) ? s[rnd() % 5] : (0x73 | (rnd() & 0xfffff000u & ~0x7000u) | (chance(500) ? 0 : (f3 << 12)));
    if (chance(400)) i = 0x73 | (0x09u << 25) | (rs2 << 20) | (rs1 << 15) | (chance(800) ? 0 : (f3 << 12)) | (chance(600) ? 0 : (rd << 7));  // SFENCE.VMA
    return i;
  }
  if (pick < 91) {                                                                                               // AMO
    uint32_t op5 = chance(300) ? (chance(500) ? 2 : 3) : (rnd() % 32);
    return 0x2f | (op5 << 27) | (rnd() & (3u << 25)) | (rs2 << 20) | (rs1 << 15) | (2u << 12) | ((chance(400) ? 0 : rd) << 7);
  }
  if (pick < 96) {                                                                                               // FP
    static const uint32_t f7s[] = {0x60, 0x68, 0x2c, 0x70, 0x00, 0x04, 0x08, 0x0c, 0x50, 0x78};
    uint32_t f7 = chance(600) ? f7s[rnd() % 10] : (rnd() & 0x7f);
    return 0x53 | (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7);
  }
  if (pick < 98) return 0x67 | (1u << 15) | 0;                                                                   // ret
  return (uint32_t)rnd();                                                                                        // anything
}

int main(int argc, char **argv) {
  if (argc < 5) { std::fprintf(stderr, "usage: gen_rand out.trc seed cycles profile\n"); return 2; }
  uint64_t seed = std::strtoull(argv[2], 0, 0), cycles = std::strtoull(argv[3], 0, 0);
  int prof = std::atoi(argv[4]);
  rng.seed(seed);
  // profile knobs (per mille): branch-resolution rate, flush rate, rename-ready rate, page-fault rate, gap rate
  int p_clear[8] = {300, 30, 5, 600, 100, 2, 150, 400};
  int p_flush[8] = {5, 5, 2, 20, 2, 1, 40, 0};
  int p_ready[8] = {800, 900, 950, 500, 990, 1000, 700, 1000};
  int p_pf[8] = {20, 10, 5, 100, 0, 5, 50, 30};
  int p_gap[8] = {50, 0, 20, 300, 0, 100, 10, 0};
  int p_mp[8] = {200, 100, 30, 400, 100, 10, 100, 300};
  int p_junk[8] = {20, 10, 0, 100, 5, 0, 50, 0};

  static SimContext ctx_obj;   // only used by the reference's perf counters
  Idu idu(&ctx_obj, MAX_BR_PER_CYCLE);
  PreIduIssueIO issue; RenDecIO ren2dec; RobBroadcastIO rob_bcast; ExuIdIO exu2id;
  DecRenIO dec2ren; DecBroadcastIO dec_bcast; IduConsumeIO consume;
  idu.in = {&issue, &ren2dec, &rob_bcast, &exu2id};
  idu.out = {&dec2ren, &dec_bcast, &consume};
  idu.init();

  ttg::TraceWriter<decltype(kFields)> tw(argv[1], kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  for (int k = 0; k < 3; ++k) tw.commit(0, ttg::kFlagReset);

  for (uint64_t cyc = 0; cyc < cycles; ++cyc) {
    // ---- inputs ----
    int n = chance(150) ? 0 : (chance(500) ? 8 : rnd() % 9);
    for (int i = 0; i < DECODE_WIDTH; i++) {
      bool v = i < n;
      if (chance(p_gap[prof])) v = !v;
      auto &e = issue.entries[i];
      e.valid = v; e.inst = rand_inst(); e.pc = rnd();
      e.page_fault_inst = v && chance(p_pf[prof]);
      e.ftq_idx = rnd() & 63; e.ftq_offset = rnd() & 15; e.ftq_is_last = rnd() & 1;
    }
    ren2dec.ready = chance(p_ready[prof]);
    rob_bcast.flush = chance(p_flush[prof]);
    uint64_t inflight = idu.now_br_mask;
    exu2id = {};
    exu2id.clear_mask = 0;
    for (int t = 1; t < 64; t++)
      if (((inflight >> t) & 1) && chance(p_clear[prof])) exu2id.clear_mask |= 1ull << t;
    if (chance(p_junk[prof])) exu2id.clear_mask |= rnd() & rnd();           // clear bits of free tags, bit 0, ...
    if (chance(p_mp[prof] / 10 + 1)) {
      exu2id.mispred = true;
      uint32_t t = 0;
      if (inflight && !chance(p_junk[prof])) { do t = rnd() & 63; while (!((inflight >> t) & 1)); }
      else t = rnd() & 63;
      exu2id.br_id = t;
      exu2id.clear_mask |= 1ull << t;
      exu2id.redirect_pc = rnd(); exu2id.redirect_rob_idx = rnd() & 127; exu2id.ftq_idx = rnd() & 63;
    }
    // ---- comb (BackTop order) ----
    idu.comb_begin();
    idu.comb_branch();
    idu.comb_decode();
    idu.comb_fire();
    // ---- record ----
    auto &W = tw;
    for (int i = 0; i < 8; i++) {
      W.set(F_pre_issue_entries_valid, i, issue.entries[i].valid);
      W.set(F_pre_issue_entries_inst, i, issue.entries[i].inst);
      W.set(F_pre_issue_entries_page_fault_inst, i, issue.entries[i].page_fault_inst);
      W.set(F_pre_issue_entries_ftq_idx, i, issue.entries[i].ftq_idx);
      W.set(F_pre_issue_entries_ftq_offset, i, issue.entries[i].ftq_offset);
      W.set(F_pre_issue_entries_ftq_is_last, i, issue.entries[i].ftq_is_last);
      W.set(F_dec2ren_valid, i, dec2ren.valid[i]);
      auto &u = dec2ren.uop[i];
      W.set(F_dec2ren_uop_diag_val, i, u.diag_val); W.set(F_dec2ren_uop_dest_areg, i, u.dest_areg);
      W.set(F_dec2ren_uop_src1_areg, i, u.src1_areg); W.set(F_dec2ren_uop_src2_areg, i, u.src2_areg);
      W.set(F_dec2ren_uop_ftq_idx, i, u.ftq_idx); W.set(F_dec2ren_uop_ftq_offset, i, u.ftq_offset);
      W.set(F_dec2ren_uop_ftq_is_last, i, u.ftq_is_last); W.set(F_dec2ren_uop_type, i, u.type);
      W.set(F_dec2ren_uop_dest_en, i, u.dest_en); W.set(F_dec2ren_uop_src1_en, i, u.src1_en);
      W.set(F_dec2ren_uop_src2_en, i, u.src2_en); W.set(F_dec2ren_uop_is_atomic, i, u.is_atomic);
      W.set(F_dec2ren_uop_src1_is_pc, i, u.src1_is_pc); W.set(F_dec2ren_uop_src2_is_imm, i, u.src2_is_imm);
      W.set(F_dec2ren_uop_func3, i, u.func3); W.set(F_dec2ren_uop_func7, i, u.func7);
      W.set(F_dec2ren_uop_imm, i, u.imm); W.set(F_dec2ren_uop_br_id, i, u.br_id);
      W.set(F_dec2ren_uop_br_mask, i, u.br_mask); W.set(F_dec2ren_uop_csr_idx, i, u.csr_idx);
      W.set(F_dec2ren_uop_expect_mask, i, u.expect_mask); W.set(F_dec2ren_uop_cplt_mask, i, u.cplt_mask);
      W.set(F_dec2ren_uop_page_fault_inst, i, u.page_fault_inst); W.set(F_dec2ren_uop_illegal_inst, i, u.illegal_inst);
      W.set(F_dec2ren_uop_tma_is_cache_miss, i, u.tma.is_cache_miss); W.set(F_dec2ren_uop_tma_is_ret, i, u.tma.is_ret);
      W.set(F_dec2ren_uop_tma_mem_commit_is_load, i, u.tma.mem_commit_is_load);
      W.set(F_dec2ren_uop_tma_mem_commit_is_store, i, u.tma.mem_commit_is_store);
      W.set(F_idu_consume_fire, i, consume.fire[i]);
    }
    W.set(F_ren2dec_ready, 0, ren2dec.ready); W.set(F_rob_bcast_flush, 0, rob_bcast.flush);
    W.set(F_exu2id_mispred, 0, exu2id.mispred); W.set(F_exu2id_redirect_pc, 0, exu2id.redirect_pc);
    W.set(F_exu2id_redirect_rob_idx, 0, exu2id.redirect_rob_idx); W.set(F_exu2id_br_id, 0, exu2id.br_id);
    W.set(F_exu2id_ftq_idx, 0, exu2id.ftq_idx); W.set(F_exu2id_clear_mask, 0, exu2id.clear_mask);
    W.set(F_dec_bcast_mispred, 0, dec_bcast.mispred); W.set(F_dec_bcast_br_mask, 0, dec_bcast.br_mask);
    W.set(F_dec_bcast_br_id, 0, dec_bcast.br_id); W.set(F_dec_bcast_redirect_rob_idx, 0, dec_bcast.redirect_rob_idx);
    W.set(F_dec_bcast_clear_mask, 0, dec_bcast.clear_mask);
    W.set(F_br_latch_mispred, 0, idu.br_latch.mispred); W.set(F_br_latch_redirect_pc, 0, idu.br_latch.redirect_pc);
    W.set(F_br_latch_redirect_rob_idx, 0, idu.br_latch.redirect_rob_idx); W.set(F_br_latch_br_id, 0, idu.br_latch.br_id);
    W.set(F_br_latch_ftq_idx, 0, idu.br_latch.ftq_idx); W.set(F_br_latch_clear_mask, 0, idu.br_latch.clear_mask);
    W.commit(cyc + 3);
    idu.seq();
  }
  tw.flush();
  return 0;
}
