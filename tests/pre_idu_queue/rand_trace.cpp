// Random-stimulus trace generator for pre_idu_queue: drives the *reference* PreIduQueue class (back-end/PreIduQueue.cpp)
// with constrained-random inputs and records a trace in the same format/spec as scripts/record.sh.
// Purpose: reach what the real programs never produce: non-zero sc/loop/page-fault metadata, full IBuffer / FTQ, FTQ tail
// wrap-around, sparse fetch groups, flush right after accepting a group, mispredict recovery of several FTQ entries, ...
//
// Legality model (the assertions of the reference model, built without NDEBUG, check it):
//  * instructions flow  front group -> InstructionBuffer -> (Idu consumes a prefix) -> "rob" queue -> commit in order;
//  * a commit slot carries the (ftq_idx, ftq_offset, ftq_is_last) the instruction was fetched with, so the commit
//    cursor of PreIduQueue::comb_commit_info (Assert ftq_idx == cursor) holds;
//  * mispredict (Idu br_latch) names an in-flight instruction k: younger instructions leave the "rob", k becomes
//    ftq_is_last (Rob::comb_branch), the InstructionBuffer is dropped; Rob commits nothing in a mispredict cycle
//    (Rob::comb_commit: !dec_bcast.mispred) and Idu fires nothing (Idu::comb_fire returns early);
//  * flush (Rob) happens together with the single commit of the head instruction; Idu fires nothing;
//  * mispredict and flush are never in the same cycle (Rob commit is blocked in a mispredict cycle).
// Front groups are independent random every cycle (the reference model does not look at the instruction stream).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <random>
#include <string>
#include "PreIduQueue.h"
#include "pre_idu_queue_fields.h"
using namespace ttg_io;

long long sim_time = 0;  // referenced by the reference model Assert
static ttg::TraceWriter<decltype(kFields)> *tw;
static std::map<std::string, int> ids;
static void S(const char *n, int e, uint64_t v) { tw->set(ids.at(n), e, v); }

struct Inst { int idx, off; bool last; };

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "rand.trc";
  uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
  int ncyc = argc > 3 ? atoi(argv[3]) : 50000;
  int p_front = argc > 4 ? atoi(argv[4]) : 60;     // % cycles with a fetch group
  int p_cons = argc > 5 ? atoi(argv[5]) : 60;      // % cycles Idu consumes
  int p_commit = argc > 6 ? atoi(argv[6]) : 60;    // % cycles Rob commits
  int p_mis = argc > 7 ? atoi(argv[7]) : 3;        // % cycles mispredict
  int p_flush = argc > 8 ? atoi(argv[8]) : 1;      // % cycles flush
  int p_sparse = argc > 9 ? atoi(argv[9]) : 20;    // % groups with a sparse lane mask
  for (int i = 0; i < (int)kNumFields; i++) ids[kFields[i].name] = i;
  static ttg::TraceWriter<decltype(kFields)> w(out, kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  tw = &w;
  std::mt19937_64 rng(seed);
  auto R = [&](int n) { return (int)(rng() % n); };
  auto P = [&](int pct) { return R(100) < pct; };

  FrontPreIO front; IduConsumeIO cons; RobBroadcastIO bc; RobCommitIO commit; ExuIdIO br;
  FtqPrfPcReqIO preq; FtqRobPcReqIO rreq;
  PreFrontIO p2f; PreIssueIO iss; FtqPrfPcRespIO presp; FtqRobPcRespIO rresp; FtqCommitInfoIO cinfo;
  PreIduQueue pre(nullptr);
  pre.in = {&front, &cons, &bc, &commit, &br, &preq, &rreq};
  pre.out = {&p2f, &iss, &presp, &rresp, &cinfo};
  pre.init();
  for (int k = 0; k < 3; k++) w.commit(0, ttg::kFlagReset);

  int tail_m = 0; bool prev_flush = false;
  std::deque<Inst> ib, rob;   // shadow of the InstructionBuffer and of the in-flight (consumed, uncommitted) insts
  for (int c = 0; c < ncyc; c++) {
    bool mis = !rob.empty() && P(p_mis);
    bool flush = !mis && !rob.empty() && P(p_flush);
    br = {};
    if (mis) {
      int k = R((int)rob.size());
      br.mispred = true; br.ftq_idx = rob[k].idx; br.br_id = R(64); br.redirect_pc = rng(); br.redirect_rob_idx = R(128);
      br.clear_mask = rng();
      rob.resize(k + 1); rob[k].last = true;   // younger insts leave, the mispredicted one closes its FTQ block
    } else if (P(20)) { br.clear_mask = rng(); br.ftq_idx = R(FTQ_SIZE); br.br_id = R(64); }   // not a mispredict
    // rob_bcast.flush is written by Rob::comb_commit, i.e. AFTER PreIduQueue::comb_accept_front: accept_front still
    // sees the value of the previous cycle (a hold), comb_fire and the recorded value see this cycle's.
    bc = {}; bc.flush = prev_flush;
    commit = {};
    int ncommit = 0;
    if (flush) ncommit = 1;
    else if (!mis && P(p_commit)) ncommit = 1 + R(COMMIT_WIDTH);
    if (ncommit > (int)rob.size()) ncommit = (int)rob.size();
    for (int i = 0; i < ncommit; i++) {
      commit.commit_entry[i].valid = true;
      commit.commit_entry[i].uop.ftq_idx = rob[i].idx; commit.commit_entry[i].uop.ftq_offset = rob[i].off;
      commit.commit_entry[i].uop.ftq_is_last = rob[i].last;
    }
    for (int i = ncommit; i < COMMIT_WIDTH; i++) {   // stale payload in invalid slots: not looked at
      commit.commit_entry[i].uop.ftq_idx = R(FTQ_SIZE); commit.commit_entry[i].uop.ftq_offset = R(16);
      commit.commit_entry[i].uop.ftq_is_last = R(2);
    }
    // front group
    front = {};
    if (P(p_front)) {
      uint32_t mask;
      if (P(p_sparse)) mask = rng() & 0xffff; else { int n = 1 + R(BACKEND_FETCH_WIDTH); mask = n >= 16 ? 0xffff : (1u << n) - 1; }
      if (P(15)) mask = 0xffff;
      front.predict_next_fetch_address[0] = rng();
      for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) {
        front.valid[i] = (mask >> i) & 1; front.inst[i] = rng(); front.pc[i] = rng();
        front.page_fault_inst[i] = P(10); front.predict_dir[i] = R(2);
        front.alt_pred[i] = R(2); front.altpcpn[i] = R(8); front.pcpn[i] = R(8); front.sc_used[i] = R(2);
        front.sc_pred[i] = R(2); front.sc_sum[i] = rng() & 0xffff; front.loop_used[i] = R(2); front.loop_hit[i] = R(2);
        front.loop_pred[i] = R(2); front.loop_idx[i] = rng() & 0xffff; front.loop_tag[i] = rng() & 0xffff;
        for (int t = 0; t < BPU_SCL_META_NTABLE; t++) front.sc_idx[i][t] = rng() & 0xffff;
        for (int j = 0; j < 4; j++) { front.tage_idx[i][j] = rng() & 0x3ff; front.tage_tag[i][j] = rng() & 0xff; }
      }
    }
    // FTQ read ports: mostly in-range random, includes entries that were never written / already freed
    preq = {}; rreq = {};
    for (int k = 0; k < FTQ_PRF_PC_PORT_NUM; k++) {
      preq.req[k].valid = P(50); preq.req[k].ftq_idx = R(FTQ_SIZE); preq.req[k].ftq_offset = R(16);
    }
    rreq.req[0].valid = P(60); rreq.req[0].ftq_idx = R(FTQ_SIZE); rreq.req[0].ftq_offset = R(16);

    pre.comb_begin();
    // Idu consumes a prefix of the issue group (nothing in a flush / mispredict cycle)
    cons = {};
    int nvis = ib.size() < (size_t)DECODE_WIDTH ? (int)ib.size() : DECODE_WIDTH;
    int ncons = (!flush && !mis && P(p_cons)) ? R(nvis + 1) : 0;
    for (int i = 0; i < ncons; i++) cons.fire[i] = true;
    pre.comb_accept_front();
    bc.flush = flush; prev_flush = flush;
    pre.comb_ftq_lookup_rob();
    pre.comb_commit_info();
    pre.comb_ftq_lookup_prf();
    pre.comb_fire();
    // ---- record (same field order as spec) ----
    for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) {
#define FI(f) S("front2pre_" #f, i, front.f[i])
      FI(valid); FI(inst); FI(pc); FI(page_fault_inst); FI(predict_dir); FI(alt_pred); FI(altpcpn); FI(pcpn);
      for (int j = 0; j < 4; j++) { S("front2pre_tage_idx", i * 4 + j, front.tage_idx[i][j]); S("front2pre_tage_tag", i * 4 + j, front.tage_tag[i][j]); }
      S("pre2front_fire", i, p2f.fire[i]);
    }
    S("front2pre_predict_next_fetch_address", 0, front.predict_next_fetch_address[0]);
    for (int i = 0; i < DECODE_WIDTH; i++) S("idu_consume_fire", i, cons.fire[i]);
    S("idu_br_latch_mispred", 0, br.mispred); S("idu_br_latch_ftq_idx", 0, br.ftq_idx);
    S("rob_bcast_flush", 0, bc.flush);
    for (int i = 0; i < COMMIT_WIDTH; i++) {
      auto &e = commit.commit_entry[i];
      S("rob_commit_commit_entry_valid", i, e.valid); S("rob_commit_commit_entry_uop_ftq_idx", i, e.uop.ftq_idx);
      S("rob_commit_commit_entry_uop_ftq_offset", i, e.uop.ftq_offset);
      S("rob_commit_commit_entry_uop_ftq_is_last", i, e.uop.ftq_is_last);
      auto &r = cinfo.resp[i];
      S("ftq_commit_info_resp_valid", i, e.valid);
#define CI(f) S("ftq_commit_info_resp_" #f, i, r.f)
      CI(pc); CI(pred_taken); CI(alt_pred); CI(altpcpn); CI(pcpn);
      for (int j = 0; j < 4; j++) {
        S("ftq_commit_info_resp_valid_t", i * 4 + j, e.valid);
        S("ftq_commit_info_resp_tage_idx", i * 4 + j, r.tage_idx[j]); S("ftq_commit_info_resp_tage_tag", i * 4 + j, r.tage_tag[j]);
      }
    }
    for (int k = 0; k < FTQ_PRF_PC_PORT_NUM; k++) {
      auto &r = presp.resp[k];
      S("ftq_prf_pc_req_req_valid", k, preq.req[k].valid); S("ftq_prf_pc_req_req_ftq_idx", k, preq.req[k].ftq_idx);
      S("ftq_prf_pc_req_req_ftq_offset", k, preq.req[k].ftq_offset);
      S("ftq_prf_pc_resp_resp_valid", k, r.valid); S("ftq_prf_pc_resp_resp_pc", k, r.pc);
      S("ftq_prf_pc_resp_resp_pred_taken", k, r.pred_taken); S("ftq_prf_pc_resp_resp_next_pc", k, r.next_pc);
    }
    S("ftq_rob_pc_req_req_valid", 0, rreq.req[0].valid); S("ftq_rob_pc_req_req_ftq_idx", 0, rreq.req[0].ftq_idx);
    S("ftq_rob_pc_req_req_ftq_offset", 0, rreq.req[0].ftq_offset);
    S("ftq_rob_pc_resp_resp_valid", 0, rresp.resp[0].valid); S("ftq_rob_pc_resp_resp_pc", 0, rresp.resp[0].pc);
    S("pre2front_ready", 0, p2f.ready);
    for (int i = 0; i < DECODE_WIDTH; i++) {
      auto &e = iss.entries[i];
      S("pre_issue_entries_valid", i, e.valid); S("pre_issue_entries_inst", i, e.inst);
      S("pre_issue_entries_page_fault_inst", i, e.page_fault_inst); S("pre_issue_entries_ftq_idx", i, e.ftq_idx);
      S("pre_issue_entries_ftq_offset", i, e.ftq_offset); S("pre_issue_entries_ftq_is_last", i, e.ftq_is_last);
    }
    w.commit(c + 1, 0);
    // ---- advance the shadow state (what the reference model just did) ----
    for (int i = 0; i < ncons; i++) {   // self-check of the shadow InstructionBuffer against the model's issue group
      if ((int)iss.entries[i].ftq_idx != ib[i].idx || (int)iss.entries[i].ftq_offset != ib[i].off ||
          (bool)iss.entries[i].ftq_is_last != ib[i].last) { fprintf(stderr, "shadow mismatch cycle %d\n", c); return 1; }
    }
    for (int i = 0; i < ncommit; i++) rob.pop_front();
    if (flush) {
      ib.clear(); rob.clear(); tail_m = 0;
    } else if (mis) {
      ib.clear(); tail_m = (br.ftq_idx + 1) % FTQ_SIZE;
    } else {
      for (int i = 0; i < ncons; i++) rob.push_back(ib[i]);
      ib.erase(ib.begin(), ib.begin() + ncons);
      int last = -1, n = 0;
      for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) if (p2f.fire[i]) last = i;
      for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) if (p2f.fire[i]) { ib.push_back({tail_m, i, i == last}); n++; }
      if (n > 0) tail_m = (tail_m + 1) % FTQ_SIZE;
    }
    pre.seq();
  }
  w.flush();
  return 0;
}
