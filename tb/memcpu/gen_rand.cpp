// Constrained-random trace generators of the CPU-phase memory blocks (mem_route, ptw_walk, peripheral_axi, axi_cpu_port_adapter).
// They drive the REAL reference classes (MemRouteBlock.cpp, MemPtwBlock.h, PeripheralAxi.cpp) -- and for the adapter the verbatim
// capture/accumulate/restore_axi_cpu_boundary_state functions extracted from rv_simu_mmu_v2.cpp -- in the call order of
// MemSubsystem::comb_outputs / comb_inputs / seq, copy the values into the memcpu tap struct (g_ttg_mc.pub) exactly where the
// refsim hook does, and let the spec-generated recorder (<mod>_rec.cpp, expressions TTG_MC.pub.*) write the trace.
// Covers what the real programs never reach (docs/modules/*.md section 5): ptw stale events / wakeups / flush while waiting /
// superpages / all PTE faults, the peripheral AXI path (never used by the 68 programs), adapter id/ready/suppress corner cases.
//   usage: gen_rand <out.trc> <seed> <cycles> <profile 0..5>          (module selected by -DMOD_ROUTE|MOD_PTW|MOD_PERI|MOD_AXI)
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#define private public
#define protected public
#include "SimCpu.h"
#undef private
#undef protected
#include "memcpu_tap.h"

McTap g_ttg_mc;
long long sim_time = 0;
extern "C" void ttg_rec_cycle(SimCpu *cpu_p, uint64_t cycle);

static std::mt19937_64 rng;
static uint64_t rnd() { return rng(); }
static bool chance(int pm) { return int(rnd() % 1000) < pm; }  // per mille
static uint32_t r32() { return uint32_t(rnd()); }

static void record(uint64_t cyc) { ttg_rec_cycle(nullptr, cyc); }
// coverage counters, printed when GEN_COV is set:  COV("name") ++
#include <map>
#include <string>
static std::map<std::string, uint64_t> g_cov;
#define COV(name) (++g_cov[name])
static void dump_cov() { if (!std::getenv("GEN_COV")) return; std::fprintf(stderr, "GENCOV"); for (auto &kv : g_cov) std::fprintf(stderr, " %s=%llu", kv.first.c_str(), (unsigned long long)kv.second); std::fprintf(stderr, "\n"); }

#if defined(MOD_ROUTE)
#include "MemRouteBlock.h"
int main(int argc, char **argv) {
  if (argc < 5) { std::fprintf(stderr, "usage: gen_rand out.trc seed cycles profile\n"); return 2; }
  setenv("TTG_REC_OUT", argv[1], 1);
  rng.seed(std::strtoull(argv[2], 0, 0));
  const uint64_t cycles = std::strtoull(argv[3], 0, 0);
  const int prof = std::atoi(argv[4]);
  //                    0    1    2    3    4    5
  int p_ic[6]   =  {300, 700, 100, 900, 500, 200};   // ICache request
  int p_walk[6] =  {300, 100, 700, 600, 900, 200};   // walk request
  int p_ld3[6]  =  {500, 300, 800, 900, 100, 600};   // LSU load on the shared port
  int p_fill[6] =  {100, 400,  50, 200, 700, 300};   // mshr_fill
  int p_hit[6]  =  {400, 100, 300, 200, 100, 500};   // route response is a HIT (else CONFLICT / MSHR_HIT / MSHR_FULL)
  int p_lsu[6]  =  {400, 800, 300, 500, 600, 100};   // other LSU activity
  MemRouteBlock rb;
  DcacheLsuIO dresp, lsu_resp; DCacheReqPorts lsu_req; ICacheMemPortReq ic_req; ICacheMemPortResp ic_resp;
  PtwReq w, d, i; LsuDcacheIO dreq; PtwGrant grant; PtwEvent ev; ReplayWakeup wk;
  rb.in = {&dresp, &lsu_req, &ic_req, &w, &d, &i};
  rb.out = {&dreq, &lsu_resp, &ic_resp, &grant, &ev, &wk};
  rb.init();
  d = {}; i = {};
  for (uint64_t cyc = 1; cyc <= cycles; ++cyc) {
    McCycle &P = g_ttg_mc.pub;
    P = McCycle{};
    // ---- DCache response published this cycle ----
    dresp = {};
    const auto own = rb.cur.issued_tags;
    for (int p = 0; p < LSU_LDU_COUNT; ++p) {
      auto &r = dresp.resp_ports.load_resps[p];
      r.valid = chance(p_lsu[prof]); r.req_id = r32() & 0x7fffffffu; r.data = r32();
      r.replay = (ReplayType)(rnd() % 4); r.retry = chance(300); r.bank_conflict = chance(100);
    }
    {
      auto &r = dresp.resp_ports.load_resps[LSU_LDU_COUNT - 1];
      if (own.owner != Owner::NONE && !chance(30)) {
        r.valid = true; r.req_id = own.req_id;                      // the answer of last cycle's route request
        int x = int(rnd() % 1000);
        r.replay = x < p_hit[prof] ? ReplayType::HIT : x < 700 ? ReplayType::CONFLICT : x < 850 ? ReplayType::MSHR_HIT : ReplayType::MSHR_FULL;
      }
    }
    for (int s = 0; s < LSU_STA_COUNT; ++s) {
      auto &r = dresp.resp_ports.store_resps[s];
      r.valid = chance(p_lsu[prof]); r.req_id = r32() & 0x3f; r.replay = (ReplayType)(rnd() % 4); r.bank_conflict = chance(100);
    }
    dresp.mshr_fill = chance(p_fill[prof]); dresp.mshr_fill_addr = r32();
    rb.comb_response();
    P.r_resp_in = dresp; P.r_lsu_resp = lsu_resp; P.r_icache_resp = ic_resp; P.r_events = ev; P.r_wakeup = wk;
    // ---- requests ----
    lsu_req = {};
    for (int p = 0; p < LSU_LDU_COUNT; ++p) {
      auto &q = lsu_req.load_ports[p];
      q.valid = p == LSU_LDU_COUNT - 1 ? chance(p_ld3[prof]) : chance(p_lsu[prof]);
      q.addr = r32(); q.req_id = r32() & 0x7fffffffu;
    }
    for (int s = 0; s < LSU_STA_COUNT; ++s) {
      auto &q = lsu_req.store_ports[s];
      q.valid = chance(p_lsu[prof]); q.addr = r32(); q.data = r32(); q.strb = r32() & 0x1f; q.req_id = r32() & 0x3f;
    }
    ic_req = {}; ic_req.req_valid = chance(p_ic[prof]); ic_req.req_addr = r32();
    w = {}; w.valid = chance(p_walk[prof]); w.addr = r32();
    rb.comb_request();
    P.r_lsu_req = lsu_req; P.r_icache_req = ic_req; P.r_walk_req = w; P.r_dtlb_req = d; P.r_itlb_req = i;
    P.r_dcache_req = dreq; P.r_grant = grant;
    if (grant.valid) COV("grant_walk");
    if (dreq.icache_req == LSU_LDU_COUNT - 1) COV("grant_icache");
    if ((grant.valid || dreq.icache_req == LSU_LDU_COUNT - 1) && lsu_req.load_ports[LSU_LDU_COUNT - 1].valid) COV("lsu_p3_displaced");
    if (ev.valid) COV("event_hit_walk");
    if (ic_resp.resp_valid) { COV(ic_resp.resp_retry ? "ic_retry" : ic_resp.resp_miss ? "ic_miss" : "ic_hit"); }
    if (wk.walk) COV("wakeup_walk");
    if (own.owner == Owner::PTW_WALK && dresp.resp_ports.load_resps[LSU_LDU_COUNT - 1].valid && dresp.resp_ports.load_resps[LSU_LDU_COUNT - 1].req_id == own.req_id) { const int rp = (int)dresp.resp_ports.load_resps[LSU_LDU_COUNT - 1].replay; COV(std::string("walk_resp_replay") + std::to_string(rp) + (dresp.mshr_fill ? "_fill" : "")); }
    if (own.owner == Owner::ICACHE && dresp.resp_ports.load_resps[LSU_LDU_COUNT - 1].valid && dresp.resp_ports.load_resps[LSU_LDU_COUNT - 1].req_id == own.req_id) { const int rp = (int)dresp.resp_ports.load_resps[LSU_LDU_COUNT - 1].replay; COV(std::string("ic_resp_replay") + std::to_string(rp) + (dresp.mshr_fill ? "_fill" : "")); }
    if (rb.cur.ptw_wait.walk) COV("ptw_wait_cycles");
    if (cyc == cycles) dump_cov();
    record(cyc);
    rb.seq();
  }
  return 0;
}

#elif defined(MOD_PTW)
#include "MemPtwBlock.h"
// a PTE of the kind the walker meets: mostly valid, all R/W/X mixes, misaligned superpages
static uint32_t rand_pte(int level1) {
  uint32_t pte = r32() & 0xffffff00u;
  int k = int(rnd() % 100);
  uint32_t perm;
  if (k < 8) perm = 0;                                        // invalid
  else if (k < 14) perm = 1 | 4;                              // V, W without R: reserved
  else if (k < 20) perm = 1 | 4 | 8 | 2;                      // V R W X
  else if (level1 && k < 60) perm = 1;                        // V only: pointer
  else perm = 1 | ((rnd() & 1) ? 2 : 0) | ((rnd() & 1) ? 8 : 0) | ((rnd() & 1) ? 4 : 0);
  if (level1 && (perm & 10) && chance(700)) pte &= ~0x000ffc00u;   // aligned superpage most of the time
  return (pte & ~0xffu) | perm | (r32() & 0xf0u);
}
int main(int argc, char **argv) {
  if (argc < 5) { std::fprintf(stderr, "usage: gen_rand out.trc seed cycles profile\n"); return 2; }
  setenv("TTG_REC_OUT", argv[1], 1);
  rng.seed(std::strtoull(argv[2], 0, 0));
  const uint64_t cycles = std::strtoull(argv[3], 0, 0);
  const int prof = std::atoi(argv[4]);
  //                    0    1    2    3    4    5
  int p_req[6]    =  {300, 800, 100, 500, 900, 400};   // a client with a free port sends a request
  int p_cons[6]   =  {600, 900, 200, 500, 800, 300};   // response consumed
  int p_flush[6]  =  { 30,  80,  10, 200,   5, 400};   // client flush
  int p_grant[6]  =  {800, 900, 500, 700, 950, 300};   // route grants a pending walk read
  int p_event[6]  =  {800, 900, 700, 600, 950, 500};   // granted read answers with a PTE next cycle (HIT)
  int p_wake[6]   =  {100,  50, 300, 150,  10, 200};   // wakeup (conflict / fill) instead of an answer, or spurious
  int p_stale[6]  =  { 50, 100, 200, 300,  20, 400};   // the answer comes with an old id
  MemPtwBlock blk(nullptr);
  uint32_t next_id = 0x80000000u;
  bool pend = false; uint32_t pend_id = 0;
  bool pend_conflict = false;
  for (uint64_t cyc = 1; cyc <= cycles; ++cyc) {
    McCycle &P = g_ttg_mc.pub;
    P = McCycle{};
    const auto view = blk.comb_outputs();
    P.p_view = view;
    // ---- two TLB-like clients (PtwWalkPortAdapter behaviour) ----
    MemPtwBlock::PortIn in{};
    bool flush[2] = {false, false};
    for (int c = 0; c < 2; ++c) {
      bool ready = view.walk_clients[c].req_ready, rvalid = view.walk_clients[c].resp_valid;
      if (rvalid && chance(p_cons[prof])) { in.walk_clients[c].resp_consumed = true; rvalid = false; }
      if (chance(p_flush[prof])) { flush[c] = true; ready = true; }
      if (ready && chance(p_req[prof])) {
        in.walk_clients[c].req_valid = true;
        in.walk_clients[c].req.vaddr = (r32() & 0xfffff) << 12 | (r32() & 0xfff);
        in.walk_clients[c].req.satp = (r32() & 0x3fffff) | (chance(500) ? 0x80000000u : 0);
      }
    }
    blk.comb_begin(in);
    P.p_in = in;
    const auto &o = blk.comb_outputs();
    P.p_issue = o.issue_walk_read; P.p_addr = o.walk_read_addr;
    // ---- route feedback: grant of this cycle's read, the answer of last cycle's read, wakeups ----
    MemPtwBlock::FeedbackIn fb{};
    if (pend && !pend_conflict) {
      MemPtwBlock::RoutedEvent e{}; e.valid = true; e.owner = MemPtwBlock::RoutedEventOwner::WALK;
      e.data = rand_pte(blk.cur_.walk_state == MemPtwBlock::WalkState::L1_WAIT_RESP);
      e.req_id = chance(p_stale[prof]) ? pend_id + (chance(500) ? 1 : 0xffffffffu) : pend_id;   // ids of neighbouring requests (never 16 apart: one route request in flight)
      if (chance(p_event[prof])) { fb.events[0] = e; fb.event_count = 1; }
      else fb.wakeup_walk = true;                 // no answer: conflict, the walk re-issues
    }
    if (chance(p_wake[prof])) fb.wakeup_walk = true;
    pend = false; pend_conflict = false;
    if (o.issue_walk_read && chance(p_grant[prof])) {
      fb.grant_valid = true; fb.grant_owner = MemPtwBlock::GrantOwner::WALK; fb.grant_req_id = next_id;
      pend = true; pend_id = next_id;
      next_id += 1;
    } else if (chance(200)) next_id += 1;         // ICache requests also consume route ids
    const auto before = blk.nxt_;
    blk.comb_finish(fb);
    {   // coverage counters (stderr summary at exit)
      const auto &a = blk.nxt_;
      static uint64_t n[16] = {};
      static bool reg = false;
      if (!reg) { reg = true; std::atexit([] {}); }
      using WS = MemPtwBlock::WalkState;
      const bool wait = before.walk_state == WS::L1_WAIT_RESP || before.walk_state == WS::L2_WAIT_RESP;
      if (fb.grant_valid) n[0]++;
      if (fb.event_count) { n[1]++;
        const bool act = (before.walk_state == WS::L1_WAIT_RESP || before.walk_state == WS::L2_WAIT_RESP || fb.grant_valid) && a.walk_req_id_valid + 0 >= 0;
        (void)act; if (!wait) n[2]++; else if (before.walk_req_id != fb.events[0].req_id) n[3]++; }
      if (before.walk_state == WS::L1_WAIT_RESP && wait && a.walk_state == WS::L2_REQ) n[4]++;
      for (int c = 0; c < 2; ++c) if (!before.walk_clients[c].resp_valid || true) {
        if (a.walk_clients[c].resp_valid && !before.walk_clients[c].resp_valid && before.walk_clients[c].req_inflight && !a.walk_clients[c].req_inflight) {
          if (a.walk_clients[c].resp.fault) n[5]++; else if (a.walk_clients[c].resp.leaf_level) n[6]++; else n[7]++; }
      }
      if (fb.wakeup_walk && wait) n[8]++;
      if (fb.wakeup_walk && !before.walk_active) n[9]++;
      if (flush[0] || flush[1]) { const int oc = int(before.walk_owner); if (a.walk_active && flush[oc]) { n[10]++; if (a.walk_state == WS::L1_WAIT_RESP || a.walk_state == WS::L2_WAIT_RESP) n[11]++; } }
      if (cyc == cycles && std::getenv("GEN_COV"))
        std::fprintf(stderr, "GENCOV grants=%llu events=%llu ev_idle=%llu ev_idmismatch=%llu pointers=%llu pub_fault=%llu pub_leaf1=%llu pub_leaf0=%llu wake_wait=%llu wake_idle=%llu flush_active_walk=%llu flush_in_wait=%llu\n",
                     (unsigned long long)n[0], (unsigned long long)n[1], (unsigned long long)n[2], (unsigned long long)n[3], (unsigned long long)n[4], (unsigned long long)n[5], (unsigned long long)n[6], (unsigned long long)n[7], (unsigned long long)n[8], (unsigned long long)n[9], (unsigned long long)n[10], (unsigned long long)n[11]);
    }
    P.p_fb = fb;
    for (int c = 0; c < 2; ++c) P.p_flush[c] = flush[c];
    MemPtwBlock::SeqIn sq{}; sq.walk_client_flush[0] = flush[0]; sq.walk_client_flush[1] = flush[1];
    if (const char *dbg = std::getenv("GEN_DEBUG_FROM")) {   // print the PTW state around a failing record (rec = cyc + 3)
      if (cyc + 3 >= std::strtoull(dbg, 0, 0) - 6 && cyc + 3 <= std::strtoull(dbg, 0, 0))
        std::fprintf(stderr, "cyc=%llu st=%d active=%d own=%d | in: req=%d%d cons=%d%d flush=%d%d grant=%d ev=%d(id %x) wake=%d | view rdy=%d%d rv=%d%d issue=%d\n", (unsigned long long)cyc,
                     (int)blk.cur_.walk_state, blk.cur_.walk_active, (int)blk.cur_.walk_owner, in.walk_clients[0].req_valid, in.walk_clients[1].req_valid,
                     in.walk_clients[0].resp_consumed, in.walk_clients[1].resp_consumed, flush[0], flush[1], fb.grant_valid, fb.event_count, (unsigned)(fb.events[0].req_id & 0xf), fb.wakeup_walk,
                     view.walk_clients[0].req_ready, view.walk_clients[1].req_ready, view.walk_clients[0].resp_valid, view.walk_clients[1].resp_valid, o.issue_walk_read);
    }
    record(cyc);
    blk.seq(sq);
  }
  return 0;
}

#elif defined(MOD_PERI)
#include "PeripheralAxi.h"
#include "PeripheralModel.h"
#include "mmio_address_map.h"
#include <unordered_map>
static std::unordered_map<uint32_t, uint32_t> g_pmem;
uint32_t pmem_read(uint32_t a) { auto it = g_pmem.find(a & ~3u); return it == g_pmem.end() ? (a * 2654435761u) ^ 0x5a5a1234u : it->second; }
void pmem_write(uint32_t a, uint32_t d) { g_pmem[a & ~3u] = d; }
static uint32_t addr_in_region(int region) {   // 0 AXI, 1 uncached RAM, 2 modeled MMIO
  for (;;) {
    uint32_t a;
    switch (region) {
      case 1: { const uint32_t b[3] = {SIM_UNCACHE_SDRAM_BASE, SIM_UNCACHE_DDR_RESERVED_BASE, SIM_UNCACHE_HIGH_BASE}; a = b[rnd() % 3] + (r32() & 0xffffc); break; }
      case 2: { const uint32_t b[4] = {BOOT_IO_BASE, UART_ADDR_BASE, XPS_INTC_ADDR_BASE, OCSDC_ADDR_BASE}; a = b[rnd() % 4] + (r32() & 0x3c) + (r32() & 3); break; }
      default: a = r32(); break;
    }
    const bool unc = simulator_is_uncached_memory_addr(a), mod = PeripheralModel::is_modeled_mmio(a);
    if (region == 1 && unc) return a;
    if (region == 2 && !unc && mod) return a;
    if (region == 0 && !unc && !mod) return a;
  }
}
int main(int argc, char **argv) {
  if (argc < 5) { std::fprintf(stderr, "usage: gen_rand out.trc seed cycles profile\n"); return 2; }
  setenv("TTG_REC_OUT", argv[1], 1);
  rng.seed(std::strtoull(argv[2], 0, 0));
  const uint64_t cycles = std::strtoull(argv[3], 0, 0);
  const int prof = std::atoi(argv[4]);
  //                    0    1    2    3    4    5
  int p_req[6]    =  {500, 900, 200, 700, 900, 300};   // LSU presents a request
  int p_axi[6]    =  {600, 300, 800, 500, 700, 600};   // request goes to AXI (else local)
  int p_acc[6]    =  {500, 800, 200, 600, 900, 300};   // AXI accepts / answers
  int p_junk[6]   =  { 20,  50,  10,  80, 150,  30};   // handshake pulses that the state machine must ignore
  static uint32_t mem_words[64]; static CsrInterruptInjectIO inj;
  PeripheralModel pm; pm.bind(&inj, mem_words);
  PeripheralAxi pa; PeripheralReqIO req; PeripheralRespIO resp;
  pa.peripheral_req = &req; pa.peripheral_resp = &resp; pa.peripheral_model = &pm; pa.init();
  for (uint64_t cyc = 1; cyc <= cycles; ++cyc) {
    McCycle &P = g_ttg_mc.pub;
    P = McCycle{};
    req = {};
    if (chance(p_req[prof])) {
      req.is_mmio = true; req.wen = chance(500);
      req.mmio_addr = addr_in_region(chance(p_axi[prof]) ? 0 : (chance(500) ? 1 : 2));
      req.mmio_wdata = r32();
      static const int f3[8] = {0, 1, 2, 4, 5, 3, 6, 7};
      req.mmio_fun3 = f3[rnd() % (chance(900) ? 5 : 8)];
    }
    pa.in = {};
    const bool wr = pa.cur.write;
    pa.in.read.req_accepted = (pa.cur.busy && !pa.cur.req_accepted && !wr && chance(p_acc[prof])) || chance(p_junk[prof]);
    pa.in.write.req_accepted = (pa.cur.busy && !pa.cur.req_accepted && wr && chance(p_acc[prof])) || chance(p_junk[prof]);
    pa.in.read.resp_valid = (pa.cur.busy && pa.cur.req_accepted && !wr && chance(p_acc[prof])) || chance(p_junk[prof]);
    pa.in.write.resp_valid = (pa.cur.busy && pa.cur.req_accepted && wr && chance(p_acc[prof])) || chance(p_junk[prof]);
    for (int k = 0; k < DCACHE_WORD_NUM; ++k) pa.in.read.resp_data[k] = r32();
    P.q_req = req; P.q_cur = pa.cur; P.q_in = pa.in;
    P.q_is_uncached = simulator_is_uncached_memory_addr(req.mmio_addr);
    P.q_is_modeled = PeripheralModel::is_modeled_mmio(req.mmio_addr);
    pa.comb_outputs();
    pa.comb_inputs();
    P.q_out = pa.out; P.q_resp = resp; P.q_env_rdata = pa.nxt.rdata;
    if (resp.ready && req.is_mmio) { const bool unc = P.q_is_uncached, mod = P.q_is_modeled; COV(std::string(req.wen ? "wr" : "rd") + (unc ? "_uncached" : mod ? "_modeled" : "_axi")); COV(std::string("f3_") + std::to_string((int)req.mmio_fun3)); }
    if (pa.out.read.req_valid) COV("axi_rd_req"); if (pa.out.write.req_valid) COV("axi_wr_req");
    if (P.q_cur.busy && !P.q_cur.write && P.q_cur.req_accepted && pa.in.read.resp_valid) COV("axi_rd_done");
    if (P.q_cur.busy && P.q_cur.write && P.q_cur.req_accepted && pa.in.write.resp_valid) COV("axi_wr_done");
    if (P.q_cur.busy && !P.q_cur.req_accepted && !P.q_cur.write && pa.in.read.req_accepted) COV("axi_rd_accept");
    if (!P.q_cur.busy && !P.q_cur.resp_valid && !req.is_mmio) COV("idle_no_req");
    if (req.is_mmio && !resp.ready) COV("req_dropped_busy");
    if (cyc == cycles) dump_cov();
    record(cyc);
    pa.seq();
  }
  return 0;
}

#elif defined(MOD_AXI)
// ---- verbatim reference code (extracted by tb/memcpu/build_gen.sh from rv_simu_mmu_v2.cpp) ----
#include "AXI_Interconnect.h"
struct FakeIc {
  axi_interconnect::ReadMasterPort_t read_ports[axi_interconnect::NUM_READ_MASTERS];
  axi_interconnect::WriteMasterPort_t write_ports[axi_interconnect::NUM_WRITE_MASTERS];
  bool read_req_accepted[axi_interconnect::NUM_READ_MASTERS] = {};
  uint8_t read_req_accepted_id[axi_interconnect::NUM_READ_MASTERS] = {};
  bool write_req_accepted[axi_interconnect::NUM_WRITE_MASTERS] = {};
};
struct FakeCpu { FakeIc axi_interconnect; };
#define SimCpu FakeCpu
#ifndef CONFIG_DCACHE_FAST_DOMAIN
#define CONFIG_DCACHE_FAST_DOMAIN 16
#endif
constexpr bool kDcacheFastDomainEnabled = CONFIG_DCACHE_FAST_DOMAIN != 0;
#include "axi_cpu_funcs.inc"
#undef SimCpu
int main(int argc, char **argv) {
  if (argc < 5) { std::fprintf(stderr, "usage: gen_rand out.trc seed cycles profile\n"); return 2; }
  setenv("TTG_REC_OUT", argv[1], 1);
  rng.seed(std::strtoull(argv[2], 0, 0));
  const uint64_t cycles = std::strtoull(argv[3], 0, 0);
  const int prof = std::atoi(argv[4]);
  //                    0    1    2    3    4    5
  int p_acc[6]   =  {200, 600, 100, 400, 900, 300};    // a request is accepted in the cycle
  int p_resp[6]  =  {300, 700, 200, 900, 500, 400};    // a response is presented in the cycle
  int p_rdy[6]   =  {500, 300, 800, 100, 600, 200};    // ready per tick
  int p_hold[6]  =  {800, 500, 900, 300, 700, 600};    // response stays presented while the master does not take it
  g_ttg_mc.on = true;
  FakeCpu cpu;
  axi_interconnect::ReadMasterPort_t dummy;
  (void)dummy;
  const int rd[2] = {axi_interconnect::MASTER_ICACHE, axi_interconnect::MASTER_EXTRA_R};
  const int wrm = axi_interconnect::MASTER_EXTRA_W;
  McAxiTick last_view{};
  // per channel: response presentation (tick window, id) and accept tick
  for (uint64_t cyc = 1; cyc <= cycles; ++cyc) {
    McCycle &P = g_ttg_mc.pub;
    P = McCycle{};
    struct Ch { int acc_tick; int acc_id; int resp_from; int resp_id; bool resp0_ready; } ch[3];
    for (int k = 0; k < 3; ++k) {
      ch[k].acc_tick = chance(p_acc[prof]) ? int(rnd() % 16) : -1;
      ch[k].acc_id = int(rnd() % 4);
      ch[k].resp_from = chance(p_resp[prof]) ? (chance(400) ? 0 : int(rnd() % 16)) : 99;
      ch[k].resp_id = chance(400) ? ch[k].acc_id : int(rnd() % 4);
      ch[k].resp0_ready = chance(600);
    }
    // sets the comb values of tick t into the ports (what the interconnect model does in comb_outputs / seq)
    auto drive = [&](int t) {
      for (int k = 0; k < 2; ++k) {
        auto &p = cpu.axi_interconnect.read_ports[rd[k]];
        p.req.ready = chance(p_rdy[prof]);
        const bool acc = ch[k].acc_tick == t;
        cpu.axi_interconnect.read_req_accepted[rd[k]] = acc;
        cpu.axi_interconnect.read_req_accepted_id[rd[k]] = acc ? ch[k].acc_id : (chance(50) ? r32() & 3 : 0);
        p.req.accepted = acc; p.req.accepted_id = cpu.axi_interconnect.read_req_accepted_id[rd[k]];
        const bool rv = t >= ch[k].resp_from && (t == ch[k].resp_from || chance(p_hold[prof]));
        p.resp.valid = rv; p.resp.id = rv ? ch[k].resp_id : (r32() & 3);
      }
      auto &w = cpu.axi_interconnect.write_ports[wrm];
      w.req.ready = chance(p_rdy[prof]);
      const bool acc = ch[2].acc_tick == t;
      cpu.axi_interconnect.write_req_accepted[wrm] = acc;
      w.req.accepted = acc;
      if (t == 0) w.req.id = ch[2].acc_id;               // ticks 1..15: masked to 0 by mask_axi_cpu_boundary_for_internal_tick
      const bool rv = t >= ch[2].resp_from && (t == ch[2].resp_from || chance(p_hold[prof]));
      w.resp.valid = rv; w.resp.id = rv ? ch[2].resp_id : (r32() & 3);
    };
    AxiCpuBoundaryState st{};
    drive(0);
    for (int k = 0; k < 2; ++k) cpu.axi_interconnect.read_ports[rd[k]].resp.ready = ch[k].resp0_ready;
    cpu.axi_interconnect.write_ports[wrm].resp.ready = ch[2].resp0_ready;
    capture_axi_cpu_boundary_state(cpu, st);
    ttg_mc_sample_axi(cpu, P.ax[0], false);
    for (int t = 1; t < 16; ++t) {
      mask_axi_cpu_boundary_for_internal_tick(cpu);
      drive(t);
      accumulate_axi_cpu_boundary_state(cpu, st);
      ttg_mc_sample_axi(cpu, P.ax[t], false);
    }
    restore_axi_cpu_boundary_state(cpu, st);
    ttg_mc_sample_axi(cpu, P.view, true);
    P.exp_view = last_view;
    last_view = P.view;
    for (int k = 0; k < 3; ++k) {
      const std::string n = k == 0 ? "ic" : k == 1 ? "rdx" : "wrx";
      const auto &a0 = P.ax[0].ch[k], &a15 = P.ax[15].ch[k]; const auto &v = P.view.ch[k];
      bool any = false, late = false; for (int t = 0; t < 16; ++t) { if (P.ax[t].ch[k].accepted) { any = true; if (t) late = true; } }
      if (any) COV(n + "_accepted"); if (late) COV(n + "_accepted_late"); if (a0.accepted) COV(n + "_accepted_t0");
      if (a15.resp_valid) COV(n + "_resp_t15"); if (a15.resp_valid && !v.resp_valid) COV(n + "_resp_hidden");
      if (a0.resp_ready && !v.resp_ready) COV(n + "_resp_ready_withheld");
      if (a15.resp_valid && !(a0.resp_valid && a0.resp_id == a15.resp_id)) COV(n + "_resp_new_in_extra");
      if (v.ready) COV(n + "_ready_any");
      if (k < 2 && v.accepted && v.accepted_id != 0) COV(n + "_acc_id_nonzero");
    }
    if (cyc == cycles) dump_cov();
    for (int t = 0; t < 16; ++t) { g_ttg_mc.t = t; record(cyc * 16 + t); }
  }
  return 0;
}
#endif
