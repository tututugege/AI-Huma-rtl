// Closed-loop testbench for rtl/core/soc_top (core + memory subsystem, RTL) with the reference's behavioural platform models:
// SimDDR (DDR timing) and PhysMemory (RAM image).  DDR / PhysMemory are the unmodified reference sources, so the DDR timing
// (latencies, write queue, turnaround) is the reference's by construction.
// One CPU cycle = kTicks fast ticks (CONFIG_AXI_SUBSYSTEM_FREQ_DIV, 1 since EXP-006; 16 in the original divided arrangement).  The core is clocked by clk_cpu, pulsed together with the fast clock edge that ends tick 0.
//   usage: soc_tb <program.bin> [max_cycles]       prints "RTL sim-time(cycle)= N, committed= M" when an ebreak commits.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <string>
#include <fstream>
#include <vector>

#include "Vsoc_top.h"
#include "Vsoc_top___024root.h"
#include "verilated.h"

#include "trace_format.h"
#include "soc_probe.inc"

#include "PhysMemory.h"
#include <deque>
#include <queue>
#include <vector>
#define private public   // idle probe reads SimDDR queues/cooldowns (test-bench only)
#include "SimDDR.h"
#undef private
#include "config.h"
#include "mmio_address_map.h"
#include "IO.h"
#include "PeripheralModel.h"
#ifdef SOC_TB_FM
#include "fm_check.h"
#endif

long long sim_time = 0;   // the reference's global cycle counter (PeripheralModel's timer reads it)

namespace {
constexpr int kTicks = CONFIG_AXI_SUBSYSTEM_FREQ_DIV;   // fast ticks per CPU cycle (platform config.h = trace-model config.h = rtl ttg_cfg_pkg)
static_assert(kTicks >= 1 && kTicks <= 16, "mem_top phase counter is 4 bits");
constexpr int kInstStore = 6;   // InstType::STORE
constexpr int kPmuEv = 51;           // pmu_ev_pkg::PMU_NUM_EV (gen_pmu_pkg.py)
static uint64_t pmu_total[kPmuEv];
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
  // BackTop::seed_uart_io_words: UART status registers as seen by MMIO reads
  constexpr uint32_t kLsr = 0x20u | 0x40u, kMsr = 0x10u | 0x20u | 0x80u;
  pmem_write(UART_ADDR_BASE + 0x00u, (0x01u | 0xc0u) << 16);
  pmem_write(UART_ADDR_BASE + 0x04u, 0x00000003u | (kLsr << 8) | (kMsr << 16));
  pmem_write(UART_ADDR_BASE + 0x08u, 0);
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
      {"dcache2lsu_mshr_fill_line", "dcache2lsu_mshr_fill"}, {"peripheral_resp_mmio_rdata", "peripheral_resp_is_mmio"}};
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
  std::vector<uint32_t> stub_words;   // restore program, also handed to the function model (its boot window is not RAM)
  load_image(argv[1]);
  if (const char *stub = std::getenv("SOC_TB_STUB")) {   // checkpoint start: the restore program (function-model/tools/ckpt2stub.py) replaces the boot stub at 0x0
    std::ifstream sf(stub, std::ios::binary);
    std::vector<char> sb((std::istreambuf_iterator<char>(sf)), std::istreambuf_iterator<char>());
    if (sb.empty()) { std::fprintf(stderr, "cannot read %s\n", stub); return 2; }
    for (uint32_t a = 0; a < 0x100; a += 4) pmem_write(a, 0);
    for (size_t k = 0; k + 4 <= sb.size(); k += 4) { uint32_t w; std::memcpy(&w, &sb[k], 4); pmem_write(uint32_t(k), w); stub_words.push_back(w); }
  }

  sim_ddr::SimDDR ddr;
  ddr.init();
  CsrInterruptInjectIO irq{};
  PeripheralModel periph;
  periph.bind(&irq, p_memory);
  auto *top = new Vsoc_top;

  uint64_t ticks = 0, cycles = 0, committed = 0;
  bool done = false;
    std::vector<std::pair<size_t, size_t>> skipmask;   // scratch-temporary byte ranges of the Verilated root (build/soc/skipmask.txt)
  {
    std::string exe = argv[0];
    std::ifstream mf(exe.substr(0, exe.rfind('/')) + "/../skipmask.txt");
    size_t o, s;
    while (mf >> o >> s) skipmask.push_back({o, s});
    const auto *base = reinterpret_cast<const uint8_t *>(top->rootp);
    skipmask.push_back({size_t(reinterpret_cast<const uint8_t *>(&top->rootp->soc_top__DOT__u_mem__DOT__phase_q) - base), 1});   // the tick counter differs by construction
    std::sort(skipmask.begin(), skipmask.end());
  }
  std::vector<std::pair<size_t, size_t>> keep;   // complement: the bytes snapshotted and compared
  {
    size_t pos = 0;
    for (const auto &m : skipmask) { if (m.first > pos) keep.push_back({pos, m.first - pos}); pos = std::max(pos, m.first + m.second); }
    if (pos < sizeof(*top->rootp)) keep.push_back({pos, sizeof(*top->rootp) - pos});
  }
  long long prof_ns[16] = {0}, prof_n[16] = {0};
  const bool semihost = std::getenv("SOC_TB_SEMIHOST") != nullptr;
#ifdef SOC_TB_FM
  FmCheck fm;   // SOC_TB_FM=1: every committed instruction is also executed by the function model and compared
  const bool fm_on = std::getenv("SOC_TB_FM") != nullptr;
  struct FmPend { uint32_t pc; unsigned rd; unsigned preg; bool irq; };
  std::vector<FmPend> fm_pend;
  auto fm_flush = [&](uint64_t cyc) {
    for (const auto &c : fm_pend) {
      if (c.irq) {   // the trap was taken on the edge of the interrupt slot: cause / privilege are in the CSR file now
        auto &R = *top->rootp;
        const uint8_t priv = R.soc_top__DOT__u_core__DOT__u_back__DOT__u_csr__DOT__privilege;
        const auto &regs = R.soc_top__DOT__u_core__DOT__u_back__DOT__u_csr__DOT__regs;
        const uint32_t cause = (priv == 3 ? regs[2] : regs[12]) & 0x7fffffffu;   // R_MCAUSE / R_SCAUSE
        if (!fm.interrupt(cyc, cause | 0x80000000u, priv, regs[4] | (1u << cause))) { compare_fail = 1; done = true; break; }   // R_MIP
        continue;
      }
      const uint32_t val = c.rd ? top->rootp->soc_top__DOT__u_core__DOT__u_back__DOT__u_prf__DOT__u_regfile__DOT__reg_file_q[c.preg] : 0u;
      if (!fm.commit(cyc, c.pc, c.rd, val)) { compare_fail = 1; done = true; break; }
    }
    fm_pend.clear();
  };
  if (fm_on) fm.init(uint32_t(RAM_SIZE), pmem_ram_ptr(), uint32_t(PMEM_SDRAM_SIZE), pmem_sdram_ptr());
  if (fm_on) fm.dut_mem = [](uint32_t a) { return pmem_read(a); };
  if (fm_on) for (size_t k = 0; k < stub_words.size(); ++k) refcpu_set_io_word(fm.ctx, uint32_t(4 * k), stub_words[k]);
#endif
  const bool fast_skip = kTicks >= 16 && std::getenv("SOC_TB_NOSKIP") == nullptr && !skipmask.empty();   // the idle-tick skip needs 16 ticks per cycle
  std::vector<uint8_t> snap(sizeof(*top->rootp));
  unsigned long long skipped_cycles = 0;
  auto ddr_idle = [&]() { return ddr.idle_quiescent(); };
long long eval_ns = 0, eval_n = 0, ev_ns[4] = {0}, ev_k = 0;
#define EVAL() do { auto e0 = std::chrono::steady_clock::now(); top->eval(); eval_ns += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - e0).count(); ev_ns[ev_k++ & 3] += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - e0).count(); ++eval_n; } while (0)
  uint32_t env_modeled_prev = 0, env_rdata_prev = 0;
  bool skip_request = false;
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
    EVAL();
    {   // peripheral environment: region decode + same-cycle read data (combinational inputs of peripheral_axi)
      auto *Rt = top->rootp;
      const uint32_t pa = Rt->soc_top__DOT__peripheral_req_mmio_addr;
      const uint8_t pf3 = Rt->soc_top__DOT__peripheral_req_mmio_fun3;
      top->env_modeled = PeripheralModel::is_modeled_mmio(pa) ? 1 : 0;
      top->env_rdata = top->env_rd_en ? periph.read_load(top->env_rd_addr, top->env_rd_func3) : 0;
      (void)pf3;
      if (top->env_modeled != env_modeled_prev || top->env_rdata != env_rdata_prev) EVAL();   // an eval with unchanged inputs is a no-op
      env_modeled_prev = top->env_modeled; env_rdata_prev = top->env_rdata;
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
#if defined(SOC_TB_DEBUG) && defined(SOC_LSU_PIPE)
    if (phase == 0 && top->rst_n && std::getenv("SOC_TB_LSUEVT")) {   // per-cycle LSU boundary events (same format as the model's LSU_PIPE_EVT)
      auto *R = top->rootp;
#define LSUP(n) R->soc_top__DOT__u_core__DOT__u_back__DOT__u_lsu__DOT__g_pipe__DOT__u_pipe__DOT__##n
      std::fprintf(stderr, "E t=%llu wb:", (unsigned long long)cycles + 1);
      for (int p = 0; p < LSU_LDU_COUNT; ++p) if (LSUP(lsu2exe_wb_req_valid) >> p & 1) std::fprintf(stderr, " %d=r%d/p%d/e%d/b%llx", p, (int)LSUP(lsu2exe_wb_req_uop_rob_idx)[p], (int)LSUP(lsu2exe_wb_req_uop_dest_preg)[p], (int)(LSUP(lsu2exe_wb_req_uop_dest_en) >> p & 1), (unsigned long long)LSUP(lsu2exe_wb_req_uop_br_mask)[p]),
        std::fprintf(stderr, "/v%x/d%x/f%d%d", (unsigned)LSUP(lsu2exe_wb_req_uop_result)[p], (unsigned)LSUP(lsu2exe_wb_req_uop_diag_val)[p],
                     (int)(LSUP(lsu2exe_wb_req_uop_page_fault_load) >> p & 1), (int)(LSUP(lsu2exe_wb_req_uop_page_fault_store) >> p & 1));
      std::fprintf(stderr, " sta:");
      for (int p = 0; p < LSU_STA_COUNT; ++p) if (LSUP(lsu2exe_sta_wb_req_valid) >> p & 1) std::fprintf(stderr, " %d=r%d/b%llx", p, (int)LSUP(lsu2exe_sta_wb_req_uop_rob_idx)[p], (unsigned long long)LSUP(lsu2exe_sta_wb_req_uop_br_mask)[p]),
        std::fprintf(stderr, "/v%x/d%x/f%d", (unsigned)LSUP(lsu2exe_sta_wb_req_uop_result)[p], (unsigned)LSUP(lsu2exe_sta_wb_req_uop_diag_val)[p],
                     (int)(LSUP(lsu2exe_sta_wb_req_uop_page_fault_store) >> p & 1));
      std::fprintf(stderr, " dl:");
      for (int p = 0; p < LSU_LDU_COUNT; ++p) if (LSUP(lsu2dcache_load_ports_valid)[p]) std::fprintf(stderr, " %d=%x/%x", p, (unsigned)LSUP(lsu2dcache_load_ports_addr)[p], (unsigned)LSUP(lsu2dcache_load_ports_req_id)[p]);
      std::fprintf(stderr, " ds:");
      for (int p = 0; p < LSU_STA_COUNT; ++p) if (LSUP(lsu2dcache_store_ports_valid)[p]) std::fprintf(stderr, " %d=%x/%d", p, (unsigned)LSUP(lsu2dcache_store_ports_addr)[p], (int)LSUP(lsu2dcache_store_ports_req_id)[p]);
      std::fprintf(stderr, " mmu:");
      for (int p = 0; p < LSU_LDU_COUNT; ++p) if (LSUP(lsu2mmu_ldq_req_valid) >> p & 1) std::fprintf(stderr, " L%d=%d", p, (int)LSUP(lsu2mmu_ldq_req_entry_idx)[p]);
      for (int p = 0; p < LSU_STA_COUNT; ++p) if (LSUP(lsu2mmu_stq_req_valid) >> p & 1) std::fprintf(stderr, " S%d=%d", p, (int)LSUP(lsu2mmu_stq_req_entry_idx)[p]);
      std::fprintf(stderr, " d: sf=%d lf=%d tl=%d/%d cp=%d", (int)LSUP(lsu2dis_stq_free), (int)LSUP(lsu2dis_ldq_free), (int)LSUP(lsu2dis_stq_tail),
                   (int)LSUP(lsu2dis_stq_tail_flag), (int)LSUP(lsu2rob_committed_store_pending));
      {
        unsigned dsa = 0, dla = 0;
        for (int i = 0; i < 8; i++) { dsa |= (unsigned)(LSUP(dis2lsu_alloc_req) >> i & 1) << i; dla |= (unsigned)(LSUP(dis2lsu_ldq_alloc_req) >> i & 1) << i; }
        std::fprintf(stderr, " b: mp=%d fl=%d cl=%llx dsa=%x dla=%x cm=%x", (int)LSUP(dec_bcast_mispred), (int)LSUP(rob_bcast_flush),
                     (unsigned long long)LSUP(dec_bcast_clear_mask), dsa, dla, (unsigned)LSUP(rob_commit_commit_entry_valid));
      }
      std::fprintf(stderr, " in:");
      for (int p = 0; p < LSU_LDU_COUNT; ++p) if (LSUP(mmu2lsu_ldq_resp_valid) >> p & 1) std::fprintf(stderr, " ml%d=%d/%x", p, (int)LSUP(mmu2lsu_ldq_resp_result)[p], (unsigned)LSUP(mmu2lsu_ldq_resp_paddr)[p]);
      for (int p = 0; p < LSU_STA_COUNT; ++p) if (LSUP(mmu2lsu_stq_resp_valid) >> p & 1) std::fprintf(stderr, " ms%d=%d/%x", p, (int)LSUP(mmu2lsu_stq_resp_result)[p], (unsigned)LSUP(mmu2lsu_stq_resp_paddr)[p]);
      for (int p = 0; p < LSU_LDU_COUNT; ++p) if (LSUP(dcache2lsu_load_resps_valid)[p]) std::fprintf(stderr, " dr%d=%x/%d", p, (unsigned)(LSUP(dcache2lsu_load_resps_req_id)[p] & 0x7fffffffu), (int)LSUP(dcache2lsu_load_resps_replay)[p]);
      for (int p = 0; p < LSU_STA_COUNT; ++p) if (LSUP(dcache2lsu_store_resps_valid)[p]) std::fprintf(stderr, " sr%d=%d/%d", p, (int)LSUP(dcache2lsu_store_resps_req_id)[p], (int)LSUP(dcache2lsu_store_resps_replay)[p]);
      if (LSUP(dcache2lsu_mshr_fill)) std::fprintf(stderr, " fill=%x", (unsigned)LSUP(dcache2lsu_mshr_fill_line));
      for (int p = 0; p < LSU_LDU_COUNT; ++p) if (LSUP(dcache2lsu_load_retry_busy)[p]) std::fprintf(stderr, " rb%d", p);
      for (int p = 0; p < LSU_STA_COUNT; ++p) if (LSUP(dcache2lsu_store_retry_busy)[p]) std::fprintf(stderr, " sb%d", p);
      std::fprintf(stderr, " ai:");
      for (int p = 0; p < 8; ++p) if (LSUP(lsu2dis_ldq_alloc_valid) >> p & 1) std::fprintf(stderr, " %d", (int)LSUP(lsu2dis_ldq_alloc_idx)[p]);
      std::fprintf(stderr, " x:");
      for (int p = 0; p < LSU_SDU_COUNT; ++p) if (top->rootp->soc_top__DOT__u_core__DOT__u_back__DOT__u_lsu__DOT__g_pipe__DOT__u_pipe__DOT__exe2lsu_sdu_req_valid >> p & 1)
        std::fprintf(stderr, " D%d=%d", p, (int)LSUP(exe2lsu_sdu_req_uop_stq_idx)[p]);
      for (int p = 0; p < LSU_STA_COUNT; ++p) if (LSUP(exe2lsu_sta_req_valid) >> p & 1) std::fprintf(stderr, " A%d=%d", p, (int)LSUP(exe2lsu_sta_req_uop_stq_idx)[p]);
      for (int p = 0; p < LSU_LDU_COUNT; ++p) if (LSUP(exe2lsu_ldu_req_valid) >> p & 1) std::fprintf(stderr, " G%d=%d", p, (int)LSUP(exe2lsu_ldu_req_uop_ldq_idx)[p]);
      if (const char *si = std::getenv("SOC_TB_STQ")) {
        const auto &fld = R->soc_top__DOT__u_core__DOT__u_back__DOT__u_lsu__DOT__g_pipe__DOT__u_pipe__DOT__u_core__DOT__sq[std::atoi(si)];
        auto bit = [&](int k) { return (int)((fld[k / 32] >> (k % 32)) & 1u); };
        constexpr int kBase = 3 + 2 + 64 + 1 + 7 + 7 + 3 + 32 + 32 + 32;  // = done bit (LSB first: rwait rtype br rob_flag rob_idx dest func3 data paddr vaddr)
        std::fprintf(stderr, " Q[%s]: va=%d pa=%d dv=%d pf=%d wbp=%d wbd=%d cmt=%d iss=%d done=%d", si, bit(kBase + 14), bit(kBase + 13), bit(kBase + 12), bit(kBase + 11), bit(kBase + 5), bit(kBase + 4), bit(kBase + 3), bit(kBase + 2), bit(kBase));
      }
      std::fprintf(stderr, "\n");
    }
#endif
    if (phase == 0 && top->rst_n) {   // the CPU acts in tick 0: look at the retirement stream before the edge
#ifdef SOC_TB_FM
      if (fm_on && !fm_pend.empty()) fm_flush(cycles);   // commits of the previous cycle: their register values are visible now
#endif
      {  // PMU event bus (EXP-013 tier 1): sum every lane; printed at the end, compared with the trace-model's PMU=1 totals
        const auto &bus = top->rootp->soc_top__DOT__u_core__DOT__pmu_ev_inc;
        for (int e = 0; e < kPmuEv; ++e) {
          uint32_t v = 0;
          for (int b = 0; b < 8; ++b) { const int bit = e * 8 + b; v |= ((bus[bit / 32] >> (bit % 32)) & 1u) << b; }
          pmu_total[e] += v;
        }
      }
      for (int i = 0; i < 8; ++i)
        if (ttg_getbit(top->rob_commit_commit_entry_valid, i)) {
          if (!top->rootp->soc_top__DOT__u_core__DOT__u_back__DOT__rob_bcast_interrupt) ++committed;   // reference: commit_num skips interrupt slots
#ifdef SOC_TB_FM
          if (fm_on && !done && top->rootp->soc_top__DOT__u_core__DOT__u_back__DOT__rob_bcast_interrupt) fm_pend.push_back({0, 0, 0, true});
          else if (fm_on && !done && (top->rob_commit_commit_entry_uop_type[i] != kUopEbreak ||
                                      (semihost && pmem_read(top->ftq_commit_info_resp_pc[i] - 4) == 0x01f01013u && pmem_read(top->ftq_commit_info_resp_pc[i] + 4) == 0x40705013u))) {   // the semihosting marker ebreak is a breakpoint exception: the function model executes it too
            const bool de = ttg_getbit(top->rob_commit_commit_entry_uop_dest_en, i);
            fm_pend.push_back({top->ftq_commit_info_resp_pc[i], (de && top->rob_commit_commit_entry_uop_dest_areg[i] < 32) ? top->rob_commit_commit_entry_uop_dest_areg[i] : 0u,   // areg 32 = AMO with rd == x0 (pseudo destination)
                               
                               top->rootp->soc_top__DOT__u_core__DOT__u_back__DOT__u_rob__DOT__rob_commit_commit_entry_uop_dest_preg[i], false});
          }
#endif
          if (std::getenv("SOC_TB_COMMIT")) std::fprintf(stderr, "[cyc %llu] commit[%d] type=%d pc=%08x\n", (unsigned long long)cycles + 1, i,
                                                         top->rob_commit_commit_entry_uop_type[i], top->ftq_commit_info_resp_pc[i]);
          if (top->rob_commit_commit_entry_uop_type[i] == kUopEbreak) {
            // SOC_TB_SEMIHOST: the ebreak of the semihosting marker sequence (slli x0,x0,0x1f; ebreak; srai x0,x0,7) is a breakpoint
            // exception for the core (RTL built with TTG_EBREAK_TRAP), not the end of the program; same rule as the function model.
            const uint32_t epc = top->ftq_commit_info_resp_pc[i];
            const bool marker = semihost && pmem_read(epc - 4) == 0x01f01013u && pmem_read(epc + 4) == 0x40705013u;
            if (!marker) done = true;
          }
          // SimCpu::commit_sync: a committing store applies its device effect (PeripheralModel::on_commit_store) from the STQ entry
          if (top->rob_commit_commit_entry_uop_type[i] == kInstStore && !ttg_getbit(top->rob_commit_commit_entry_uop_page_fault_store, i)) {
#ifdef SOC_LSU_PIPE
            // lp_pkg::lp_stq_t (packed, first field = MSB): va_v pa_v data_v pf mmio lrsc sc_pass suppress trp wbp wbd cmt iss mmw done
            // vaddr paddr data func3 dest_preg rob_idx rob_flag br_mask rtype[2] rwait[3]
            const auto &fld = top->rootp->soc_top__DOT__u_core__DOT__u_back__DOT__u_lsu__DOT__g_pipe__DOT__u_pipe__DOT__u_core__DOT__sq[top->rob_commit_commit_entry_uop_stq_idx[i]];
            auto bits = [&](int lo, int w) { uint64_t v = 0; for (int b = 0; b < w; ++b) { int k = lo + b; v |= uint64_t((fld[k / 32] >> (k % 32)) & 1u) << b; } return uint32_t(v); };
            constexpr int kRtype = 3, kBr = kRtype + 2, kRobFlag = kBr + kCfg_BR_MASK_WIDTH, kRobIdx = kRobFlag + 1, kDest = kRobIdx + kCfg_ROB_IDX_WIDTH,
                          kFunc3 = kDest + kCfg_PRF_IDX_WIDTH, kData = kFunc3 + 3, kPaddr = kData + 32, kVaddr = kPaddr + 32, kDone = kVaddr + 32;
            // flags above done (LSB first): done mmw iss cmt wbd wbp trp suppress sc_pass lrsc mmio pf data_v pa_v va_v
            constexpr int kSuppress = kDone + 7, kDataV = kDone + 12, kPaV = kDone + 13;
            if (!bits(kSuppress, 1) && bits(kPaV, 1) && bits(kDataV, 1)) periph.on_commit_store(bits(kPaddr, 32), bits(kData, 32), uint8_t(bits(kFunc3, 3)));
#else
            const auto &fld = top->rootp->soc_top__DOT__u_core__DOT__u_back__DOT__u_lsu__DOT__g_legacy__DOT__u_core__DOT__st_fld_q[top->rob_commit_commit_entry_uop_stq_idx[i]];
            auto bits = [&](int lo, int w) { uint64_t v = 0; for (int b = 0; b < w; ++b) { int k = lo + b; v |= uint64_t((fld[k / 32] >> (k % 32)) & 1u) << b; } return uint32_t(v); };
            // lsu_pkg::stq_fld_t from the LSB: sc_pass lrsc mmio suppress pf paddr_valid data_valid replay[2] br_mask rob_flag rob_idx dest func3[3] paddr vaddr data
            constexpr int kFunc3 = 9 + kCfg_BR_MASK_WIDTH + 1 + kCfg_ROB_IDX_WIDTH + kCfg_PRF_IDX_WIDTH, kPaddr = kFunc3 + 3, kData = kPaddr + 64;
            if (!bits(3, 1) && bits(5, 1) && bits(6, 1)) periph.on_commit_store(bits(kPaddr, 32), bits(kData, 32), uint8_t(bits(kFunc3, 3)));
#endif
          }
        }
    }
#ifdef SOC_TB_DEBUG
    if (std::getenv("SOC_TB_TICK") && cycles + 1 >= std::strtoull(std::getenv("SOC_TB_TICK"), nullptr, 0)) {
      auto *R = top->rootp;
      std::fprintf(stderr, "  t%02d dcin_ld_v3=%d icache_req=%d | dc_ld_resp_v3=%d retry3=%d | route: ic_resp_v=%d miss=%d\n", phase,
        R->soc_top__DOT__u_mem__DOT__dc_ld_valid_in[3], R->soc_top__DOT__u_mem__DOT__dc_icache_req,
        R->soc_top__DOT__u_mem__DOT__dc_ld_resp_valid[3], R->soc_top__DOT__u_mem__DOT__dc_ld_resp_retry[3],
        R->soc_top__DOT__dc_resp_valid, R->soc_top__DOT__dc_resp_miss);
    }
#endif
    if (fast_skip && (phase == 2 || phase == 3) && top->rst_n) {
      // pre-edge state (inputs applied, comb settled) of tick 2 vs tick 3: equal and DDR idle => the whole cycle is a fixed point
      if (phase == 2) {
        for (const auto &k : keep) std::memcpy(snap.data() + k.first, reinterpret_cast<const uint8_t *>(top->rootp) + k.first, k.second);
      } else if (ddr_idle()) {
        bool same = true;
        for (const auto &k : keep)
          if (std::memcmp(snap.data() + k.first, reinterpret_cast<const uint8_t *>(top->rootp) + k.first, k.second)) { same = false; break; }
        if (!same && std::getenv("SOC_TB_IDLEDBG") && cycles >= 2000 && cycles < 2040) {   // debug: where does the state still change?
          int n = 0;
          for (const auto &k : keep)
            for (size_t i = 0; i < k.second && n < 8; ++i)
              if (snap[k.first + i] != reinterpret_cast<const uint8_t *>(top->rootp)[k.first + i]) { std::fprintf(stderr, "cyc %llu diff at byte %zu\n", (unsigned long long)cycles, k.first + i); ++n; }
        }
        if (same) {   // ticks 4..14 are skipped: this tick's edge must load phase 15 (state is a fixed point, so the edge is otherwise a no-op)
          top->rootp->soc_top__DOT__u_mem__DOT__phase_q = 14;
          skip_request = true;
        }
      }
    }
    if (top->rst_n) ddr.seq();   // the DDR model (and DRAMsim3's clock) starts with the first cycle after reset, like the trace-model
    top->clk = 1;
    if (phase == 0) top->clk_cpu = 1;
    EVAL();
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
    if (std::getenv("SOC_TB_NOOP") && phase == 5 && cycles == 1000) {   // probe: cost of eval() with nothing changed
      for (int k = 0; k < 3; ++k) {
        auto e0 = std::chrono::steady_clock::now(); top->eval();
        std::fprintf(stderr, "noop eval after edge, #%d: %.1f us\n", k, std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - e0).count() / 1000.0);
      }
    }
    // no eval here: the falling clock edge and the new inputs are evaluated together by the next tick's first eval
    ++ticks;
  };

  // reset: 3 CPU cycles
  top->rst_n = 0; top->clk = 0; top->clk_cpu = 0;
  top->interrupt_inject_external_irq_pending = 0; top->interrupt_inject_external_irq_pending_valid = 1;
  top->interrupt_inject_supervisor_external_irq_pending = 0; top->interrupt_inject_supervisor_external_irq_pending_valid = 1;
  top->interrupt_inject_timer_irq_pending = 0; top->interrupt_inject_timer_irq_pending_valid = 1;
  top->env_modeled = 0; top->env_rdata = 0;
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
      auto t0 = std::chrono::steady_clock::now();
      tick(p);
      prof_ns[p] += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t0).count(); ++prof_n[p];
      if (p == 0 && done) break;
      if (skip_request) {   // tick 3 ran with the phase jump armed: its edge loaded phase 15
        skip_request = false; p = 14; ++skipped_cycles;
      }
    }
    ++cycles;
  }
  if (compare_fail) std::printf("FIRST MISMATCH at cycle %llu (see above)\n", (unsigned long long)cycles + 1);
  if (std::getenv("SOC_TB_PMU")) for (int e = 0; e < kPmuEv; ++e) std::printf("PMU_EV %d %llu\n", e, (unsigned long long)pmu_total[e]);
  std::printf("RTL sim-time(cycle)= %llu, committed= %llu%s\n", (unsigned long long)cycles, (unsigned long long)committed,
              done ? "" : "  (NO EBREAK within the cycle cap)");
  if (std::getenv("SOC_TB_PROF")) std::fprintf(stderr, "eval: n=%lld total=%.2f s  by-index(ns/eval): %.0f %.0f %.0f %.0f\n", eval_n, eval_ns / 1e9, ev_ns[0]*4.0/eval_n, ev_ns[1]*4.0/eval_n, ev_ns[2]*4.0/eval_n, ev_ns[3]*4.0/eval_n);
  if (std::getenv("SOC_TB_PROF")) for (int i = 0; i < 16; ++i) if (prof_n[i]) std::fprintf(stderr, "tick %2d: n=%lld avg=%.1f us\n", i, prof_n[i], prof_ns[i] / 1000.0 / prof_n[i]);
#ifdef SOC_TB_FM
  if (fm_on) { fm_flush(cycles); std::fprintf(stderr, "[FM] %llu instructions checked against the function model (%llu device/counter values adopted, %llu interrupts)%s\n", (unsigned long long)fm.steps, (unsigned long long)fm.synced_io, (unsigned long long)fm.irqs, fm.failed ? "  ** MISMATCH **" : ""); }
#endif
  if (std::getenv("SOC_TB_NOSKIP") == nullptr) std::fprintf(stderr, "idle-skipped cycles: %llu of %llu\n", skipped_cycles, (unsigned long long)cycles);
  delete top;
  return compare_fail ? 3 : (done ? 0 : 1);
}
