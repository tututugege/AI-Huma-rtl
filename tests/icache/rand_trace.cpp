// Constrained-random trace generator for icache: drives the *reference* icache (icache_peek_ready / icache_comb_calc of front-end/icache/, including the
// real TlbMmu ITLB) exactly the way front_top.cpp S2/S6/S12 does (peek; main call; a second call with invalidate_req in a predecode-flush cycle),
// with mock environments behind the ports and writes a trace of spec/icache.io (the values the second recording tap / the front-end would see).
//
// Environment models (what the SoC can legally produce; the reference has no input assertions):
//  * AXI read master port (ready-first contract as observed in real runs): `ready` random each cycle; a request that was on the port with ready=1 is
//    accepted one cycle later (accepted pulse + accepted_id); with probability p_late the commit is decided on the request as it was BEFORE a predecode
//    flush withdrew it (the CANCEL_WAIT_ACCEPT path).  Response after a random latency 0..8 (0 = same cycle as the accepted pulse), held until the I-cache
//    raises resp.ready; id = request id; responses of abandoned requests still arrive (canceled path); rare unprompted "orphan" responses (id not in flight).
//    Line contents = hash(address, epoch of the line); the epoch of random lines is bumped at random (self-modifying code makes memory and DCache differ).
//  * DCache word probe: one response per probe request (the next cycle + 0..2), retry / miss / hit(+data, usually the current memory word); rare spurious
//    responses (ignored by the I-cache unless a probe is in flight).
//  * PTW walk client (MockPort, same semantics as MemSubsystemPtwWalkPortAdapter) over a random Sv32 page table (tests/tlb_mmu/rand_trace.cpp).
//  * Front-end: a fetch is presented only when the peeked icache_ready is 1 and no refetch is active (fetch_addr FIFO read enable); refetch random;
//    itlb_flush and fence_i only together with refetch (SFENCE.VMA / FENCE.I flush the pipe in BackTop); predecode flush (invalidate) only without
//    refetch and is followed by a refetch in the next cycle (predecode_refetch).  satp / privilege / mstatus change at random.
// Build/run: tests/icache/run_rand.sh.   args: out.trc seed cycles [mode]   mode: 0 default; 1 = also fence_i / itlb_flush without refetch is NOT generated
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>
#define private public
#define protected public
#include "TlbMmu.h"
#include "FrontTop.h"
#include "front_IO.h"
#include "front_tap.h"
#include "AXI_Interconnect_IO.h"
#include "PtwWalkPort.h"
#undef private
#undef protected
#include "icache_fields.h"
using namespace ttg_io;

long long sim_time = 0;
bool g_ttg_front_tap_on = true;
FrontIcTap g_ttg_ic_tap;
uint32_t pmem_read(uint32_t) { return 0; }

void icache_comb_calc(struct icache_in *in, struct icache_out *out);
void icache_peek_ready(struct icache_in *in, struct icache_out *out);
void icache_set_context(SimContext *ctx);
extern PtwWalkPort *icache_ptw_walk_port;
extern ICacheMemPortReq *icache_mem_req_port;
extern ICacheMemPortResp *icache_mem_resp_port;
extern axi_interconnect::ReadMasterPort_t *icache_mem_read_port;
extern PtwMemPort *icache_ptw_mem_port;

static ttg::TraceWriter<decltype(kFields)> *tw;
static std::map<std::string, int> ids;
static void S(const std::string &n, int e, uint64_t v) { tw->set(ids.at(n), e, v); }

struct MockPort : PtwWalkPort {
  PtwWalkPortCombIn in{};
  PtwWalkPortSeqIn sq{};
  PtwWalkPortCombOut out{};
  bool send_walk_req(const PtwWalkReq &r) override {
    if (!out.req_ready || in.req_valid) return false;
    in.req_valid = true; in.req = r; out.req_ready = false; out.resp_valid = false; out.resp = {};
    return true;
  }
  bool resp_valid() const override { return out.resp_valid; }
  PtwWalkResp resp() const override { return out.resp; }
  PtwWalkPortCombOut comb_output() const override { return out; }
  void consume_resp() override { in.resp_consumed = true; out.resp_valid = false; out.resp = {}; }
  void flush_client() override { sq.flush = true; out.req_ready = true; out.resp_valid = false; out.resp = {}; }
};

static std::mt19937_64 rng;
static int R(int n) { return (int)(rng() % n); }
static bool P(int pct) { return R(100) < pct; }
static bool PM(int pm) { return R(1000) < pm; }

// ---- Sv32 page tables (as tests/tlb_mmu/rand_trace.cpp) ----
static std::unordered_map<uint32_t, uint32_t> mem;
static const int NSPACE = 3, NV1 = 6, NV0 = 32;
static uint32_t root_ppn(int s) { return 0x200 + 0x10 * s; }
static uint32_t l2_ppn(int s, int v1) { return 0x400 + 0x40 * s + 4 * v1; }
static uint32_t flags_random() {
  uint32_t f = 1;
  if (P(80)) f |= 2; if (P(50)) f |= 4; if (P(70)) f |= 8; if (P(60)) f |= 16; if (P(15)) f |= 32; if (P(90)) f |= 64; if (P(60)) f |= 128;
  return f | ((uint32_t)R(4) << 8);
}
static uint32_t rnd_ppn() { return P(75) ? (0x80000u + R(0x400)) : (uint32_t)R(0x100000); }  // mostly cacheable RAM, some low (uncached) pages
static uint32_t pte_l1(int s, int v1) {
  int k = R(100);
  if (k < 60) return (l2_ppn(s, v1) << 10) | 1u;
  if (k < 75) return ((rnd_ppn() & 0xFFC00u) << 10) | flags_random() | 2 | 8;
  if (k < 85) return flags_random() & ~1u;
  return (rnd_ppn() << 10) | 1u;
}
static uint32_t pte_l2() {
  int k = R(100);
  if (k < 80) return (rnd_ppn() << 10) | flags_random() | 8 | 2;
  if (k < 90) return flags_random() & ~1u;
  return (rnd_ppn() << 10) | 1u;
}
static void build_tables() {
  for (int s = 0; s < NSPACE; s++)
    for (int v1 = 0; v1 < NV1; v1++) {
      mem[(root_ppn(s) << 10) + v1] = pte_l1(s, v1);
      for (int v0 = 0; v0 < NV0; v0++) mem[(l2_ppn(s, v1) << 10) + v0] = pte_l2();
    }
}
static void mutate_tables() {
  int s = R(NSPACE), v1 = R(NV1);
  if (P(30)) mem[(root_ppn(s) << 10) + v1] = pte_l1(s, v1);
  else mem[(l2_ppn(s, v1) << 10) + R(NV0)] = pte_l2();
}
static uint32_t rd(uint32_t paddr) { auto it = mem.find(paddr >> 2); return it == mem.end() ? 0 : it->second; }
static PtwWalkResp walk(uint32_t vaddr, uint32_t satp) {
  PtwWalkResp r; r.vaddr = vaddr; r.fault = true; r.leaf_pte = 0; r.leaf_level = 0;
  uint32_t root = satp & 0x3FFFFF, v1 = (vaddr >> 22) & 0x3FF, v0 = (vaddr >> 12) & 0x3FF;
  uint32_t pte = rd((root << 12) + (v1 << 2));
  bool v = pte & 1, rr = pte & 2, w = pte & 4, x = pte & 8;
  if (!v || (!rr && w)) return r;
  if (rr || x) { if (((pte >> 10) & 0x3FF) != 0) return r; r.fault = false; r.leaf_pte = pte; r.leaf_level = 1; return r; }
  uint32_t ppn = (pte >> 10) & 0x3FFFFF;
  pte = rd((ppn << 12) + (v0 << 2));
  v = pte & 1; rr = pte & 2; w = pte & 4; x = pte & 8;
  if (!v || (!rr && w) || !(rr || x)) return r;
  r.fault = false; r.leaf_pte = pte; r.leaf_level = 0;
  return r;
}

// ---- instruction memory model ----
static uint32_t epoch[1 << 14];
static uint32_t memword(uint32_t paddr) {
  uint64_t h = (uint64_t)(paddr >> 2) * 0x9E3779B97F4A7C15ull ^ ((uint64_t)epoch[(paddr >> 6) & 0x3FFF] * 0xD6E8FEB86659FD93ull);
  h ^= h >> 29; h *= 0xBF58476D1CE4E5B9ull; h ^= h >> 32;
  return (uint32_t)h;
}

struct MemResp { int id; uint32_t addr; bool bypass; long ready; };
struct DcResp { long ready; bool retry, miss; uint32_t data; };

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "rand.trc";
  uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
  int ncyc = argc > 3 ? atoi(argv[3]) : 100000;
  for (int i = 0; i < (int)kNumFields; i++) ids[kFields[i].name] = i;
  static ttg::TraceWriter<decltype(kFields)> w(out, kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  tw = &w;
  rng.seed(seed);

  SimContext ctx;
  icache_set_context(&ctx);
  static MockPort ptw;
  static axi_interconnect::ReadMasterPort_t axi;
  static ICacheMemPortReq dcreq;
  static ICacheMemPortResp dcresp;
  icache_ptw_walk_port = &ptw; icache_mem_read_port = &axi; icache_mem_req_port = &dcreq; icache_mem_resp_port = &dcresp;
  CsrStatusIO csr;
  build_tables();

  // init call, as FrontTop::init() does (reset): the ITLB flush of the reset call stays on the PTW port in cycle 1
  { struct icache_in in; struct icache_out o; memset(&in, 0, sizeof in); memset(&o, 0, sizeof o);
    in.reset = true; in.csr_status = &csr; g_ttg_ic_tap = FrontIcTap{}; icache_comb_calc(&in, &o); }
  for (int k = 0; k < 3; k++) w.commit(0, ttg::kFlagReset);

  uint32_t satps[5] = {0, (1u << 31) | (1u << 22) | root_ppn(0), (1u << 31) | (2u << 22) | root_ppn(1),
                       (1u << 31) | (1u << 22) | root_ppn(2), (1u << 31) | root_ppn(0)};
  uint32_t satp = 0, privilege = 3, mxr = 0, sum = 0, mprv = 0, mpp = 1;
  int p_req = 70, p_refetch = 2, p_inv = 3, p_itlb_flush = 20, p_fence_i = 10, p_ready = 60, p_late = 30, p_probe_hit = 60, hot_lines = 600;
  bool force_refetch = false;
  // AXI model state
  std::deque<MemResp> mresp; bool commit_pulse = false; int commit_id = 0; bool prev_v = false, prev_ready = false; int prev_id = 0;
  std::deque<DcResp> dresp;
  bool pend = false; int lat = 0; PtwWalkResp pend_resp; bool rv = false; PtwWalkResp rresp;
  long st[16] = {};

  for (int c = 0; c < ncyc; c++) {
    sim_time = c + 1;
    if (c % 3000 == 0) {
      static const int pr[] = {10, 40, 90}, pre[] = {0, 1, 3, 8}, pi[] = {0, 2, 6, 20}, pl[] = {0, 30, 90}, pph[] = {10, 60, 100}, hl[] = {40, 300, 700, 2000};
      p_req = pr[R(3)]; p_refetch = pre[R(4)]; p_inv = pi[R(4)]; p_late = pl[R(3)]; p_probe_hit = pph[R(3)]; hot_lines = hl[R(4)];
      p_ready = P(30) ? 20 : 70;
      if (P(20)) build_tables();
    }
    if (PM(3)) mutate_tables();
    if (PM(6)) satp = P(35) ? 0 : satps[1 + R(4)];
    if (PM(10)) { static const int pv_[4] = {0, 1, 3, 3}; privilege = pv_[R(4)]; }
    if (PM(10)) { mxr = R(2); sum = R(2); mprv = R(2); mpp = P(50) ? 3 : R(2); }
    if (PM(15)) epoch[R(1 << 14)]++;
    csr.satp = satp; csr.privilege = privilege; csr.mstatus = (mxr << 19) | (sum << 18) | (mprv << 17) | (mpp << 11);

    // ---- front-end control ----
    bool refetch = force_refetch || PM(p_refetch * 10);
    force_refetch = false;
    bool itlb_flush = refetch && P(p_itlb_flush) && PM(100), fence_i = refetch && P(p_fence_i) && PM(200);
    if (refetch && PM(30)) { itlb_flush |= P(50); }
    bool invalidate = !refetch && PM(p_inv * 10);

    // ---- environment inputs ----
    axi.req.ready = P(p_ready);
    axi.req.accepted = commit_pulse; axi.req.accepted_id = commit_id;
    axi.resp.valid = false; axi.resp.id = 0;
    for (int i = 0; i < 16; i++) axi.resp.data[i] = 0;
    long cur = c;
    int head = -1;
    for (size_t i = 0; i < mresp.size(); i++) if (mresp[i].ready <= cur) { head = (int)i; break; }
    bool orphan = false; MemResp orph{};
    if (head >= 0) {
      MemResp &m = mresp[head]; axi.resp.valid = true; axi.resp.id = m.id;
      if (m.bypass) axi.resp.data[0] = memword(m.addr);
      else for (int i = 0; i < 16; i++) axi.resp.data[i] = memword((m.addr & ~63u) + 4 * i);
    } else if (PM(4)) {
      orphan = true; orph.id = R(16); axi.resp.valid = true; axi.resp.id = orph.id;
      for (int i = 0; i < 16; i++) axi.resp.data[i] = (uint32_t)rng();
    }
    dcresp = ICacheMemPortResp{}; dcresp.resp_miss = true;
    bool dc_pop = false;
    if (!dresp.empty() && dresp.front().ready <= cur) {
      dc_pop = true; dcresp.resp_valid = true; dcresp.resp_retry = dresp.front().retry; dcresp.resp_miss = dresp.front().miss; dcresp.resp_data = dresp.front().data;
    } else if (PM(5)) { dcresp.resp_valid = true; dcresp.resp_retry = P(30); dcresp.resp_miss = P(50); dcresp.resp_data = (uint32_t)rng(); }
    if (c > 0) { ptw.in = {}; ptw.sq = {}; }
    ptw.out.req_ready = !pend; ptw.out.resp_valid = rv; ptw.out.resp = rv ? rresp : PtwWalkResp{};

    // ---- peek, fetch request, main call ----
    struct icache_in in; struct icache_out o;
    memset(&in, 0, sizeof in); memset(&o, 0, sizeof o);
    in.refetch = refetch; in.itlb_flush = itlb_flush; in.fence_i = fence_i; in.csr_status = &csr;
    icache_peek_ready(&in, &o);
    bool ready_peek = o.icache_read_ready;
    bool req_valid = ready_peek && !refetch && P(p_req);
    uint32_t fa = 0;
    if (req_valid) {
      if (satp == 0 || privilege == 3) {
        if (P(10)) fa = 0x100 + 4 * R(2000);                                  // uncached low region
        else fa = 0x80000000u + 64u * R(hot_lines) + 4u * R(16);
        if (P(20)) fa = 0x80000000u + 64u * R(8) + 4u * R(16);              // hot set (repeat hits)
      } else {
        int pg = R(NV1 * NV0 / (P(50) ? 8 : 1)); uint32_t v1 = (pg / NV0) % NV1, v0 = pg % NV0;
        if (PM(60)) v1 = R(1024);
        fa = (v1 << 22) | (v0 << 12) | (uint32_t)(64 * R(P(60) ? 4 : 64) + 4 * R(16));
      }
    }
    in.icache_read_valid = req_valid; in.fetch_address = fa;
    g_ttg_ic_tap = FrontIcTap{};
    icache_comb_calc(&in, &o);
    struct icache_out o1 = o;
    if (invalidate) {
      struct icache_in in2; memset(&in2, 0, sizeof in2); in2.invalidate_req = true; in2.csr_status = &csr;
      icache_comb_calc(&in2, &o);
      force_refetch = true;
    }
    const FrontIcTap &T = g_ttg_ic_tap;

    // ---- record ----
    S("refetch", 0, refetch); S("itlb_flush", 0, itlb_flush); S("fence_i", 0, fence_i); S("invalidate", 0, invalidate);
    S("req_valid", 0, req_valid); S("fetch_address", 0, fa);
    S("csr_status_satp", 0, satp); S("csr_status_privilege", 0, privilege); S("csr_status_mstatus_mxr", 0, mxr);
    S("csr_status_mstatus_sum", 0, sum); S("csr_status_mstatus_mprv", 0, mprv); S("csr_status_mstatus_mpp", 0, mpp);
    S("mem_req_ready", 0, T.mem_req_ready); S("mem_req_accepted", 0, T.mem_req_accepted); S("mem_req_accepted_id", 0, T.mem_req_accepted_id);
    S("mem_resp_valid", 0, T.mem_resp_valid); S("mem_resp_id", 0, T.mem_resp_id);
    for (int i = 0; i < 16; i++) S("mem_resp_data", i, T.mem_resp_data[i]);
    S("dc_resp_valid", 0, T.dc_resp_valid); S("dc_resp_retry", 0, T.dc_resp_retry); S("dc_resp_miss", 0, T.dc_resp_miss);
    S("dc_resp_data", 0, T.dc_resp_data);
    S("ptw_walk_req_ready", 0, T.ptw_req_ready); S("ptw_walk_resp_valid", 0, T.ptw_resp_valid); S("ptw_walk_resp_fault", 0, T.ptw_resp_fault);
    S("ptw_walk_resp_vpn", 0, T.ptw_resp_vaddr >> 12); S("ptw_walk_resp_leaf_ppn", 0, (T.ptw_resp_leaf_pte >> 10) & 0xFFFFF);
    S("ptw_walk_resp_leaf_perm", 0, T.ptw_resp_leaf_pte & 0xFF); S("ptw_walk_resp_leaf_level", 0, T.ptw_resp_leaf_level & 1);
    S("icache_ready", 0, ready_peek); S("read_complete", 0, o1.icache_read_complete); S("fetch_pc", 0, o1.fetch_pc);
    for (int i = 0; i < 8; i++) {
      S("inst_valid", i, o1.inst_valid[i]); S("page_fault_inst", i, o1.page_fault_inst[i]); S("fetch_group", i, o1.fetch_group[i]);
    }
    S("mem_req_valid", 0, T.mem_req_valid); S("mem_req_addr", 0, T.mem_req_addr); S("mem_req_total_size", 0, T.mem_req_total_size);
    S("mem_req_bypass", 0, T.mem_req_bypass); S("mem_req_id", 0, T.mem_req_id); S("mem_resp_ready", 0, T.mem_resp_ready);
    S("dc_req_valid", 0, T.dc_req_valid); S("dc_req_addr", 0, T.dc_req_addr);
    S("ptw_walk_req_valid", 0, T.ptw_req_valid); S("ptw_walk_req_vpn", 0, T.ptw_req_vaddr >> 12);
    S("ptw_walk_req_root_ppn", 0, T.ptw_req_satp & 0x3FFFFF); S("ptw_walk_resp_consumed", 0, T.ptw_resp_consumed);
    S("ptw_walk_flush", 0, T.ptw_flush);
    w.commit(c);

    // ---- statistics ----
    st[0] += invalidate; st[1] += invalidate && T.step[0].regs_next.state != 0; st[2] += T.step[0].o_resp_valid; st[3] += T.mem_req_valid;
    st[4] += refetch && T.step[0].regs_before.state == 1; st[5] += T.mem_resp_valid && !orphan && head < 0; st[6] += T.dc_req_valid;
    st[7] += T.ptw_req_valid; st[8] += T.itlb_translate_invoked && T.itlb_result == 1; st[9] += T.step[0].o_page_fault && T.step[0].o_resp_valid;
    st[10] += T.step[0].tw_we; st[11] += fence_i; st[12] += itlb_flush; st[13] += invalidate && T.step[0].regs_next.state == 1;
    st[14] += T.mem_resp_ready && orphan;

    // ---- environment update (seq) ----
    // AXI: response pop / request commit
    if (T.mem_resp_ready && T.mem_resp_valid) { if (head >= 0) mresp.erase(mresp.begin() + head); }
    bool v_final = T.mem_req_valid, v_first = T.step[0].o_mem_req_valid;
    commit_pulse = false;
    if (axi.req.ready && (v_final || (v_first && P(p_late)))) {
      commit_pulse = true; commit_id = v_final ? T.mem_req_id : T.step[0].o_mem_req_id;
      uint32_t addr = v_final ? T.mem_req_addr : T.step[0].o_mem_req_addr; bool byp = v_final ? T.mem_req_bypass : T.step[0].o_mem_req_bypass;
      mresp.push_back({commit_id, addr, byp, c + 1 + R(P(30) ? 1 : 9)});
    }
    (void)prev_v; (void)prev_ready; (void)prev_id;
    if (dc_pop) dresp.pop_front();
    if (T.dc_req_valid) {
      DcResp d; d.ready = c + 1 + R(3); int k = R(100);
      d.retry = k < 15; d.miss = !d.retry && k >= 15 + p_probe_hit * 85 / 100; d.data = P(85) ? memword(T.dc_req_addr) : (uint32_t)rng();
      dresp.push_back(d);
    }
    // PTW
    if (ptw.in.resp_consumed) rv = false;
    if (ptw.in.req_valid) { rv = false; pend = true; lat = R(7); pend_resp = walk(ptw.in.req.vaddr, ptw.in.req.satp); }
    if (ptw.sq.flush) { pend = false; rv = false; }
    else if (pend) { if (lat-- <= 0) { pend = false; rv = true; rresp = pend_resp; } }
  }
  fprintf(stderr, "%s: cycles=%d invalidate=%ld inv&&R1!=IDLE=%ld inv&&R1==SWAP_IN=%ld resp=%ld mem_req=%ld refetch_in_swap=%ld dc_req=%ld ptw_req=%ld itlb_fault=%ld "
          "pf_resp=%ld table_wr=%ld fence_i=%ld itlb_flush=%ld orphan_ready=%ld\n", out, ncyc, st[0], st[1], st[13], st[2], st[3], st[4], st[6], st[7], st[8], st[9], st[10], st[11], st[12], st[14]);
  return 0;
}
