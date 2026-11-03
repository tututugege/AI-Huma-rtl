// Closed-loop testbench for rtl/core/soc_top (core + memory subsystem, RTL) with the reference's behavioural platform models:
// SimDDR (DDR timing) and PhysMemory (RAM image).  DDR / PhysMemory are the unmodified reference sources, so the DDR timing
// (latencies, write queue, turnaround) is the reference's by construction.
// One CPU cycle = 16 fast ticks.  The core is clocked by clk_cpu, pulsed together with the fast clock edge that ends tick 0.
//   usage: soc_tb <program.bin> [max_cycles]       prints "RTL sim-time(cycle)= N, committed= M" when an ebreak commits.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <vector>

#include "Vsoc_top.h"
#include "Vsoc_top___024root.h"
#include "verilated.h"

#include "trace_format.h"
#include "soc_probe.inc"

#include "PhysMemory.h"
#include "SimDDR.h"
#include "config.h"
#include "mmio_address_map.h"
#include "IO.h"
#include "PeripheralModel.h"

long long sim_time = 0;   // the reference's global cycle counter (PeripheralModel's timer reads it)

namespace {
constexpr int kTicks = 16;
constexpr int kInstStore = 6;   // InstType::STORE
constexpr int kUopEbreak = 10;  // the commit entry's `type` is the instruction type (rob_pkg ITYPE_EBREAK)

void load_image(const char *path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) { std::fprintf(stderr, "cannot open %s\n", path); std::exit(2); }
  f.seekg(0, std::ios::end);
  std::streamsize size = f.tellg();
  f.seekg(0, std::ios::beg);
  if (!f.read(reinterpret_cast<char *>(pmem_ram_ptr()), size)) { std::fprintf(stderr, "read failed\n"); std::exit(2); }
  // BackTop::load_image boot stub
  pmem_write(0x0, 0xf1402573);
  pmem_write(0x4, 0x83e005b7);
  pmem_write(0x8, 0x800002b7);
  pmem_write(0xc, 0x00028067);
}

// ---- optional per-cycle comparison with a core_top trace recorded from the reference (scripts/record.sh core_top prog) ----
struct RefTrace {
  FILE *f = nullptr;
  std::vector<uint8_t> rec;      // in + out of the current record
  bool open(const char *path) {
    f = std::fopen(path, "rb");
    if (!f) return false;
    char magic[8]; uint32_t inb, outb; uint64_t hash; uint16_t nl;
    if (std::fread(magic, 1, 8, f) != 8 || std::fread(&inb, 4, 1, f) != 1 || std::fread(&outb, 4, 1, f) != 1 ||
        std::fread(&hash, 8, 1, f) != 1 || std::fread(&nl, 2, 1, f) != 1) return false;
    std::fseek(f, nl, SEEK_CUR);
    if (inb != kInBytesProbe || outb != kOutBytesProbe) { std::fprintf(stderr, "trace layout mismatch\n"); return false; }
    rec.assign(kInBytesProbe + kOutBytesProbe, 0);
    return true;
  }
  bool next(uint8_t &flags) {   // returns false at EOF
    uint64_t cyc;
    if (std::fread(&cyc, 8, 1, f) != 1 || std::fread(&flags, 1, 1, f) != 1) return false;
    return std::fread(rec.data(), 1, rec.size(), f) == rec.size();
  }
};

// returns the number of mismatching fields (prints them)
// mem->core input fields the core only consumes when the paired valid/accepted bit is set (core_top.io has no `when` on inputs)
const char *input_gate(const char *name) {
  static const char *kGate[][2] = {
      {"mem_req_accepted_id", "mem_req_accepted"}, {"mem_resp_id", "mem_resp_valid"}, {"mem_resp_data", "mem_resp_valid"},
      {"dc_resp_data", "dc_resp_valid"}, {"dc_resp_retry", "dc_resp_valid"}, {"dc_resp_miss", "dc_resp_valid"},
      {"itlb_walk_resp_fault", "itlb_walk_resp_valid"}, {"itlb_walk_resp_vpn", "itlb_walk_resp_valid"},
      {"itlb_walk_resp_leaf_ppn", "itlb_walk_resp_valid"}, {"itlb_walk_resp_leaf_perm", "itlb_walk_resp_valid"},
      {"itlb_walk_resp_leaf_level", "itlb_walk_resp_valid"},
      {"dtlb_walk_resp_fault", "dtlb_walk_resp_valid"}, {"dtlb_walk_resp_vpn", "dtlb_walk_resp_valid"},
      {"dtlb_walk_resp_leaf_ppn", "dtlb_walk_resp_valid"}, {"dtlb_walk_resp_leaf_perm", "dtlb_walk_resp_valid"},
      {"dtlb_walk_resp_leaf_level", "dtlb_walk_resp_valid"},
      {"dcache2lsu_load_resps_data", "dcache2lsu_load_resps_valid"}, {"dcache2lsu_load_resps_replay", "dcache2lsu_load_resps_valid"},
      {"dcache2lsu_load_resps_req_id", "dcache2lsu_load_resps_valid"},
      {"dcache2lsu_store_resps_replay", "dcache2lsu_store_resps_valid"}, {"dcache2lsu_store_resps_req_id", "dcache2lsu_store_resps_valid"},
      {"dcache2lsu_mshr_fill_line", "dcache2lsu_mshr_fill"}, {"peripheral_resp_mmio_rdata", "peripheral_resp_ready"},
      {"peripheral_resp_is_mmio", "peripheral_resp_ready"}};
  for (auto &g : kGate) if (!std::strcmp(g[0], name)) return g[1];
  return nullptr;
}

int compare_boundary(const uint8_t *got_in, const uint8_t *got_out, const uint8_t *exp_in, const uint8_t *exp_out, uint64_t cyc) {
  int bad = 0;
  for (const auto &f : kProbe) {
    const uint8_t *g = (f.is_out ? got_out : got_in) + f.off;
    const uint8_t *e = (f.is_out ? exp_out : exp_in) + f.off;
    for (int i = 0; i < f.nelem; ++i) {
      bool skip = false;
      if (!f.is_out) {
        if (const char *gname = input_gate(f.name)) {
          for (const auto &w : kProbe)
            if (!std::strcmp(w.name, gname)) {
              const uint8_t *we = (w.is_out ? exp_out : exp_in) + w.off + (w.nelem == f.nelem ? i : 0) * w.ebytes;
              if (!(ttg::get_elem(we, w.ebytes) & 1)) skip = true;
            }
        }
      }
      if (skip) continue;
      if (f.when >= 0) {   // gate: 1-bit field of the same record (same element if it has the same dimensions)
        const auto &w = kProbe[f.when];
        const uint8_t *we = (w.is_out ? exp_out : exp_in) + w.off + (w.nelem == f.nelem ? i : 0) * w.ebytes;
        if (!(ttg::get_elem(we, w.ebytes) & 1)) continue;
      }
      uint64_t gv = ttg::get_elem(g + i * f.ebytes, f.ebytes), ev = ttg::get_elem(e + i * f.ebytes, f.ebytes);
      if (f.width < 64) { gv &= (1ull << f.width) - 1; ev &= (1ull << f.width) - 1; }
      if (gv != ev) {
        if (bad < 16) std::fprintf(stderr, "  MISMATCH cycle=%llu %s[%d] (%s): ref=0x%llx rtl=0x%llx\n", (unsigned long long)cyc, f.name, i,
                                   f.is_out ? "core out" : "mem->core in", (unsigned long long)ev, (unsigned long long)gv);
        ++bad;
      }
    }
  }
  return bad;
}

// ---- peripheral environment (the reference's PeripheralModel + uncached RAM), see docs/modules/peripheral_axi.md ----
uint8_t uncached_size(uint8_t func3) { switch (func3 & 3u) { case 0: return 1; case 1: return 2; default: return 4; } }
uint32_t extract_uncached(uint32_t raw, uint8_t func3) {
  switch (func3) {
    case 0: { uint32_t v = raw & 0xFFu; return (v & 0x80u) ? (v | 0xFFFFFF00u) : v; }
    case 1: { uint32_t v = raw & 0xFFFFu; return (v & 0x8000u) ? (v | 0xFFFF0000u) : v; }
    case 4: return raw & 0xFFu;
    case 5: return raw & 0xFFFFu;
    default: return raw;
  }
}
uint32_t read_uncached_ram(uint32_t addr, uint8_t func3) {
  uint32_t raw = 0;
  for (uint8_t i = 0; i < uncached_size(func3); i++) {
    uint32_t a = addr + i;
    raw |= ((pmem_read(a & ~0x3u) >> ((a & 3u) * 8u)) & 0xFFu) << (i * 8u);
  }
  return extract_uncached(raw, func3);
}
void write_uncached_ram(uint32_t addr, uint32_t data, uint8_t func3) {
  for (uint8_t i = 0; i < uncached_size(func3); i++) {
    uint32_t a = addr + i, w = a & ~0x3u, sh = (a & 3u) * 8u;
    pmem_write(w, (pmem_read(w) & ~(0xFFu << sh)) | (((data >> (i * 8u)) & 0xFFu) << sh));
  }
}
}  // namespace

int main(int argc, char **argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: soc_tb prog.bin [max_cycles]\n"); return 2; }
  const uint64_t max_cycles = argc > 2 ? std::strtoull(argv[2], nullptr, 0) : 2000000;
  const char *trace_path = std::getenv("SOC_TB_TRACE");   // reference trace of the core_top boundary (per-cycle compare)
  RefTrace trace;
  if (trace_path && !trace.open(trace_path)) { std::fprintf(stderr, "cannot read trace %s\n", trace_path); return 2; }
  int compare_fail = 0;
  Verilated::commandArgs(argc, argv);
  if (!pmem_init()) { std::fprintf(stderr, "pmem_init failed\n"); return 2; }
  load_image(argv[1]);

  sim_ddr::SimDDR ddr;
  ddr.init();
  CsrInterruptInjectIO irq{};
  PeripheralModel periph;
  periph.bind(&irq, p_memory);
  auto *top = new Vsoc_top;

  uint64_t ticks = 0, cycles = 0, committed = 0;
  bool done = false;
  auto tick = [&](int phase) {
    // DDR slave outputs -> RTL
    ddr.comb_outputs();
    top->d_arready = ddr.io.ar.arready;
    top->d_rvalid = ddr.io.r.rvalid;
    top->d_rid = ddr.io.r.rid;
    for (int w = 0; w < 8; ++w) top->d_rdata[w] = axi_compat::get_u32(ddr.io.r.rdata, w);
    top->d_awready = ddr.io.aw.awready;
    top->d_wready = ddr.io.w.wready;
    top->d_bvalid = ddr.io.b.bvalid;
    top->d_bid = ddr.io.b.bid;
    top->d_bresp = ddr.io.b.bresp;
    top->eval();
    {   // peripheral environment: region decode + same-cycle read data (combinational inputs of peripheral_axi)
      auto *Rt = top->rootp;
      const uint32_t pa = Rt->soc_top__DOT__peripheral_req_mmio_addr;
      const uint8_t pf3 = Rt->soc_top__DOT__peripheral_req_mmio_fun3;
      top->env_region = simulator_is_uncached_memory_addr(pa) ? 1 : (PeripheralModel::is_modeled_mmio(pa) ? 2 : 0);
      top->env_rdata = top->env_rd_en ? (top->env_region == 1 ? read_uncached_ram(top->env_rd_addr, top->env_rd_func3)
                                                              : periph.read_load(top->env_rd_addr, top->env_rd_func3)) : 0;
      (void)pf3;
      top->eval();
    }
    // RTL master outputs -> DDR
    ddr.io.ar.arvalid = top->d_arvalid;
    ddr.io.ar.arid = top->d_arid;
    ddr.io.ar.araddr = top->d_araddr;
    ddr.io.ar.arlen = top->d_arlen;
    ddr.io.ar.arsize = sim_ddr::AXI_SIZE_CODE;
    ddr.io.ar.arburst = sim_ddr::AXI_BURST_INCR;
    ddr.io.r.rready = top->d_rready;
    ddr.io.aw.awvalid = top->d_awvalid;
    ddr.io.aw.awid = top->d_awid;
    ddr.io.aw.awaddr = top->d_awaddr;
    ddr.io.aw.awlen = top->d_awlen;
    ddr.io.aw.awsize = sim_ddr::AXI_SIZE_CODE;
    ddr.io.aw.awburst = sim_ddr::AXI_BURST_INCR;
    ddr.io.w.wvalid = top->d_wvalid;
    for (int w = 0; w < 8; ++w) axi_compat::set_u32(ddr.io.w.wdata, w, top->d_wdata[w]);
    ddr.io.w.wstrb = top->d_wstrb;
    ddr.io.w.wlast = top->d_wlast;
    ddr.io.b.bready = top->d_bready;
    ddr.comb_inputs();
    if (phase == 0 && top->rst_n && std::getenv("SOC_TB_DBG")) {
      auto *R = top->rootp;
      std::fprintf(stderr, "[cyc %llu] mem_req v=%d a=%08x acc=%d resp_v=%d | dc_req v=%d a=%08x resp v=%d r=%d m=%d | ld v=%d%d%d%d a3=%08x | ldresp v=%d%d%d%d | st v=%d%d%d%d\n",
                   (unsigned long long)cycles + 1, R->soc_top__DOT__mem_req_valid, R->soc_top__DOT__mem_req_addr, R->soc_top__DOT__mem_req_accepted, R->soc_top__DOT__mem_resp_valid,
                   R->soc_top__DOT__dc_req_valid, R->soc_top__DOT__dc_req_addr, R->soc_top__DOT__dc_resp_valid, R->soc_top__DOT__dc_resp_retry, R->soc_top__DOT__dc_resp_miss,
                   R->soc_top__DOT__lsu2dcache_load_ports_valid[0], R->soc_top__DOT__lsu2dcache_load_ports_valid[1], R->soc_top__DOT__lsu2dcache_load_ports_valid[2], R->soc_top__DOT__lsu2dcache_load_ports_valid[3],
                   R->soc_top__DOT__lsu2dcache_load_ports_addr[3],
                   R->soc_top__DOT__dcache2lsu_load_resps_valid[0], R->soc_top__DOT__dcache2lsu_load_resps_valid[1], R->soc_top__DOT__dcache2lsu_load_resps_valid[2], R->soc_top__DOT__dcache2lsu_load_resps_valid[3],
                   R->soc_top__DOT__lsu2dcache_store_ports_valid[0], R->soc_top__DOT__lsu2dcache_store_ports_valid[1], R->soc_top__DOT__lsu2dcache_store_ports_valid[2], R->soc_top__DOT__lsu2dcache_store_ports_valid[3]);
    }
    if (phase == 0 && top->rst_n && trace_path && !compare_fail) {
      static std::vector<uint8_t> gi(kInBytesProbe), go(kOutBytesProbe);
      static bool skipped_reset = false;
      uint8_t flags;
      if (!skipped_reset) { for (int k = 0; k < 3; ++k) trace.next(flags); skipped_reset = true; }
      if (trace.next(flags)) {
        soc_probe(top, gi.data(), go.data());
        if (const char *show = std::getenv("SOC_TB_SHOW")) {   // comma list of field names: print ref/rtl element 0 every cycle
          std::string list = std::string(",") + show + ",";
          std::fprintf(stderr, "[cyc %llu]", (unsigned long long)cycles + 1);
          for (const auto &f : kProbe) {
            if (list.find(std::string(",") + f.name + ",") == std::string::npos) continue;
            const uint8_t *g = (f.is_out ? go.data() : gi.data()) + f.off;
            const uint8_t *e = (f.is_out ? trace.rec.data() + kInBytesProbe : trace.rec.data()) + f.off;
            unsigned long long gv = ttg::get_elem(g, f.ebytes), ev = ttg::get_elem(e, f.ebytes);
            std::fprintf(stderr, " %s=%llx%s", f.name, ev, gv == ev ? "" : (std::string("(rtl ") + std::to_string(gv) + ")").c_str());
          }
          std::fprintf(stderr, "\n");
        }
        if (compare_boundary(gi.data(), go.data(), trace.rec.data(), trace.rec.data() + kInBytesProbe, cycles + 1)) {
          compare_fail = 1; done = true;
        }
      }
    }
    if (phase == 0 && top->rst_n) {   // the CPU acts in tick 0: look at the retirement stream before the edge
      for (int i = 0; i < 8; ++i)
        if (top->rob_commit_commit_entry_valid[i]) {
          ++committed;
          if (std::getenv("SOC_TB_COMMIT")) std::fprintf(stderr, "[cyc %llu] commit[%d] type=%d pc=%08x\n", (unsigned long long)cycles + 1, i,
                                                         top->rob_commit_commit_entry_uop_type[i], top->ftq_commit_info_resp_pc[i]);
          if (top->rob_commit_commit_entry_uop_type[i] == kUopEbreak) done = true;
          // SimCpu::commit_sync: a committing store applies its device effect (PeripheralModel::on_commit_store) from the STQ entry
          if (top->rob_commit_commit_entry_uop_type[i] == kInstStore && !top->rob_commit_commit_entry_uop_page_fault_store[i]) {
            const auto &fld = top->rootp->soc_top__DOT__u_core__DOT__u_back__DOT__u_lsu__DOT__u_core__DOT__st_fld_q[top->rob_commit_commit_entry_uop_stq_idx[i]];
            auto bits = [&](int lo, int w) { uint64_t v = 0; for (int b = 0; b < w; ++b) { int k = lo + b; v |= uint64_t((fld[k / 32] >> (k % 32)) & 1u) << b; } return uint32_t(v); };
            if (!bits(3, 1) && bits(5, 1) && bits(6, 1)) periph.on_commit_store(bits(91, 32), bits(155, 32), uint8_t(bits(88, 3)));
          }
        }
    }
    if (std::getenv("SOC_TB_TICK") && cycles + 1 >= std::strtoull(std::getenv("SOC_TB_TICK"), nullptr, 0)) {
      auto *R = top->rootp;
      std::fprintf(stderr, "  t%02d dcin_ld_v3=%d icache_req=%d | dc_ld_resp_v3=%d retry3=%d | route: ic_resp_v=%d miss=%d\n", phase,
        R->soc_top__DOT__u_mem__DOT__dc_ld_valid_in[3], R->soc_top__DOT__u_mem__DOT__dc_icache_req,
        R->soc_top__DOT__u_mem__DOT__dc_ld_resp_valid[3], R->soc_top__DOT__u_mem__DOT__dc_ld_resp_retry[3],
        R->soc_top__DOT__dc_resp_valid, R->soc_top__DOT__dc_resp_miss);
    }
    if (phase == 0 && top->rst_n) {
      auto *Rt = top->rootp;
      if (top->env_wr_en && top->env_region == 1) write_uncached_ram(top->env_wr_addr, top->env_wr_data, top->env_wr_func3);
    }
    ddr.seq();
    top->clk = 1;
    if (phase == 0) top->clk_cpu = 1;
    top->eval();
    top->clk = 0;
    top->clk_cpu = 0;
    if (phase == 0 && top->rst_n) {   // MemSubsystem::seq -> peripheral_model_.tick(); interrupts for the next cycle
      periph.tick();
      top->interrupt_inject_external_irq_pending = irq.external_irq_pending;
      top->interrupt_inject_external_irq_pending_valid = irq.external_irq_pending_valid;
      top->interrupt_inject_supervisor_external_irq_pending = irq.supervisor_external_irq_pending;
      top->interrupt_inject_supervisor_external_irq_pending_valid = irq.supervisor_external_irq_pending_valid;
      top->interrupt_inject_timer_irq_pending = irq.timer_irq_pending;
      top->interrupt_inject_timer_irq_pending_valid = irq.timer_irq_pending_valid;
    }
    top->eval();
    ++ticks;
  };

  // reset: 3 CPU cycles
  top->rst_n = 0; top->clk = 0; top->clk_cpu = 0;
  top->interrupt_inject_external_irq_pending = 0; top->interrupt_inject_external_irq_pending_valid = 1;
  top->interrupt_inject_supervisor_external_irq_pending = 0; top->interrupt_inject_supervisor_external_irq_pending_valid = 1;
  top->interrupt_inject_timer_irq_pending = 0; top->interrupt_inject_timer_irq_pending_valid = 1;
  top->env_region = 0; top->env_rdata = 0;
  top->interrupt_inject_external_irq_pending = irq.external_irq_pending; top->interrupt_inject_external_irq_pending_valid = irq.external_irq_pending_valid;
  top->interrupt_inject_supervisor_external_irq_pending = irq.supervisor_external_irq_pending; top->interrupt_inject_supervisor_external_irq_pending_valid = irq.supervisor_external_irq_pending_valid;
  top->interrupt_inject_timer_irq_pending = irq.timer_irq_pending; top->interrupt_inject_timer_irq_pending_valid = irq.timer_irq_pending_valid;
  for (int c = 0; c < 3; ++c)
    for (int p = 0; p < kTicks; ++p) tick(p);
  top->rst_n = 1;
  const bool trace_cyc = std::getenv("SOC_TB_CYC") != nullptr;
  while (!done && cycles < max_cycles) {
    sim_time = static_cast<long long>(cycles);
    if (trace_cyc) std::fprintf(stderr, "cyc %llu\n", (unsigned long long)cycles + 1);
    for (int p = 0; p < kTicks; ++p) {
      tick(p);
      if (p == 0 && done) break;
    }
    ++cycles;
  }
  if (compare_fail) std::printf("FIRST MISMATCH at cycle %llu (see above)\n", (unsigned long long)cycles + 1);
  std::printf("RTL sim-time(cycle)= %llu, committed= %llu%s\n", (unsigned long long)cycles, (unsigned long long)committed,
              done ? "" : "  (NO EBREAK within the cycle cap)");
  delete top;
  return compare_fail ? 3 : (done ? 0 : 1);
}
