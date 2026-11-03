// Random-stimulus trace generator for the prf module: drives the *reference* Prf class (back-end/Prf.cpp)
// with constrained-random inputs and records a trace in the same format/spec as scripts/record.sh.
// Purpose: reach corner cases the real programs never produce (write conflicts, FU-vs-WB bypass priority,
// >4 load wake-ups, FTQ answer missing, ...). Build: see tests/prf/run_rand.sh.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <random>
#include <string>
#include "Prf.h"
#include "prf_fields.h"
using namespace ttg_io;

static ttg::TraceWriter<decltype(kFields)> *tw;
static std::map<std::string, int> ids;
static void S(const char *n, int e, uint64_t v) { tw->set(ids.at(n), e, v); }

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "rand.trc";
  uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
  int ncyc = argc > 3 ? atoi(argv[3]) : 100000;
  int pool = argc > 4 ? atoi(argv[4]) : 8;      // preg pool size (small = many collisions)
  int p_ld = argc > 5 ? atoi(argv[5]) : 40;     // % of exe ops that are loads
  for (int i = 0; i < (int)kNumFields; i++) ids[kFields[i].name] = i;
  static ttg::TraceWriter<decltype(kFields)> w(out, kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  tw = &w;
  std::mt19937_64 rng(seed);
  auto R = [&](int n) { return (int)(rng() % n); };
  auto P = [&](int pct) { return R(100) < pct; };
  auto preg = [&]() { return P(10) ? R(PRF_NUM) : R(pool); };
  auto brm = [&]() { uint64_t m = 0; int n = R(3); for (int i = 0; i < n; i++) m |= 1ull << R(8); return m; };

  SimContext ctx;
  Prf prf(&ctx);
  IssPrfIO iss; ExePrfIO exe; DecBroadcastIO dec; RobBroadcastIO rob; FtqPrfPcRespIO resp;
  PrfExeIO p2e; PrfAwakeIO awk; FtqPrfPcReqIO req;
  prf.in = {&iss, &exe, &dec, &rob, &resp};
  prf.out = {&p2e, &awk, &req};
  prf.init();
  for (int k = 0; k < 3; k++) w.commit(0, ttg::kFlagReset);

  for (int c = 0; c < ncyc; c++) {
    dec.mispred = P(12); dec.br_mask = dec.mispred ? (1ull << R(8)) : 0; dec.clear_mask = P(30) ? brm() : 0;
    rob.flush = P(3);
    for (int i = 0; i < ISSUE_WIDTH; i++) {
      auto &e = iss.iss_entry[i]; auto &u = e.uop;
      e.valid = P(60);
      u.dest_preg = preg(); u.src1_preg = preg(); u.src2_preg = preg();
      u.src1_en = P(80); u.src2_en = P(80); u.src1_is_pc = P(50); u.dest_en = P(80);
      u.ftq_idx = R(FTQ_SIZE); u.ftq_offset = R(16);
      u.op = (i >= IQ_BR_PORT_BASE || i < ALU_NUM) ? (P(15) ? R(MAX_UOP_TYPE) : (P(50) ? UOP_BR : UOP_ADD)) : R(MAX_UOP_TYPE);
      u.is_atomic = R(2); u.src2_is_imm = R(2); u.func3 = R(8); u.func7 = R(128); u.imm = rng();
      u.br_id = R(64); u.br_mask = brm(); u.csr_idx = R(4096); u.rob_idx = R(128); u.stq_idx = R(64);
      u.stq_flag = R(2); u.ldq_idx = R(64); u.rob_flag = R(2);
      auto &x = exe.entry[i];
      x.valid = P(60);
      x.uop.dest_preg = preg(); x.uop.result = rng(); x.uop.br_mask = brm(); x.uop.dest_en = P(85);
      x.uop.op = P(p_ld) ? UOP_LOAD : R(MAX_UOP_TYPE);
    }
    for (int k = 0; k < TOTAL_FU_COUNT; k++) {
      auto &b = exe.bypass[k];
      b.valid = P(40); b.uop.dest_preg = preg(); b.uop.result = rng(); b.uop.dest_en = P(80);
      b.uop.br_mask = brm(); b.uop.op = R(MAX_UOP_TYPE);
    }
    for (int k = 0; k < FTQ_PRF_PC_PORT_NUM; k++) {
      auto &r = resp.resp[k];
      r.valid = P(75); r.entry_valid = R(2); r.pc = rng(); r.pred_taken = R(2); r.next_pc = rng();
    }
    prf.comb_begin(); prf.comb_complete(); prf.comb_awake(); prf.comb_write();
    prf.comb_req_ftq(); prf.comb_read(); prf.comb_pipeline();
    // record (same field order as spec)
    S("dec_bcast_mispred", 0, dec.mispred); S("dec_bcast_br_mask", 0, dec.br_mask);
    S("dec_bcast_clear_mask", 0, dec.clear_mask); S("rob_bcast_flush", 0, rob.flush);
    for (int i = 0; i < ISSUE_WIDTH; i++) {
      auto &e = iss.iss_entry[i]; auto &u = e.uop; auto &o = p2e.iss_entry[i]; auto &ou = o.uop; auto &x = exe.entry[i];
      S("iss2prf_iss_entry_valid", i, e.valid);
#define IU(f) S("iss2prf_iss_entry_uop_" #f, i, u.f)
      IU(dest_preg); IU(src1_preg); IU(src2_preg); IU(ftq_idx); IU(ftq_offset); IU(is_atomic); IU(dest_en); IU(src1_en);
      IU(src2_en); IU(src1_is_pc); IU(src2_is_imm); IU(func3); IU(func7); IU(imm); IU(br_id); IU(br_mask); IU(csr_idx);
      IU(rob_idx); IU(stq_idx); IU(stq_flag); IU(ldq_idx); IU(rob_flag); IU(op);
      S("exe2prf_entry_valid", i, x.valid);
#define EU(f) S("exe2prf_entry_uop_" #f, i, x.uop.f)
      EU(dest_preg); EU(result); EU(br_mask); EU(dest_en); EU(op);
      S("prf2exe_iss_entry_valid", i, o.valid);
#define OU(f) S("prf2exe_iss_entry_uop_" #f, i, ou.f)
      OU(pc); OU(ftq_resp_valid); OU(ftq_pred_taken); OU(ftq_next_pc); OU(src1_rdata); OU(src2_rdata);
      OU(dest_preg); OU(src1_preg); OU(src2_preg); OU(ftq_idx); OU(ftq_offset); OU(is_atomic); OU(dest_en); OU(src1_en);
      OU(src2_en); OU(src1_is_pc); OU(src2_is_imm); OU(func3); OU(func7); OU(imm); OU(br_id); OU(br_mask); OU(csr_idx);
      OU(rob_idx); OU(stq_idx); OU(stq_flag); OU(ldq_idx); OU(rob_flag); OU(op);
    }
    for (int k = 0; k < TOTAL_FU_COUNT; k++) {
      auto &b = exe.bypass[k];
      S("exe2prf_bypass_valid", k, b.valid); S("exe2prf_bypass_uop_dest_preg", k, b.uop.dest_preg);
      S("exe2prf_bypass_uop_result", k, b.uop.result); S("exe2prf_bypass_uop_dest_en", k, b.uop.dest_en);
    }
    for (int k = 0; k < FTQ_PRF_PC_PORT_NUM; k++) {
      auto &r = resp.resp[k];
      S("ftq_prf_pc_resp_resp_valid", k, r.valid); S("ftq_prf_pc_resp_resp_pc", k, r.pc);
      S("ftq_prf_pc_resp_resp_pred_taken", k, r.pred_taken); S("ftq_prf_pc_resp_resp_next_pc", k, r.next_pc);
      S("ftq_prf_pc_req_req_valid", k, req.req[k].valid); S("ftq_prf_pc_req_req_ftq_idx", k, req.req[k].ftq_idx);
      S("ftq_prf_pc_req_req_ftq_offset", k, req.req[k].ftq_offset);
    }
    for (int k = 0; k < LSU_LOAD_WB_WIDTH; k++) {
      S("prf_awake_wake_valid", k, awk.wake[k].valid); S("prf_awake_wake_preg", k, awk.wake[k].preg);
    }
    w.commit(c + 1, 0);
    prf.seq();
  }
  w.flush();
  return 0;
}
