// Random-traffic driver for the reference AXI interconnect + LLC + sim_ddr, used to feed the lock-step plugins with traffic that the
// 68 programs never produce (peripheral read/write ports, bypass writes, partial strobes, same-line read/write races, ...).
// It links the reference objects (AXI_Interconnect.o / AXI_LLC.o / SimDDR.o of the tap refsim), copies the per-tick order of
// rv_simu_mmu_v2.cpp (axi_subsystem_comb_outputs / comb_inputs / seq, the CPU-boundary mask / capture / accumulate / restore of the
// non-DCache masters) and drives master ports with random but protocol-conforming requests.  After every CPU cycle it calls the
// lock-step plugin (TTG_REC_END=<lock_*.dylib>, symbol ttg_rec_cycle_end) exactly like the patched simulator does.
//   usage: rand_axi <seed> <cpu_cycles>      env: TTG_LLC_KB / TTG_LLC_WAYS (geometry), RAND_FOOT (lines per set group, default 40),
//                                            RAND_PERIPH=0 disables the peripheral ports, RAND_PWR=0 only the peripheral WRITE port (bypass writes),
//                                            RAND_PARTIAL=0 forces full strobes (the LLC RTL does not implement partial-line / bypass writes).
#define private public
#define protected public
#include "AXI_Interconnect.h"
#undef private
#undef protected
#include "SimDDR.h"
#include "axi_tap.h"
#include "icache/GenericTable.h"
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <unordered_map>

using namespace axi_interconnect;

long long sim_time = 0;
// the lock plugin only needs the `cur` member of the memory-subsystem tap (spec expressions use TTG_MS.cur)
struct MemTapStub { bool on = false; int cur = 0; } g_ttg_ms_tap;
void ttg_axi_tap_enable();

// ---------------- functional memory (pattern for untouched words, so read data is non-trivial) ----------------
static std::unordered_map<uint32_t, uint32_t> g_mem;
static uint32_t pattern(uint32_t a) { uint32_t x = a * 2654435761u; x ^= x >> 15; x *= 2246822519u; return x ^ (x >> 13); }
uint32_t pmem_read(uint32_t paddr) {
  uint32_t w = paddr & ~3u;
  auto it = g_mem.find(w);
  return it == g_mem.end() ? pattern(w) : it->second;
}
void pmem_write(uint32_t paddr, uint32_t data) { g_mem[paddr & ~3u] = data; }
uint32_t *pmem_ram_ptr() { static uint32_t dummy; return &dummy; }

// ---------------- LLC tables (verbatim copy of AxiLlcTableRuntime from MemSubsystem.cpp) ----------------
#include "axi_llc_tables_runtime.inc"

// ---------------- helpers copied from rv_simu_mmu_v2.cpp ----------------
static void connect_slave(sim_ddr::SimDDR_IO_t &m, const sim_ddr::SimDDR_IO_t &s) {
  m.ar.arready = s.ar.arready; m.r.rvalid = s.r.rvalid; m.r.rid = s.r.rid; m.r.rdata = s.r.rdata; m.r.rresp = s.r.rresp;
  m.r.rlast = s.r.rlast; m.aw.awready = s.aw.awready; m.w.wready = s.w.wready; m.b.bvalid = s.b.bvalid; m.b.bid = s.b.bid;
  m.b.bresp = s.b.bresp;
}
static void connect_master(const sim_ddr::SimDDR_IO_t &m, sim_ddr::SimDDR_IO_t &s) {
  s.ar.arvalid = m.ar.arvalid; s.ar.arid = m.ar.arid; s.ar.araddr = m.ar.araddr; s.ar.arlen = m.ar.arlen;
  s.ar.arsize = m.ar.arsize; s.ar.arburst = m.ar.arburst; s.r.rready = m.r.rready;
  s.aw.awvalid = m.aw.awvalid; s.aw.awid = m.aw.awid; s.aw.awaddr = m.aw.awaddr; s.aw.awlen = m.aw.awlen;
  s.aw.awsize = m.aw.awsize; s.aw.awburst = m.aw.awburst; s.w.wvalid = m.w.wvalid; s.w.wdata = m.w.wdata;
  s.w.wstrb = m.w.wstrb; s.w.wlast = m.w.wlast; s.b.bready = m.b.bready;
}
static bool dc_rd(int m) { return m == MASTER_DCACHE_R; }
static bool dc_wr(int m) { return m == MASTER_DCACHE_W; }

struct BoundaryState {
  bool rd_ready[NUM_READ_MASTERS] = {}, rd_acc[NUM_READ_MASTERS] = {}, rd_resp_valid[NUM_READ_MASTERS] = {},
       rd_resp_ready[NUM_READ_MASTERS] = {}, wr_ready[NUM_WRITE_MASTERS] = {}, wr_acc[NUM_WRITE_MASTERS] = {},
       wr_resp_valid[NUM_WRITE_MASTERS] = {}, wr_resp_ready[NUM_WRITE_MASTERS] = {};
  uint8_t rd_acc_id[NUM_READ_MASTERS] = {}, rd_resp_id[NUM_READ_MASTERS] = {}, wr_acc_id[NUM_WRITE_MASTERS] = {},
          wr_resp_id[NUM_WRITE_MASTERS] = {};
};
static void bs_capture(AXI_Interconnect &ic, BoundaryState &s) {
  for (int i = 0; i < NUM_READ_MASTERS; ++i) {
    s.rd_ready[i] = ic.read_ports[i].req.ready; s.rd_acc[i] = ic.read_req_accepted[i]; s.rd_acc_id[i] = ic.read_req_accepted_id[i];
    s.rd_resp_valid[i] = ic.read_ports[i].resp.valid; s.rd_resp_id[i] = ic.read_ports[i].resp.id;
    s.rd_resp_ready[i] = ic.read_ports[i].resp.ready;
  }
  for (int i = 0; i < NUM_WRITE_MASTERS; ++i) {
    s.wr_ready[i] = ic.write_ports[i].req.ready; s.wr_acc[i] = ic.write_req_accepted[i];
    s.wr_acc_id[i] = ic.write_ports[i].req.id; s.wr_resp_valid[i] = ic.write_ports[i].resp.valid;
    s.wr_resp_id[i] = ic.write_ports[i].resp.id; s.wr_resp_ready[i] = ic.write_ports[i].resp.ready;
  }
}
static void bs_accumulate(AXI_Interconnect &ic, BoundaryState &s) {
  for (int i = 0; i < NUM_READ_MASTERS; ++i) {
    if (dc_rd(i)) continue;
    s.rd_ready[i] = s.rd_ready[i] || ic.read_ports[i].req.ready;
    if (ic.read_req_accepted[i]) { s.rd_acc[i] = true; s.rd_acc_id[i] = ic.read_req_accepted_id[i]; }
  }
  for (int i = 0; i < NUM_WRITE_MASTERS; ++i) {
    if (dc_wr(i)) continue;
    s.wr_ready[i] = s.wr_ready[i] || ic.write_ports[i].req.ready;
    if (ic.write_req_accepted[i]) { s.wr_acc[i] = true; s.wr_acc_id[i] = ic.write_ports[i].req.id; }
  }
}
static void bs_restore(AXI_Interconnect &ic, const BoundaryState &s) {
  for (int i = 0; i < NUM_READ_MASTERS; ++i) {
    if (dc_rd(i)) continue;
    ic.read_req_accepted[i] = s.rd_acc[i]; ic.read_req_accepted_id[i] = s.rd_acc_id[i];
    ic.read_ports[i].req.ready = s.rd_ready[i]; ic.read_ports[i].req.accepted = s.rd_acc[i];
    ic.read_ports[i].req.accepted_id = s.rd_acc_id[i]; ic.read_ports[i].resp.ready = s.rd_resp_ready[i];
    const bool rv = ic.read_ports[i].resp.valid; const uint8_t rid = ic.read_ports[i].resp.id;
    const bool from_extra = rv && !(s.rd_resp_valid[i] && s.rd_resp_id[i] == rid);
    const bool matches_new = s.rd_acc[i] && rv && rid == s.rd_acc_id[i];
    if (matches_new) ic.read_ports[i].resp.valid = false;
    if (from_extra || matches_new) ic.read_ports[i].resp.ready = false;
  }
  for (int i = 0; i < NUM_WRITE_MASTERS; ++i) {
    if (dc_wr(i)) continue;
    ic.write_req_accepted[i] = s.wr_acc[i]; ic.write_ports[i].req.ready = s.wr_ready[i];
    ic.write_ports[i].req.accepted = s.wr_acc[i]; ic.write_ports[i].resp.ready = s.wr_resp_ready[i];
    const bool wv = ic.write_ports[i].resp.valid; const uint8_t wid = ic.write_ports[i].resp.id;
    const bool from_extra = wv && !(s.wr_resp_valid[i] && s.wr_resp_id[i] == wid);
    const bool matches_new = s.wr_acc[i] && wv && wid == s.wr_acc_id[i];
    if (matches_new) ic.write_ports[i].resp.valid = false;
    if (from_extra || matches_new) ic.write_ports[i].resp.ready = false;
  }
}
static void mask_non_dcache(AXI_Interconnect &ic) {
  for (int i = 0; i < NUM_READ_MASTERS; ++i) {
    if (dc_rd(i)) continue;
    auto &p = ic.read_ports[i];
    p.req.valid = false; p.req.addr = 0; p.req.total_size = 0; p.req.id = 0; p.req.bypass = false; p.resp.ready = false;
  }
  for (int i = 0; i < NUM_WRITE_MASTERS; ++i) {
    if (dc_wr(i)) continue;
    auto &p = ic.write_ports[i];
    p.req.valid = false; p.req.addr = 0; p.req.wdata.clear(); p.req.wstrb = 0; p.req.total_size = 0; p.req.id = 0;
    p.req.bypass = false; p.resp.ready = false;
  }
}
static void clear_master_inputs(AXI_Interconnect &ic) {   // clear_axi_master_inputs (tick 0; resp.ready is kept)
  for (int i = 0; i < NUM_READ_MASTERS; i++) {
    auto &p = ic.read_ports[i]; p.req.valid = false; p.req.addr = 0; p.req.total_size = 0; p.req.id = 0; p.req.bypass = false;
  }
  for (int i = 0; i < NUM_WRITE_MASTERS; i++) {
    auto &p = ic.write_ports[i]; p.req.valid = false; p.req.addr = 0; p.req.wdata.clear(); p.req.wstrb = 0;
    p.req.total_size = 0; p.req.id = 0; p.req.bypass = false;
  }
}
struct IntState { bool rr[NUM_READ_MASTERS], dw[NUM_READ_MASTERS], wr[NUM_WRITE_MASTERS]; ReadReqHoldLatch hold[NUM_READ_MASTERS]; };
static void is_capture(AXI_Interconnect &ic, IntState &s) {
  for (int i = 0; i < NUM_READ_MASTERS; ++i) { s.rr[i] = ic.req_ready_r[i]; s.dw[i] = ic.req_drop_warned[i]; s.hold[i] = ic.read_req_hold[i]; }
  for (int i = 0; i < NUM_WRITE_MASTERS; ++i) s.wr[i] = ic.w_req_ready_r[i];
}
static void is_restore_except_dcache(AXI_Interconnect &ic, const IntState &s) {
  for (int i = 0; i < NUM_READ_MASTERS; ++i) {
    if (dc_rd(i)) continue;
    ic.req_ready_r[i] = s.rr[i]; ic.req_drop_warned[i] = s.dw[i]; ic.read_req_hold[i] = s.hold[i];
  }
  for (int i = 0; i < NUM_WRITE_MASTERS; ++i) { if (!dc_wr(i)) ic.w_req_ready_r[i] = s.wr[i]; }
}

// ---------------- random masters ----------------
static uint64_t rng_s = 88172645463325252ull;
static uint32_t rnd() { rng_s ^= rng_s << 13; rng_s ^= rng_s >> 7; rng_s ^= rng_s << 17; return static_cast<uint32_t>(rng_s >> 11); }
static bool chance(unsigned pct) { return (rnd() % 100u) < pct; }
static int g_foot = 40, g_sets = 16;
static bool g_periph = true, g_partial = true, g_pwr = true;
static uint32_t pick_line_addr() {   // a few set groups, many tags per set -> evictions; shared by reads and writes
  const uint32_t set = rnd() % 4u;
  const uint32_t tag = rnd() % static_cast<uint32_t>(g_foot);
  return 0x80000000u + ((tag * static_cast<uint32_t>(g_sets) + set) << 6);
}
struct RdMaster {
  bool pending = false; uint32_t addr = 0; uint8_t size = 0, id = 0; bool byp = false;
  uint32_t out_mask = 0;       // outstanding ids
  unsigned max_out = 4;
};
struct WrMaster {
  bool pending = false, waiting = false; uint32_t addr = 0; uint8_t size = 0; bool byp = false; uint8_t id = 0;
  uint32_t data[16]; uint64_t strb = 0;
};
static RdMaster rm[NUM_READ_MASTERS];
static WrMaster wm[NUM_WRITE_MASTERS];

static void new_rd(int m) {
  RdMaster &r = rm[m];
  uint32_t free_ids = 0;
  const unsigned nid = (m == MASTER_DCACHE_R) ? 8 : (m == 0 ? 2 : 4);
  for (unsigned i = 0; i < nid; ++i) if (!(r.out_mask >> i & 1)) free_ids |= 1u << i;
  if (!free_ids) return;
  unsigned cnt = 0; for (unsigned i = 0; i < nid; ++i) cnt += (r.out_mask >> i) & 1;
  if (cnt >= r.max_out) return;
  unsigned id; do { id = rnd() % nid; } while (!(free_ids >> id & 1));
  r.pending = true; r.id = static_cast<uint8_t>(id);
  if (m == 3 || (m == 0 && chance(15))) {            // peripheral / uncached: bypass, 1/2/4 bytes anywhere in a line
    r.byp = true; r.size = static_cast<uint8_t>(m == 3 ? (chance(50) ? 3 : (chance(50) ? 1 : 0)) : 3);
    r.addr = (m == 3 ? 0x80000000u + ((rnd() % 4u) << 6) : pick_line_addr()) + ((rnd() % 64u) & ~static_cast<uint32_t>(r.size));
  } else {
    r.byp = false; r.size = 63; r.addr = pick_line_addr();
  }
}
static void new_wr(int m) {
  WrMaster &w = wm[m];
  w.pending = true; w.waiting = false; w.id = 0;
  for (int i = 0; i < 16; ++i) w.data[i] = rnd();
  if (m == MASTER_DCACHE_W) {
    w.byp = false; w.size = 63; w.addr = pick_line_addr(); w.strb = ~0ull;
    if (g_partial && chance(15)) { w.strb = 0; for (int b = 0; b < 64; ++b) if (rnd() & 1) w.strb |= 1ull << b; if (!w.strb) w.strb = 1; }
  } else {
    w.byp = true; w.size = static_cast<uint8_t>(chance(50) ? 3 : (chance(50) ? 1 : 0));
    w.addr = 0x80000000u + ((rnd() % 4u) << 6) + ((rnd() % 64u) & ~static_cast<uint32_t>(w.size));
    w.strb = (w.size == 3) ? 0xFull : (w.size == 1 ? 0x3ull : 0x1ull);
  }
}

int main(int argc, char **argv) {
  if (argc < 3) { std::fprintf(stderr, "usage: rand_axi <seed> <cpu_cycles>\n"); return 2; }
  rng_s ^= (static_cast<uint64_t>(std::strtoull(argv[1], nullptr, 0)) + 1) * 0x9E3779B97F4A7C15ull;
  const uint64_t ncyc = std::strtoull(argv[2], nullptr, 0);
  if (const char *e = std::getenv("RAND_FOOT")) g_foot = std::atoi(e);
  if (const char *e = std::getenv("RAND_PERIPH")) g_periph = std::atoi(e) != 0;
  if (const char *e = std::getenv("RAND_PARTIAL")) g_partial = std::atoi(e) != 0;
  if (const char *e = std::getenv("RAND_PWR")) g_pwr = std::atoi(e) != 0;
  AXI_LLCConfig cfg; cfg.enable = true; cfg.size_bytes = 4ull << 20; cfg.ways = 16; cfg.mshr_num = 8; cfg.lookup_latency = 3;
  if (const char *kb = std::getenv("TTG_LLC_KB")) cfg.size_bytes = std::strtoull(kb, nullptr, 0) << 10;
  if (const char *w = std::getenv("TTG_LLC_WAYS")) cfg.ways = static_cast<uint32_t>(std::strtoul(w, nullptr, 0));
  g_sets = static_cast<int>(cfg.set_count());

  const char *plug = std::getenv("TTG_REC_END");
  using EndFn = void (*)(void *, uint64_t); using FinFn = void (*)();
  EndFn endfn = nullptr; FinFn finfn = nullptr;
  if (plug && *plug) {
    void *h = dlopen(plug, RTLD_NOW | RTLD_LOCAL);
    if (!h) { std::fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 2; }
    endfn = reinterpret_cast<EndFn>(dlsym(h, "ttg_rec_cycle_end")); finfn = reinterpret_cast<FinFn>(dlsym(h, "ttg_rec_finish"));
  }
  g_ttg_ms_tap.on = true; ttg_axi_tap_enable();

  AXI_Interconnect ic; sim_ddr::SimDDR ddr; AxiLlcTableRuntime tables;
  ic.set_llc_config(cfg); ic.init(); ddr.init(); tables.configure(cfg);
  rm[0].max_out = 2; rm[1].max_out = 8; rm[3].max_out = 3;

  uint64_t wacc_all = 0, wacc_orphan = 0, wresp_cons = 0;
  uint64_t haz_ar = 0, haz_aw = 0, haz_w = 0;
  const bool dbg = std::getenv("RAND_DBG") != nullptr; int dbg_n = 0;
  BoundaryState bs; uint64_t acc_cnt[4] = {}, bypass_wr = 0;
  unsigned mx_wq[2] = {}, mx_uwq[2] = {}, mx_wdl[2] = {}, mx_rq[4] = {}, mx_vq = 0, mx_pend = 0;
  for (uint64_t cyc = 1; cyc <= ncyc; ++cyc) {
    sim_time = static_cast<long long>(cyc);
    for (int tick = 0; tick < 16; ++tick) {
      g_ttg_axi_tap.cur = tick; g_ttg_ms_tap.cur = tick;
      if (tick == 0) clear_master_inputs(ic); else mask_non_dcache(ic);
      // ---- axi_subsystem_comb_outputs ----
      tables.comb_outputs(); ic.set_llc_lookup_in(tables.lookup_in); ddr.comb_outputs();
      connect_slave(ic.axi_ddr_io, ddr.io); ic.comb_outputs();
      // ---- masters (react to the outputs, then drive their requests) ----
      for (int m = 0; m < NUM_READ_MASTERS; ++m) {
        if (m == 2 || (m == 3 && !g_periph)) continue;
        auto &p = ic.read_ports[m]; RdMaster &r = rm[m];
        if (p.req.accepted && r.pending) { r.pending = false; r.out_mask |= 1u << p.req.accepted_id; ++acc_cnt[m]; }
        const bool cpu_tick = dc_rd(m) || tick == 0;
        if (cpu_tick) {
          p.resp.ready = chance(85);
          if (p.resp.valid && p.resp.ready) r.out_mask &= ~(1u << p.resp.id);
          if (!r.pending && chance(m == MASTER_DCACHE_R ? 30 : 20)) new_rd(m);
          p.req.valid = false;
          if (r.pending) {
            p.req.valid = true; p.req.addr = r.addr; p.req.total_size = r.size; p.req.id = r.id; p.req.bypass = r.byp;
          }
        }
      }
      for (int m = 0; m < NUM_WRITE_MASTERS; ++m) {
        if (m == 1 && (!g_periph || !g_pwr)) continue;
        auto &p = ic.write_ports[m]; WrMaster &w = wm[m];
        if (p.req.accepted && w.pending) { w.pending = false; w.waiting = true; ++bypass_wr; if (dbg && m == 0 && dbg_n++ < 40) std::printf("W%d accept cyc=%llu tick=%d\n", m, (unsigned long long)cyc, tick); }
        if (dbg && m == 0 && cyc >= 1 && cyc <= 4) std::printf("T cyc=%llu tick=%d acc=%d pend=%d wait=%d resp=%d/%d\n", (unsigned long long)cyc, tick, (int)p.req.accepted, (int)w.pending, (int)w.waiting, (int)p.resp.valid, (int)p.resp.ready);
        if (m == 0 && p.req.accepted) { ++wacc_all; if (!w.pending) ++wacc_orphan; }
        if (m == 0 && p.resp.valid && p.resp.ready) ++wresp_cons;
        if (dbg && m == 0 && p.resp.valid && dbg_n < 80) { ++dbg_n; std::printf("W%d resp.valid cyc=%llu tick=%d ready=%d waiting=%d\n", m, (unsigned long long)cyc, tick, (int)p.resp.ready, (int)w.waiting); }
        const bool cpu_tick = dc_wr(m) || tick == 0;
        if (cpu_tick) {
          p.resp.ready = chance(85);
          if (p.resp.valid && p.resp.ready) w.waiting = false;
          if (!w.pending && !w.waiting && chance(m == MASTER_DCACHE_W ? 20 : 15)) new_wr(m);
          p.req.valid = false;
          if (w.pending) {
            p.req.valid = true; p.req.addr = w.addr; p.req.total_size = w.size; p.req.id = w.id; p.req.bypass = w.byp;
            for (int i = 0; i < 16; ++i) p.req.wdata[i] = w.data[i];
            p.req.wstrb = w.strb;
          }
        }
      }
      // ---- axi_subsystem_comb_inputs ----
      if (tick == 0) {
        ic.comb_inputs();
      } else {
        IntState st; is_capture(ic, st); ic.comb_inputs(); is_restore_except_dcache(ic, st);
      }
      connect_master(ic.axi_ddr_io, ddr.io); ddr.comb_inputs();
      // ---- seq ----
      tables.seq(ic.get_llc_table_out()); ic.seq(); ddr.seq();
      if (tick == 0) bs_capture(ic, bs); else bs_accumulate(ic, bs);
      for (int m = 0; m < NUM_WRITE_MASTERS; ++m) {
        mx_wq[m] = std::max<unsigned>(mx_wq[m], ic.llc.io.regs.write_q_count_r[m]);
        mx_uwq[m] = std::max<unsigned>(mx_uwq[m], static_cast<unsigned>(ic.llc_upstream_write_q[m].size()));
        mx_wdl[m] = std::max<unsigned>(mx_wdl[m], static_cast<unsigned>(ic.llc_write_resp_delay[m].size()));
      }
      for (int m = 0; m < NUM_READ_MASTERS; ++m) mx_rq[m] = std::max<unsigned>(mx_rq[m], ic.llc.io.regs.read_resp_q_count_r[m]);
      mx_vq = std::max<unsigned>(mx_vq, ic.llc.io.regs.read_victim_wb_q_count_r);
      mx_pend = std::max<unsigned>(mx_pend, static_cast<unsigned>(ic.r_pending.size()));
      {
        const AxiTapTick &T = g_ttg_axi_tap.t[tick];
        haz_ar += T.dbg_ar_blocked_by_write; haz_aw += T.dbg_aw_blocked_by_read;
        haz_w += T.dbg_wr_blocked_by_read[0] + T.dbg_wr_blocked_by_read[1];
      }
    }
    bs_restore(ic, bs);
    if (endfn) endfn(nullptr, cyc);
  }
  std::printf("rand_axi: %llu cycles, accepted reads icache=%llu dcache=%llu periph=%llu, writes accepted=%llu\n",
              static_cast<unsigned long long>(ncyc), static_cast<unsigned long long>(acc_cnt[0]),
              static_cast<unsigned long long>(acc_cnt[1]), static_cast<unsigned long long>(acc_cnt[3]),
              static_cast<unsigned long long>(bypass_wr));
  std::printf("rand_axi: max llc write_q %u/%u, upstream write_q %u/%u, write resp delay %u/%u, read resp q %u, victim q %u, r_pending %u\n",
              mx_wq[0], mx_wq[1], mx_uwq[0], mx_uwq[1], mx_wdl[0], mx_wdl[1], std::max(mx_rq[0], std::max(mx_rq[1], std::max(mx_rq[2], mx_rq[3]))), mx_vq, mx_pend);
  std::printf("rand_axi: dcache-write accepted pulses %llu (orphan %llu), responses consumed %llu\n", (unsigned long long)wacc_all, (unsigned long long)wacc_orphan, (unsigned long long)wresp_cons);
  std::printf("rand_axi: hazard ticks: AR blocked by pending write %llu, AW blocked by pending read %llu, write accept blocked by read %llu\n",
              (unsigned long long)haz_ar, (unsigned long long)haz_aw, (unsigned long long)haz_w);
  if (finfn) finfn();
  return 0;
}
