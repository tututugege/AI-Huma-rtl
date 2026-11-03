// Constrained-random trace generator for tlb_mmu: drives the *reference* TlbMmu class (Kind::DTLB, back-end/Lsu/TlbMmu.cpp) exactly
// the way BackTop::comb_lsu_mmu() does (fence -> flush(); flush||mispred -> cancel_pending_walk(); else translate_lsu_ports(); then seq()),
// with a mock page-table walker behind the PtwWalkPort (same port semantics as MemSubsystemPtwWalkPortAdapter + MemPtwBlock walk client:
// req_ready = no request outstanding, response held until consumed / new request / flush, fault response = {fault, vaddr}, leaf response
// = raw PTE + level, PTE checks as in MemPtwBlock::on_walk_mem_resp) over a small random Sv32 page-table memory.
//
// Why this is legal stimulus (the reference has no input assertions; the point is to stay within what the SoC can produce):
//  * LSU side: 8 request ports (4 load, 4 store), arbitrary 32-bit vaddrs, a request that got MISS is retried (as the LSU does);
//    entry_idx / wait_idx are opaque tags echoed back.
//  * CSR side: satp from a small pool (bare, and Sv32 with 3 address spaces incl. same ASID for different roots), privilege in {U,S,M},
//    MXR/SUM/MPRV/MPP arbitrary (MPP in {U,S,M}), changing at arbitrary cycles.
//  * control: fence (SFENCE.VMA) / flush / mispredict at arbitrary cycles, also together (fence wins, as in comb_lsu_mmu).
//  * page tables: random valid / invalid / !R&W / misaligned-megapage / pointer-at-leaf-level PTEs; PTEs are re-written mid-run WITHOUT a
//    fence (legal for the model: the TLB just keeps stale entries; it is what produces overlapping 4K/megapage entries).
//  * PTW: latency 0..6 cycles, one request outstanding. Optional "stale" mode (p_stale>0) injects a spurious response for a page that is
//    not being walked; the real PTW drops responses of flushed walks (walk_drop_resp_credit), so this is NOT reachable in the SoC and only
//    exists to cover the defensive branch (vaddr mismatch -> response consumed and dropped); it goes to separate trace files (it also replaces a pending walk response by a wrong-page one).
// Build/run: tests/tlb_mmu/run_rand.sh.   args: out.trc seed cycles [p_stale_permille]
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <random>
#include <string>
#include <unordered_map>
#define private public
#include "TlbMmu.h"
#undef private
#include "tlb_mmu_fields.h"
using namespace ttg_io;

long long sim_time = 0;

static ttg::TraceWriter<decltype(kFields)> *tw;
static std::map<std::string, int> ids;
static void S(const std::string &n, int e, uint64_t v) { tw->set(ids.at(n), e, v); }

// ---- mock PTW walk client (same observable behaviour as MemSubsystemPtwWalkPortAdapter) ----
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
static bool PM(int permille) { return R(1000) < permille; }

// ---- page-table memory ----
static std::unordered_map<uint32_t, uint32_t> mem;  // word address -> PTE
static const int NSPACE = 3, NV1 = 6, NV0 = 32;
static uint32_t root_ppn(int s) { return 0x200 + 0x10 * s; }
static uint32_t l2_ppn(int s, int v1) { return 0x400 + 0x40 * s + 4 * v1; }
static uint32_t flags_random() {
  uint32_t f = 1;  // V
  if (P(80)) f |= 2; if (P(50)) f |= 4; if (P(40)) f |= 8; if (P(50)) f |= 16; if (P(15)) f |= 32; if (P(85)) f |= 64; if (P(60)) f |= 128;
  f |= (uint32_t)R(4) << 8;  // RSW
  return f;
}
static uint32_t pte_l1(int s, int v1) {
  int k = R(100);
  if (k < 55) return (l2_ppn(s, v1) << 10) | 1u | (P(10) ? (uint32_t)(flags_random() & 0xF0) : 0);
  if (k < 75) return ((uint32_t)(R(0x400) << 10) << 0 & 0xFFC00000u) | ((uint32_t)R(4) << 20 & 0) | flags_random() | 2;  // megapage, ppn0 = 0
  if (k < 80) return ((uint32_t)R(0x400000) << 10) | flags_random() | 2;                                            // maybe misaligned
  if (k < 90) return flags_random() & ~1u;                                                                           // invalid
  if (k < 95) return ((uint32_t)R(0x400000) << 10) | 1u | 4u;                                                        // !R && W
  return ((uint32_t)R(0x400000) << 10) | 1u;                                                                         // pointer
}
static uint32_t pte_l2(void) {
  int k = R(100);
  if (k < 78) return ((uint32_t)R(0x400000) << 10) | flags_random() | (P(95) ? 2u : 8u);
  if (k < 88) return flags_random() & ~1u;
  if (k < 93) return ((uint32_t)R(0x400000) << 10) | 1u | 4u;
  return ((uint32_t)R(0x400000) << 10) | 1u;  // non-leaf at level 0 -> fault
}
static void build_tables(int nv0) {
  for (int s = 0; s < NSPACE; s++)
    for (int v1 = 0; v1 < NV1; v1++) {
      mem[(root_ppn(s) << 10) + v1] = pte_l1(s, v1);
      for (int v0 = 0; v0 < nv0; v0++) mem[(l2_ppn(s, v1) << 10) + v0] = pte_l2();
    }
}
static void mutate_tables(int nv0) {
  int s = R(NSPACE), v1 = R(NV1);
  if (P(25)) {  // flip a region between "pointer to a 4K table" and "megapage": later lookups see overlapping 4K / megapage entries
    mem[(root_ppn(s) << 10) + v1] = P(50) ? (l2_ppn(s, v1) << 10) | 1u
                                          : ((uint32_t)R(0x400) << 20) | (flags_random() | 2u | 8u) ;
  }
  else if (P(30)) mem[(root_ppn(s) << 10) + v1] = pte_l1(s, v1);
  else mem[(l2_ppn(s, v1) << 10) + R(nv0)] = pte_l2();
}
static uint32_t rd(uint32_t paddr) { auto it = mem.find(paddr >> 2); return it == mem.end() ? 0 : it->second; }

// Sv32 walk as MemPtwBlock does it
static PtwWalkResp walk(uint32_t vaddr, uint32_t satp) {
  PtwWalkResp r; r.vaddr = vaddr; r.fault = true; r.leaf_pte = 0; r.leaf_level = 0;
  uint32_t root = satp & 0x3FFFFF, v1 = (vaddr >> 22) & 0x3FF, v0 = (vaddr >> 12) & 0x3FF;
  uint32_t pte = rd((root << 12) + (v1 << 2));
  bool v = pte & 1, rr = pte & 2, w = pte & 4, x = pte & 8;
  if (!v || (!rr && w)) return r;
  if (rr || x) {
    if (((pte >> 10) & 0x3FF) != 0) return r;
    r.fault = false; r.leaf_pte = pte; r.leaf_level = 1; return r;
  }
  uint32_t ppn = (pte >> 10) & 0x3FFFFF;
  pte = rd((ppn << 12) + (v0 << 2));
  v = pte & 1; rr = pte & 2; w = pte & 4; x = pte & 8;
  if (!v || (!rr && w) || !(rr || x)) return r;
  r.fault = false; r.leaf_pte = pte; r.leaf_level = 0;
  return r;
}

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "rand.trc";
  uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
  int ncyc = argc > 3 ? atoi(argv[3]) : 100000;
  int p_stale = argc > 4 ? atoi(argv[4]) : 0;
  for (int i = 0; i < (int)kNumFields; i++) ids[kFields[i].name] = i;
  static ttg::TraceWriter<decltype(kFields)> w(out, kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  tw = &w;
  rng.seed(seed);

  SimContext *ctx = nullptr;
  TlbMmu tlb(ctx, nullptr, DTLB_ENTRIES, TlbMmu::Kind::DTLB);
  tlb.flush(); tlb.seq();  // BackTop::init
  MockPort port;
  tlb.set_ptw_walk_port(&port);
  for (int k = 0; k < 3; k++) w.commit(0, ttg::kFlagReset);

  int nv0 = NV0;
  build_tables(nv0);
  // PTW client state
  bool pend = false; int lat = 0; PtwWalkResp pend_resp; uint32_t pend_vaddr = 0; bool rv = false; PtwWalkResp rresp;

  // CSR pool
  uint32_t satps[5] = {0, (1u << 31) | (1u << 22) | root_ppn(0), (1u << 31) | (2u << 22) | root_ppn(1),
                       (1u << 31) | (1u << 22) | root_ppn(2), (1u << 31) | (0u << 22) | root_ppn(0)};
  uint32_t satp = satps[1]; uint32_t privilege = 1, mxr = 0, sum = 0, mprv = 0, mpp = 1;
  // phase parameters
  int p_req = 50, hot = 40, p_fence_pm = 0, p_cancel = 2, p_mut_pm = 3;
  // lane state
  bool pv[8] = {}; uint32_t pva[8] = {};
  static const int mpps[3] = {0, 1, 3};
  long st_cycles = 0, st_refill = 0, st_evict = 0, st_walkreq = 0, st_early = 0, st_cancel_resp = 0, st_res[3] = {}, st_fence = 0;

  for (int c = 0; c < ncyc; c++) {
    sim_time = c;
    if (c % 4000 == 0) {
      static const int pr[] = {5, 30, 80}, hs[] = {2, 8, 40, NV1 * NV0, NV1 * NV0}, pf[] = {0, 0, 0, 1, 8}, pc[] = {0, 0, 1, 4};
      p_mut_pm = P(40) ? 30 : 3; p_req = pr[R(3)]; hot = hs[R(5)]; p_fence_pm = pf[R(5)]; p_cancel = pc[R(4)];
      if (P(30)) { nv0 = P(50) ? 8 : NV0; build_tables(nv0); }
    }
    if (PM(p_mut_pm)) mutate_tables(nv0);
    if (PM(10)) satp = satps[R(9) == 0 ? 0 : 1 + R(4)];
    if (PM(20)) { static const int pv_[4] = {0, 1, 1, 3}; privilege = pv_[R(4)]; }
    if (PM(20)) { mxr = R(2); sum = R(2); mprv = R(2); mpp = mpps[R(3)]; }

    // ---- stimulus ----
    bool fence = PM(p_fence_pm), flushb = P(p_cancel) && P(40), mispred = P(p_cancel) && P(60);
    LsuMMUIO req{}; MMULsuIO resp{};
    req.csr_status.satp = satp; req.csr_status.privilege = privilege;
    req.csr_status.mstatus = (mxr << 19) | (sum << 18) | (mprv << 17) | (mpp << 11);
    uint32_t last_page[8];
    for (int i = 0; i < 8; i++) {
      bool v = false; uint32_t va = 0;
      if (pv[i] && P(85)) { v = true; va = pva[i]; }
      else if (P(p_req)) {
        v = true;
        if (i > 0 && P(25)) va = (pva[R(i)] & ~0xFFFu) | (uint32_t)R(4096);  // same page as another lane
        else {
          int pg = R(hot);
          uint32_t v1 = (pg / NV0) % NV1, v0 = pg % NV0;
          if (PM(15)) v1 = R(1024);              // outside the built tables
          if (PM(10)) v0 = R(1024);
          va = (v1 << 22) | (v0 << 12) | (uint32_t)R(4096);
        }
      }
      last_page[i] = va;
      MMUReq &q = i < 4 ? req.ldq_req[i] : req.stq_req[i - 4];
      q.valid = v; q.vaddr = va; q.entry_idx = R(64); q.wait_idx = R(64);
      pva[i] = va; pv[i] = v;
    }
    // PTW port as the TLB will see it
    port.in = {}; port.sq = {};
    port.out.req_ready = !pend; port.out.resp_valid = rv; port.out.resp = rv ? rresp : PtwWalkResp{};
    if (p_stale && !rv && PM(p_stale)) {
      // spurious response: either unprompted, or replacing the pending walk's response by one for a page one VPN bit away
      uint32_t base = pend ? pend_vaddr : pva[R(8)];
      pend = false;
      rv = true; rresp = PtwWalkResp(); rresp.fault = P(30);
      rresp.vaddr = (P(70) ? (base ^ ((uint32_t)1 << (12 + R(20)))) : (uint32_t)rng()) & ~0xFFFu;
      rresp.leaf_pte = (uint32_t)rng(); rresp.leaf_level = R(2);
      port.out.req_ready = true; port.out.resp_valid = true; port.out.resp = rresp;
    }
    PtwWalkPortCombOut seen = port.out;

    // ---- reference model: BackTop::comb_lsu_mmu ----
    bool cancel = flushb || mispred;
    if (fence) tlb.flush();
    else if (cancel) tlb.cancel_pending_walk();
    else tlb.translate_lsu_ports(req, resp);
    bool was_walk = false;
    (void)was_walk;
    if (tlb.refill_comb_.valid) {
      st_refill++;
      if (tlb.tlb_entries_[tlb.refill_comb_.slot].valid) st_evict++;
    }
    if (port.in.resp_consumed && cancel) st_cancel_resp++;
    if (port.in.req_valid) st_walkreq++;
    if (fence) st_fence++;
    st_cycles++;

    // ---- record ----
    for (int i = 0; i < 8; i++) {
      const char *q = i < 4 ? "ldq" : "stq"; int e = i & 3;
      MMUReq &rq = i < 4 ? req.ldq_req[i] : req.stq_req[i - 4];
      MMUResp &rs = i < 4 ? resp.ldq_resp[i] : resp.stq_resp[i - 4];
      std::string n = q;
      S(n + "_req_valid", e, rq.valid); S(n + "_req_vaddr", e, rq.vaddr);
      S(n + "_req_entry_idx", e, rq.entry_idx); S(n + "_req_wait_idx", e, rq.wait_idx);
      S(n + "_resp_valid", e, rs.valid); S(n + "_resp_result", e, (uint32_t)rs.result);
      S(n + "_resp_hit", e, rs.valid && rs.result == MMUResultType::HIT); S(n + "_resp_paddr", e, rs.paddr);
      S(n + "_resp_entry_idx", e, rs.entry_idx); S(n + "_resp_wait_idx", e, rs.wait_idx);
      if (rs.valid) st_res[(int)rs.result]++;
      // LSU retry on MISS only
      pv[i] = rq.valid && rs.valid && rs.result == MMUResultType::MISS;
    }
    S("csr_status_satp", 0, satp); S("csr_status_privilege", 0, privilege);
    S("csr_status_mstatus_mxr", 0, mxr); S("csr_status_mstatus_sum", 0, sum);
    S("csr_status_mstatus_mprv", 0, mprv); S("csr_status_mstatus_mpp", 0, mpp);
    S("rob_bcast_fence", 0, fence); S("rob_bcast_flush", 0, flushb); S("dec_bcast_mispred", 0, mispred);
    S("ptw_walk_req_ready", 0, seen.req_ready); S("ptw_walk_resp_valid", 0, seen.resp_valid);
    S("ptw_walk_resp_fault", 0, seen.resp.fault); S("ptw_walk_resp_vpn", 0, (uint32_t)seen.resp.vaddr >> 12);
    S("ptw_walk_resp_leaf_ppn", 0, ((uint32_t)seen.resp.leaf_pte >> 10) & 0xFFFFF);
    S("ptw_walk_resp_leaf_perm", 0, (uint32_t)seen.resp.leaf_pte & 0xFF);
    S("ptw_walk_resp_leaf_level", 0, (uint32_t)seen.resp.leaf_level & 1);
    S("ptw_walk_req_valid", 0, port.in.req_valid); S("ptw_walk_req_vpn", 0, (uint32_t)port.in.req.vaddr >> 12);
    S("ptw_walk_req_root_ppn", 0, (uint32_t)port.in.req.satp & 0x3FFFFF);
    S("ptw_walk_resp_consumed", 0, port.in.resp_consumed); S("ptw_walk_flush", 0, port.sq.flush);
    w.commit(c);

    // ---- seq ----
    tlb.seq();
    if (port.in.resp_consumed) rv = false;
    if (port.in.req_valid) {
      rv = false; pend = true; lat = R(7);
      pend_resp = walk(port.in.req.vaddr, port.in.req.satp); pend_vaddr = port.in.req.vaddr;
    }
    if (port.sq.flush) { pend = false; rv = false; }
    else if (pend) {
      if (lat-- <= 0) { pend = false; rv = true; rresp = pend_resp; }
    }
  }
  fprintf(stderr, "%s: cycles=%ld fence=%ld walk_req=%ld refills=%ld evictions=%ld cancel_consumed_resp=%ld results miss/hit/fault=%ld/%ld/%ld\n",
          out, st_cycles, st_fence, st_walkreq, st_refill, st_evict, st_cancel_resp, st_res[0], st_res[1], st_res[2]);
  return 0;
}
