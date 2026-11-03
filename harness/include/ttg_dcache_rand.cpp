// Random-stimulus campaign for the DCache-domain lock-step (replaces ttg_ticks_end.cpp via TICKS_END=...; see scripts/dcache_rand.sh).
//
// Real programs never reach some DCache paths (store arriving while a fill is presented, WB merge, ...), so this drives the reference
// MemSubsystem (the real RealDcache + MSHR + WriteBuffer + response latch code, unmodified, used through its own tick functions exactly as
// SimCpu::cycle()/run_extra_axi_subsystem_ticks() call them) with random LSU requests and a random-latency AXI model, records the boundary
// through the normal TTG_MS tap and compares the RTL tick by tick with the same generated lock plugin.  The host simulator only supplies
// the process (any program); its own CPU state is not used.
//   env: TTG_RAND_CYCLES (CPU cycles per configuration, default 100000), TTG_RAND_SEED, TTG_RAND_CFG (comma list: only these configurations)
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <vector>
#include <algorithm>
#include <array>
#include <bitset>
#include <functional>
#include <list>
#include <map>
#include <queue>
#include <set>
#include <string>
#include <unordered_map>
#include <unordered_set>
#define private public
#define protected public
#include "SimCpu.h"
#undef private
#undef protected
#include "memsys_tap.h"

extern "C" void ttg_rec_cycle(SimCpu *cpu, uint64_t cycle);
extern "C" void ttg_rec_finish();

namespace {
struct Rng {
  uint64_t s;
  uint32_t next() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return uint32_t(s >> 11); }
  uint32_t below(uint32_t n) { return n ? next() % n : 0; }
  bool chance(int pct) { return int(below(100)) < pct; }
};

struct Cfg {
  const char *name;
  int ld_pct, st_pct;            // per-port request probability per CPU cycle
  int sets, tags;                // address pool: `sets` sets (spread over few banks) x `tags` tags
  int rd_lo, rd_hi, wr_lo, wr_hi;  // AXI read / write latency in ticks
  int rd_acc, wr_acc;            // accept probability per tick (percent)
  int probe_pct;                 // ICache-route probe on load port 3
  int route_pct;                 // port-3 requests carrying a route id (bit 31)
  int rd_fast_pct;               // percent of reads answered within 0..3 ticks regardless of the latency range
};

const Cfg kCfgs[] = {
    {"mixed",        50, 50, 6, 12, 20, 80, 5, 40, 60, 60, 20, 10, 0},
    {"slow-write",   60, 70, 4, 10, 5, 40, 150, 500, 90, 80, 10, 5, 0},
    {"fast-axi",     70, 70, 2, 6, 0, 3, 0, 3, 100, 100, 10, 10, 0},
    {"slow-read",    60, 60, 6, 12, 200, 600, 5, 30, 70, 70, 10, 5, 0},
    {"same-line",    80, 80, 1, 5, 2, 30, 2, 60, 80, 50, 15, 0, 0},
    {"burst-evict",  40, 90, 3, 16, 30, 70, 120, 260, 100, 100, 5, 5, 0},
    {"light",        15, 15, 8, 8, 40, 120, 10, 80, 50, 50, 30, 10, 0},
    {"mshr-edge",    70, 30, 6, 10, 400, 800, 3, 30, 100, 100, 5, 5, 15},
    {"mshr-edge-st", 25, 80, 6, 10, 400, 800, 3, 30, 100, 100, 5, 5, 20},
};

struct Sim {
  std::unique_ptr<MemSubsystem> ms;
  LsuDcacheIO lsu_req{};
  DcacheLsuIO lsu_resp{};
  ICacheMemPortReq ic_req{};
  ICacheMemPortResp ic_resp{};
  PeripheralReqIO per_req{};
  PeripheralRespIO per_resp{};
  CsrInterruptInjectIO irq{};
  uint32_t dummy_mem[16] = {};
  Rng rng{};
  // AXI model
  struct Rd { int id; uint64_t due; uint32_t data[DCACHE_WORD_NUM]; bool accepted; };
  std::vector<Rd> rds;
  bool rd_pend_acc = false; int rd_pend_id = 0;      // request seen last tick, may be accepted this tick
  bool wr_pend_acc = false, wr_out = false; uint64_t wr_due = 0;
  uint64_t tick = 0;
  uint64_t n_req = 0, n_resp = 0, n_rd_done = 0, n_wr_done = 0, n_fill = 0;   // per-configuration activity (printed at the end)
  bool resp_presented = false; int resp_presented_idx = -1;

  Sim() {
    ms = std::make_unique<MemSubsystem>(nullptr);
    ms->peripheral_req = &per_req;
    ms->peripheral_resp = &per_resp;
    ms->csr_interrupt_inject = &irq;
    ms->memory = dummy_mem;
    ms->lsu2dcache = &lsu_req;
    ms->dcache2lsu = &lsu_resp;
    ms->icache_req = &ic_req;
    ms->icache_resp = &ic_resp;
    ms->set_internal_axi_runtime_active(false);
    ms->init();
  }

  // ---- AXI inputs of this tick (what the interconnect bridge would show) ----
  void drive_axi_inputs(const Cfg &c) {
    MshrAxiIn &mi = ms->mshr_axi_in;
    WbAxiIn &wi = ms->wb_axi_in;
    mi = MshrAxiIn{};
    wi = WbAxiIn{};
    resp_presented = false;
    if (rd_pend_acc && rng.chance(c.rd_acc)) {
      mi.req_accepted = true;
      mi.req_accepted_id = rd_pend_id;
      Rd r{}; r.id = rd_pend_id; r.accepted = true;
      r.due = tick + (rng.chance(c.rd_fast_pct) ? rng.below(4) : c.rd_lo + rng.below(c.rd_hi - c.rd_lo + 1));
      for (int w = 0; w < DCACHE_WORD_NUM; ++w) r.data[w] = rng.next();
      rds.push_back(r);
      rd_pend_acc = false;
    }
    // oldest due response (random order among the due ones)
    std::vector<int> ready;
    for (size_t i = 0; i < rds.size(); ++i) if (rds[i].due <= tick) ready.push_back(int(i));
    if (!ready.empty()) {
      int k = ready[rng.below(uint32_t(ready.size()))];
      mi.resp_valid = true;
      mi.resp_id = rds[k].id;
      for (int w = 0; w < DCACHE_WORD_NUM; ++w) mi.resp_data[w] = rds[k].data[w];
      resp_presented = true; resp_presented_idx = k;
    }
    if (wr_pend_acc && rng.chance(c.wr_acc)) {
      wi.req_accepted = true;
      wr_pend_acc = false; wr_out = true;
      wr_due = tick + c.wr_lo + rng.below(c.wr_hi - c.wr_lo + 1);
    }
    if (wr_out && wr_due <= tick) { wi.resp_valid = true; wr_out = false; ++n_wr_done; }
  }

  // ---- after the tick: what the memory side saw ----
  void observe_axi_outputs() {
    const MshrAxiOut &mo = ms->mshr_axi_out;
    const WbAxiOut &wo = ms->wb_axi_out;
    if (resp_presented && mo.resp_ready) { rds.erase(rds.begin() + resp_presented_idx); ++n_rd_done; }
    if (mo.req_valid) { rd_pend_acc = true; rd_pend_id = int(mo.req_id); } else rd_pend_acc = false;
    wr_pend_acc = wo.req_valid && !wr_out;
  }

  uint32_t pool_addr(const Cfg &c, uint32_t salt) {
    uint32_t set = 3 + 16 * rng.below(2) + rng.below(c.sets) * 1;           // few banks, several rows
    uint32_t tag = rng.chance(8) ? 0 : 0x100 + rng.below(c.tags);   // tag 0: lines whose tag equals the reset value of invalid ways
    return (tag << 14) | ((set & 255u) << 6) | (rng.below(16) << 2) | (salt & 0);
  }

  void gen_request(const Cfg &c) {
    std::memset((void *)&lsu_req, 0, sizeof(lsu_req));   // wire<N> members are not zero-initialised by LsuDcacheIO{}
    lsu_req.icache_req = LSU_LDU_COUNT;
    for (int i = 0; i < LSU_LDU_COUNT; ++i) {
      if (!rng.chance(c.ld_pct)) continue;
      auto &p = lsu_req.req_ports.load_ports[i];
      p.valid = true; p.addr = pool_addr(c, 0); p.req_id = rng.next() & 0x7fffffffu;
      if (i == LSU_LDU_COUNT - 1 && rng.chance(c.route_pct)) p.req_id |= 0x80000000u;
    }
    for (int i = 0; i < LSU_STA_COUNT; ++i) {
      if (!rng.chance(c.st_pct)) continue;
      auto &p = lsu_req.req_ports.store_ports[i];
      p.valid = true; p.addr = pool_addr(c, 0); p.data = rng.next();
      p.strb = uint8_t(1 + rng.below(15)); p.req_id = rng.below(64);
    }
    ic_req.req_valid = rng.chance(c.probe_pct);
    ic_req.req_addr = pool_addr(c, 0);
  }

  void run_cycle(const Cfg &c) {
    gen_request(c);
    if (std::getenv("TTG_RAND_DEBUG") && tick < 160) { std::fprintf(stderr, "gen:"); for (int i = 0; i < LSU_LDU_COUNT; ++i) std::fprintf(stderr, " %d", int(lsu_req.req_ports.load_ports[i].valid)); std::fprintf(stderr, "\n"); }
    for (int i = 0; i < LSU_LDU_COUNT; ++i) n_req += lsu_req.req_ports.load_ports[i].valid;
    for (int i = 0; i < LSU_STA_COUNT; ++i) n_req += lsu_req.req_ports.store_ports[i].valid;
    // tick 0 = SimCpu::cycle(): comb_outputs, comb_inputs, seq of the memory subsystem (the other blocks are idle)
    g_ttg_ms_tap.cur = 0;
    drive_axi_inputs(c);
    ms->comb_outputs();
    ms->comb_inputs();
    observe_axi_outputs();
    for (int i = 0; i < LSU_LDU_COUNT; ++i) n_resp += ms->dcache_resp_route_.resp_ports.load_resps[i].valid;
    for (int i = 0; i < LSU_STA_COUNT; ++i) n_resp += ms->dcache_resp_route_.resp_ports.store_resps[i].valid;
    n_fill += ms->dcache_resp_route_.mshr_fill;
    ms->seq();
    ++tick;
    // ticks 1..15 = run_extra_axi_subsystem_ticks (dcache fast domain, empty request)
    for (int t = 1; t < TTG_MS_TICKS; ++t) {
      g_ttg_ms_tap.cur = t;
      drive_axi_inputs(c);
      ms->dcache_fast_comb(false);
      observe_axi_outputs();
      ms->dcache_fast_seq(false);
      ++tick;
    }
  }
};
}  // namespace

extern "C" void ttg_rec_cycle_end(SimCpu *cpu, uint64_t) {
  static bool done = false;
  if (done) return;
  done = true;
  const char *e;
  uint64_t cycles = (e = std::getenv("TTG_RAND_CYCLES")) ? std::strtoull(e, nullptr, 0) : 100000;
  uint64_t seed = (e = std::getenv("TTG_RAND_SEED")) ? std::strtoull(e, nullptr, 0) : 1;
  std::string only_list = (e = std::getenv("TTG_RAND_CFG")) ? std::string(",") + e + "," : std::string();
  g_ttg_ms_tap.on = true;
  auto sim = std::make_unique<Sim>();
  int n = int(sizeof(kCfgs) / sizeof(kCfgs[0]));
  for (int k = 0; k < n; ++k) {
    if (!only_list.empty() && only_list.find("," + std::to_string(k) + ",") == std::string::npos) continue;
    sim->rng.s = seed * 0x9E3779B97F4A7C15ull + 12345 + k;
    std::fprintf(stderr, "dcache_rand: config %d '%s' (%llu cycles)\n", k, kCfgs[k].name, (unsigned long long)cycles);
    for (uint64_t cyc = 0; cyc < cycles; ++cyc) {
      sim->run_cycle(kCfgs[k]);
      for (int t = 0; t < TTG_MS_TICKS; ++t) {
        g_ttg_ms_tap.cur = t;
        ttg_rec_cycle(cpu, (uint64_t(k) << 40) + cyc * TTG_MS_TICKS + t);
      }
    }
    std::fprintf(stderr, "dcache_rand:   requests %llu, responses published %llu, fills %llu, AXI reads %llu, writes %llu\n",
                 (unsigned long long)sim->n_req, (unsigned long long)sim->n_resp, (unsigned long long)sim->n_fill,
                 (unsigned long long)sim->n_rd_done, (unsigned long long)sim->n_wr_done);
    sim->n_req = sim->n_resp = sim->n_fill = sim->n_rd_done = sim->n_wr_done = 0;
  }
  ttg_rec_finish();
  std::fflush(stdout);
  std::_Exit(0);
}
