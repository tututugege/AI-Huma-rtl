// memcpu coverage plugin (TTG_REC mid-cycle hook): counts events of the CPU-phase memory blocks from the memcpu tap
// (TTG_MC.pub = previous cycle's record). Env MCOV_N = max cycles. Output lines "MCOV <key> <count>".
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>
#define private public
#define protected public
#include "SimCpu.h"
#undef private
#undef protected
static std::map<std::string, uint64_t> C;
static uint64_t cnt = 0, N = ~0ull;
static void fin() {
  for (auto &kv : C) std::printf("MCOV %s %llu\n", kv.first.c_str(), (unsigned long long)kv.second);
  std::printf("MCOV cycles %llu\n", (unsigned long long)cnt);
}
static void ev(const std::string &k) { C[k]++; }
static void mx(const std::string &k, uint64_t v) { if (C[k] < v) C[k] = v; }
extern "C" void ttg_rec_cycle(SimCpu *c, uint64_t cycle) {
  static bool init = false;
  static MemPtwBlock::State ps{};         // PTW state at the start of the cycle that pub describes
  static bool have_ps = false;
  if (!init) { init = true; if (const char *e = std::getenv("MCOV_N")) N = std::strtoull(e, 0, 0); std::atexit(fin); }
  auto &P = g_ttg_mc.pub;
  ++cnt;
  if (have_ps && cnt > 1) {
    // ---------------- route ----------------
    if (P.r_dtlb_req.valid) ev("route_dtlb_req_valid");
    if (P.r_itlb_req.valid) ev("route_itlb_req_valid");
    if (P.r_icache_req.req_valid) ev("route_icache_req");
    if (P.r_walk_req.valid) ev("route_walk_req");
    if (P.r_icache_req.req_valid && P.r_walk_req.valid) ev("route_icache_and_walk_req");
    if (P.r_grant.valid) ev(std::string("route_grant_owner") + std::to_string((int)P.r_grant.owner));
    if (P.r_dcache_req.icache_req == LSU_LDU_COUNT - 1) ev("route_icache_granted");
    if (P.r_dcache_req.icache_req != LSU_LDU_COUNT - 1 && P.r_dcache_req.icache_req != LSU_LDU_COUNT) ev("ERR_icache_req_other");
    bool granted = P.r_grant.valid || P.r_dcache_req.icache_req == LSU_LDU_COUNT - 1;
    if (granted && P.r_lsu_req.load_ports[LSU_LDU_COUNT - 1].valid) ev("route_grant_steals_lsu_port3");
    if (P.r_lsu_req.load_ports[LSU_LDU_COUNT - 1].valid && !granted) ev("lsu_port3_passthrough");
    if (P.r_events.valid) {
      ev(std::string("route_event_owner") + std::to_string((int)P.r_events.owner));
      if (P.r_events.replay) ev("route_event_replay_nonzero");
    }
    if (P.r_wakeup.dtlb) ev("route_wakeup_dtlb");
    if (P.r_wakeup.itlb) ev("route_wakeup_itlb");
    if (P.r_wakeup.walk) ev("route_wakeup_walk");
    if (P.r_icache_resp.resp_valid) {
      ev("route_icresp_valid");
      if (P.r_icache_resp.resp_retry) ev("route_icresp_retry");
      else if (P.r_icache_resp.resp_miss) ev("route_icresp_miss");
      else ev("route_icresp_hit");
    }
    if (P.r_resp_in.mshr_fill) ev("route_mshr_fill");
    const auto &r3 = P.r_resp_in.resp_ports.load_resps[LSU_LDU_COUNT - 1];
    if (r3.valid && (r3.req_id >> 31)) {
      ev(std::string("route_resp3_routeid_replay") + std::to_string((int)r3.replay));
      if (r3.retry) ev("route_resp3_routeid_retry");
    }
    for (int i = 0; i < LSU_LDU_COUNT; i++) {
      const auto &r = P.r_resp_in.resp_ports.load_resps[i];
      if (r.valid && (r.req_id >> 31) && i != LSU_LDU_COUNT - 1) ev("ERR_routeid_resp_on_port_not3");
      if (r.valid && !(r.req_id >> 31) && i == LSU_LDU_COUNT - 1) ev("route_resp3_lsu_id");
      if (r.valid && !(r.req_id >> 31) && i == LSU_LDU_COUNT - 1 && P.r_lsu_resp.resp_ports.load_resps[i].valid != 1) ev("route_resp3_lsu_id_valid_changed");
    }
    // ---------------- ptw ----------------
    for (int i = 0; i < 2; i++) {
      if (P.p_in.mem_clients[i].req_valid) ev("ptw_memclient_req_valid");
      if (P.p_in.mem_clients[i].resp_consumed) ev("ptw_memclient_resp_consumed");
      if (P.p_in.walk_clients[i].req_valid) ev(std::string("ptw_walk_req_c") + std::to_string(i));
      if (P.p_in.walk_clients[i].resp_consumed) ev(std::string("ptw_walk_resp_consumed_c") + std::to_string(i));
      if (P.p_flush[i]) {
        ev(std::string("ptw_flush_c") + std::to_string(i));
        if (ps.walk_active && (int)ps.walk_owner == i) ev(std::string("ptw_flush_owner_state") + std::to_string((int)ps.walk_state));
      }
      if (P.p_view.walk_clients[i].resp_valid) {
        ev("ptw_resp_valid");
        if (P.p_view.walk_clients[i].resp.fault) ev("ptw_resp_fault");
        else ev(std::string("ptw_resp_leaf_level") + std::to_string((int)P.p_view.walk_clients[i].resp.leaf_level));
      }
      if (P.p_in.walk_clients[i].req_valid && !P.p_view.walk_clients[i].req_ready) ev("ptw_req_while_not_ready");
      if (P.p_in.walk_clients[i].req_valid && P.p_view.walk_clients[i].resp_valid) ev("ptw_req_while_resp_valid");
    }
    if (P.p_in.walk_clients[0].req_valid && P.p_in.walk_clients[1].req_valid) ev("ptw_both_req");
    if (P.p_fb.grant_valid) ev(std::string("ptw_fb_grant_owner") + std::to_string((int)P.p_fb.grant_owner));
    if (P.p_fb.event_count) {
      const auto &e = P.p_fb.events[0];
      ev(std::string("ptw_fb_event_owner") + std::to_string((int)e.owner));
      if (e.replay) ev("ptw_fb_event_replay_nonzero");
      if (e.owner == MemPtwBlock::RoutedEventOwner::WALK) {
        bool active_req = ps.walk_active && ps.walk_req_id_valid && ps.walk_req_id == e.req_id;
        // state AFTER grant of this cycle matters for the id compare; approximate with before/after variants
        bool grant_same_cycle = P.p_fb.grant_valid && P.p_fb.grant_owner == MemPtwBlock::GrantOwner::WALK;
        if (ps.walk_drop_resp_credit > 0 && !active_req && !grant_same_cycle) ev("ptw_event_dropped_by_credit_nogrant");
        if (grant_same_cycle) ev("ptw_event_with_same_cycle_grant");
        if (!ps.walk_active) ev("ptw_event_walk_inactive");
        if (ps.walk_active && !ps.walk_req_id_valid) ev("ptw_event_walk_noid");
        if (ps.walk_active && ps.walk_req_id_valid && !active_req) ev("ptw_event_id_mismatch");
        if (active_req) {
          uint32_t pte = e.data;
          bool v = pte & 1, r = pte & 2, w = pte & 4, x = pte & 8;
          if (ps.walk_state == MemPtwBlock::WalkState::L1_WAIT_RESP) {
            if (!v) ev("ptw_L1_invalid"); else if (!r && w) ev("ptw_L1_rw_reserved");
            else if (r || x) { if ((pte >> 10) & 0x3ff) ev("ptw_L1_misaligned_super"); else ev("ptw_L1_leaf"); }
            else ev("ptw_L1_pointer");
          } else if (ps.walk_state == MemPtwBlock::WalkState::L2_WAIT_RESP) {
            if (!v) ev("ptw_L2_invalid"); else if (!r && w) ev("ptw_L2_rw_reserved");
            else if (!(r || x)) ev("ptw_L2_nonleaf"); else ev("ptw_L2_leaf");
          } else ev("ptw_event_active_but_state_not_wait");
        }
      }
    }
    if (P.p_fb.wakeup_dtlb) ev("ptw_wakeup_dtlb");
    if (P.p_fb.wakeup_itlb) ev("ptw_wakeup_itlb");
    if (P.p_fb.wakeup_walk) {
      ev("ptw_wakeup_walk");
      if (ps.walk_active) ev(std::string("ptw_wakeup_walk_state") + std::to_string((int)ps.walk_state));
      else ev("ptw_wakeup_walk_inactive");
    }
    ev(std::string("ptw_state") + std::to_string((int)ps.walk_state));
    mx("ptw_max_drop_credit", ps.walk_drop_resp_credit);
    if (ps.walk_drop_resp_credit) ev("ptw_credit_nonzero_cycles");
    if (P.p_issue) ev("ptw_issue_walk_read");
    // ---------------- peripheral ----------------
    const auto &q = P.q_req;
    if (q.is_mmio) {
      std::string k = std::string("per_req_") + (q.wen ? "w" : "r") + (P.q_is_uncached ? "_uncached" : P.q_is_modeled ? "_modeled" : "_axi");
      ev(k);
      ev(std::string("per_req_f3_") + std::to_string((int)q.mmio_fun3) + (q.wen ? "w" : "r"));
      bool ready = !P.q_cur.busy && !P.q_cur.resp_valid;
      if (!ready) ev("per_req_not_ready_ignored");
      if (!ready && P.q_cur.resp_valid) ev("per_req_during_resp_valid");
      if (!ready && P.q_cur.busy) ev("per_req_during_busy");
      if (ready && P.q_cur.busy) ev("ERR_ready_with_busy");
    }
    if (P.q_cur.busy) {
      ev(std::string("per_busy_") + (P.q_cur.write ? "w" : "r") + (P.q_cur.req_accepted ? "_accepted" : "_pending"));
      if (P.q_cur.write && P.q_in.write.req_accepted && !P.q_cur.req_accepted) ev("per_write_accept");
      if (!P.q_cur.write && P.q_in.read.req_accepted && !P.q_cur.req_accepted) ev("per_read_accept");
      if (P.q_cur.write && P.q_in.write.resp_valid && P.q_cur.req_accepted) ev("per_write_resp");
      if (!P.q_cur.write && P.q_in.read.resp_valid && P.q_cur.req_accepted) ev("per_read_resp");
      if (P.q_cur.write && P.q_in.write.resp_valid && !P.q_cur.req_accepted) ev("per_write_resp_before_accept");
      if (!P.q_cur.write && P.q_in.read.resp_valid && !P.q_cur.req_accepted) ev("per_read_resp_before_accept");
      if (P.q_cur.write && P.q_in.write.req_accepted && P.q_cur.req_accepted) ev("per_write_accept_again");
      if (P.q_cur.write && P.q_in.write.req_accepted && P.q_in.write.resp_valid && !P.q_cur.req_accepted) ev("per_write_accept_and_resp_same_cycle");
    }
    if (P.q_cur.resp_valid) { ev("per_resp_valid_cycle"); if (P.q_cur.write) ev("per_resp_valid_write"); }
    if (P.q_out.read.req_valid) ev(std::string("per_axi_rd_size") + std::to_string((int)P.q_out.read.req_total_size));
    if (P.q_out.write.req_valid) ev(std::string("per_axi_wr_size") + std::to_string((int)P.q_out.write.req_total_size));
    if (P.q_out.read.req_id || P.q_out.write.req_id) ev("ERR_per_req_id_nonzero");
    if (P.q_resp.ready != (!P.q_cur.busy && !P.q_cur.resp_valid)) ev("ERR_per_resp_ready_formula");
    // ---------------- axi cpu adapter ----------------
    const char *cn[3] = {"rdIC", "rdEX", "wrEX"};
    for (int k = 0; k < 3; k++) {
      std::string n = cn[k];
      bool acc_any = false, acc_t0 = P.ax[0].ch[k].accepted, acc_late = false, rdy_any = false, rdy_t0 = P.ax[0].ch[k].ready;
      int first_acc = -1, nacc = 0; bool id_change = false;
      uint8_t last_id = P.ax[0].ch[k].accepted_id;
      for (int t = 0; t < 16; t++) {
        const auto &a = P.ax[t].ch[k];
        if (a.ready) rdy_any = true;
        if (a.accepted) { acc_any = true; nacc++; if (first_acc < 0) first_acc = t; if (t > 0) acc_late = true; if (a.accepted_id != last_id && t > 0) id_change = true; last_id = a.accepted_id; }
      }
      if (acc_any) ev(n + "_accepted_cycle");
      if (acc_t0) ev(n + "_accepted_t0");
      if (acc_late && !acc_t0) ev(n + "_accepted_only_late");
      if (acc_late && acc_t0) ev(n + "_accepted_t0_and_late");
      if (nacc > 1) ev(n + "_accepted_multi_ticks");
      if (id_change) ev(n + "_accepted_id_changes");
      if (rdy_any) ev(n + "_ready_any");
      if (rdy_any && !rdy_t0) ev(n + "_ready_late_only");
      if (!rdy_any) ev(n + "_ready_never");
      bool rdy_all = true; for (int t = 0; t < 16; t++) rdy_all = rdy_all && P.ax[t].ch[k].ready;
      if (rdy_any && !rdy_all) ev(n + "_ready_mixed");
      const auto &a0 = P.ax[0].ch[k], &a15 = P.ax[15].ch[k]; const auto &v = P.view.ch[k];
      if (a0.resp_valid) ev(n + "_resp_t0");
      if (a15.resp_valid) ev(n + "_resp_t15");
      if (a15.resp_valid && !(a0.resp_valid && a0.resp_id == a15.resp_id)) ev(n + "_resp_new_in_extra_ticks");
      if (a15.resp_valid && !v.resp_valid) ev(n + "_resp_suppressed");
      if (a15.resp_valid && v.resp_valid) ev(n + "_resp_passed");
      if (a0.resp_ready) ev(n + "_resp_ready_t0");
      if (a0.resp_ready && !v.resp_ready) ev(n + "_resp_ready_cleared");
      if (!a0.resp_ready && v.resp_ready) ev(n + "ERR_resp_ready_set");
      bool suppress_match = acc_any && a15.resp_valid && a15.resp_id == last_id;
      if (suppress_match) ev(n + "_resp_matches_new_accept");
      if (a15.resp_valid && a0.resp_valid && a0.resp_id != a15.resp_id) ev(n + "_resp_id_changed_t0_t15");
      if (a0.resp_valid && !a15.resp_valid) ev(n + "_resp_t0_gone_t15");
      for (int t = 1; t < 16; t++) if (P.ax[t].ch[k].resp_valid && P.ax[t].ch[k].resp_id != a15.resp_id) { ev(n + "_resp_id_varies_ticks"); break; }
    }
  }
  // save the PTW state at the start of THIS cycle (read-only copy); P (pub) for the next call describes this cycle
  ps = c->mem_subsystem.ptw_block.cur_;
  have_ps = true;
  if (cnt >= N) { fin(); std::fflush(stdout); std::_Exit(0); }
}
