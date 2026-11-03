// Constrained-random stream for the BPU top (spec/bpu.io).  Golden = the REAL reference class BPU_TOP driven exactly like
// front_top.cpp does (bpu_seq_read; bpu_comb_calc; bpu_seq_write, once per cycle); the same inputs + the reference outputs are
// written as a trace for the RTL.
//
// Legality (what the reference model assumes / what the real core can produce):
//   * br_type in 0..5 (BR_DIRECT..BR_JAL), pcpn/altpcpn in 0..4, all pcs 4-byte aligned;  sc_*/loop_* inputs stay 0
//     (the BPU never emits non-zero SC/loop metadata, so a real backend cannot send any).
//   * update metadata (pred_dir, alt_pred, pcpn, tags, idxs) is either the metadata the BPU itself emitted for that pc
//     (realistic mode: a software "backend" keeps the predicted groups in flight and commits their lanes in order, with a
//     synthetic static program giving type/target/direction), or fully random (stress mode: the C++ model accepts any values;
//     idx is masked to its width by construction).
//   * refetch comes with arbitrary 4-aligned addresses, including 32-byte-group / 64-byte-line straddling ones and
//     addresses near 2^32 (the reference wraps in 32 bits, the RTL does the same).
// Phases (switched every ~3000 cycles): 0 realistic, 1 stress (tiny pc pool, random meta, dense commits: bank collisions in
// the update queue and the type table), 2 call/return heavy (RAS depth beyond 32), 3 refetch heavy, 4 realistic + back-pressure.
// usage: rand_trace <out.trc> <seed> <cycles>
#include <deque>
#include <vector>
#define private public
#include "front_module.h"
#include "train_IO.h"
#include MODFIELDS
#include "gen_common.h"
GEN_BEGIN(MOD)
#include "BPU/BPU.h"

BPU_TOP *g_bpu_top = nullptr;
static std::mt19937_64 rng;
static uint64_t R64() { return rng(); }
static int R(int n) { return (int)(rng() % n); }
static bool P(double p) { return (rng() >> 11) * (1.0 / 9007199254740992.0) < p; }
static uint32_t mix(uint32_t x) { x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16; return x; }

struct Lane { uint32_t pc; bool pred, alt; int pcpn, altpcpn; int tags[4], idxs[4]; };
static std::vector<uint32_t> pool;   // pc pool (word aligned)
static long cv_drop, cv_tage_upd, cv_reset, cv_usealt, cv_alloc, cv_tage_hit, cv_btb_upd, cv_tc, cv_mode, cv_idir_pred, cv_ras_s, cv_ras_a, cv_ras_full, cv_refetch, cv_pred;

static void make_pool(int regions) {
  pool.clear();
  for (int r = 0; r < regions; r++) {
    uint32_t base = (uint32_t)(R64() & 0xFFFFFFC0u);
    if (r == 0) base = 0x80000000u;
    if (r == 1) base = 0xFFFFFF80u;            // addresses near 2^32
    for (int w = 0; w < 32; w++) pool.push_back(base + 4u * w);
  }
}
static uint32_t pool_pc() { return pool[R((int)pool.size())]; }
// synthetic static program
static int static_type(uint32_t pc, int phase) {
  uint32_t h = mix(pc >> 2) % 100;
  if (phase == 2) return h < 45 ? 1 : h < 85 ? 0 : h < 90 ? 2 : h < 95 ? 3 : 5;
  if (h < 55) return 4;
  if (h < 80) return 0;
  if (h < 85) return 1;
  if (h < 90) return 2;
  if (h < 93) return 3;
  return 5;
}
static uint32_t static_target(uint32_t pc) { return pool[mix((pc >> 2) * 3 + 1) % pool.size()]; }
static bool static_dir(uint32_t pc, int ty) {
  if (ty != 0) return true;
  uint32_t h = mix((pc >> 2) + 77) % 100;
  return P(h < 50 ? 0.9 : 0.15);
}

int main(int argc, char **argv) {
  if (argc < 4) { std::fprintf(stderr, "usage: %s out.trc seed cycles\n", argv[0]); return 2; }
  rng.seed(std::strtoull(argv[2], 0, 0));
  const long N = std::strtol(argv[3], 0, 0);
  GEN_OPEN(argv[1]);
  static BPU_TOP bpu;
  g_bpu_top = &bpu;
  make_pool(12);
  std::deque<Lane> inflight;
  int phase = 0;
  bool want_refetch = false; uint32_t refetch_pc = 0;
  for (long cyc = 0; cyc < N; cyc++) {
    if (cyc % 3000 == 0) { phase = R(5); if (R(4) == 0) make_pool(2 + R(14)); if (phase == 1) make_pool(1 + R(3)); }
    BPU_TOP::InputPayload in{};
    // ---- control ----
    double p_ready = phase == 4 ? 0.35 : 0.8;
    in.icache_read_ready = P(p_ready);
    bool refetch = want_refetch || P(phase == 3 ? 0.25 : 0.01);
    if (refetch) {
      in.refetch = true;
      uint32_t a = want_refetch ? refetch_pc : (P(0.7) ? pool_pc() : (uint32_t)(R64() & ~3ull));
      if (P(0.05)) a = 0xFFFFFFC0u + 4u * R(16);
      if (P(0.1)) a = (a & ~63u) + 4u * R(16) + (P(0.5) ? 32 : 0);
      in.refetch_address = a;
    } else if (P(0.3)) {
      in.refetch_address = pool_pc();              // value is ignored without refetch (stale payload on a real bus)
    }
    want_refetch = false;
    // ---- commit lanes ----
    double p_commit = phase == 1 ? 0.95 : phase == 2 ? 0.8 : 0.6;
    if (P(p_commit)) {
      int n = phase == 1 ? 1 + R(8) : 1 + R(8);
      bool mispred_seen = false;
      for (int l = 0; l < n && l < COMMIT_WIDTH; l++) {
        Lane ln{};
        bool have = !inflight.empty() && phase != 1;
        if (have) { ln = inflight.front(); inflight.pop_front(); }
        else {
          ln.pc = pool_pc(); ln.pred = P(0.5); ln.alt = P(0.5); ln.pcpn = R(5); ln.altpcpn = R(5);
          for (int t = 0; t < 4; t++) { ln.tags[t] = R(256); ln.idxs[t] = R(1024); }
        }
        if (phase == 1 && P(0.5)) {  // stress: reuse recent tags/idx so TAGE entries are hit
          for (int t = 0; t < 4; t++) { ln.tags[t] = R(4); ln.idxs[t] = R(4); }
        }
        int ty = phase == 1 ? R(6) : static_type(ln.pc, phase);
        bool dir = phase == 1 ? P(0.5) : static_dir(ln.pc, ty);
        in.in_upd_valid[l] = true;
        in.in_update_base_pc[l] = ln.pc;
        in.in_actual_br_type[l] = ty;
        in.in_actual_dir[l] = dir;
        in.in_actual_targets[l] = P(0.1) ? (uint32_t)(R64() & ~3ull) : static_target(ln.pc);
        in.in_pred_dir[l] = ln.pred;
        in.in_alt_pred[l] = ln.alt;
        in.in_pcpn[l] = ln.pcpn;
        in.in_altpcpn[l] = ln.altpcpn;
        for (int t = 0; t < 4; t++) { in.in_tage_tags[l][t] = ln.tags[t]; in.in_tage_idxs[l][t] = ln.idxs[t]; }
        if (ty == 0 && ln.pred != dir && !mispred_seen) { mispred_seen = true; want_refetch = P(0.8); refetch_pc = static_target(ln.pc); }
      }
    }
    // payload of invalid lanes is junk on a real bus: fill some with garbage (the model must ignore it)
    for (int l = 0; l < COMMIT_WIDTH; l++) if (!in.in_upd_valid[l] && P(0.3)) {
      in.in_update_base_pc[l] = (uint32_t)R64(); in.in_actual_dir[l] = R(2); in.in_actual_br_type[l] = R(6);
      in.in_actual_targets[l] = (uint32_t)R64(); in.in_pred_dir[l] = R(2);
    }
    // ---- reference step ----
    BPU_TOP::ReadData rd; BPU_TOP::OutputPayload out{}; BPU_TOP::UpdateRequest req;
    bpu.bpu_seq_read(in, rd);
    bpu.bpu_comb_calc(in, rd, out, req);
    // ---- coverage counters (printed at exit) ----
    {
      bool seen[8] = {};
      for (int l = 0; l < COMMIT_WIDTH; l++) if (in.in_upd_valid[l]) { int b = (in.in_update_base_pc[l] >> 2) & 7; if (seen[b]) cv_drop++; seen[b] = true; }
      for (int b = 0; b < 8; b++) {
        if (req.tage_in[b].update_en) { cv_tage_upd++; if ((bpu.tage_inst[b]->reset_cnt_reg & 0x7ff) == 0) cv_reset++;
          if (req.tage_req[b].use_alt_ctr_reg_we) cv_usealt++; for (int t = 0; t < 4; t++) if (req.tage_req[b].tag_we_commit[t]) cv_alloc++; }
        if (req.tage_in[b].pred_req && req.tage_req[b].out_regs.pcpn_out < 4) cv_tage_hit++;
        if (req.btb_in[b].upd_valid) cv_btb_upd++;
        if (req.btb_req[b].tc_we_commit) cv_tc++;
        if (req.btb_req[b].tc_mode_we_commit) cv_mode++;
        if (req.btb_in[b].pred_req && req.btb_in[b].pred_type_in == BR_IDIRECT) cv_idir_pred++;
      }
      if (bpu.Spec_ras_count > cv_ras_s) cv_ras_s = bpu.Spec_ras_count;
      if (bpu.Arch_ras_count > cv_ras_a) cv_ras_a = bpu.Arch_ras_count;
      if (bpu.Spec_ras_count == RAS_DEPTH) cv_ras_full++;
      if (in.refetch) cv_refetch++;
      if (req.going_to_do_pred && !in.refetch) cv_pred++;
    }
    bpu.bpu_seq_write(in, req, false);
    // ---- record in-flight predictions (what a real backend would later send back) ----
    if (out.PTAB_write_enable) {
      uint32_t base = out.fetch_address;
      uint32_t plus = base + FETCH_WIDTH * 4, mask = ~(uint32_t)(ICACHE_LINE_SIZE - 1);
      uint32_t bound = ((base & mask) != (plus & mask)) ? (plus & mask) : plus;
      for (int i = 0; i < FETCH_WIDTH; i++) {
        uint32_t pc = base + 4 * i;
        if (!(pc < bound)) continue;
        Lane ln{}; ln.pc = pc; ln.pred = out.out_pred_dir[i]; ln.alt = out.out_alt_pred[i];
        ln.pcpn = out.out_pcpn[i]; ln.altpcpn = out.out_altpcpn[i];
        for (int t = 0; t < 4; t++) { ln.tags[t] = out.out_tage_tags[i][t]; ln.idxs[t] = out.out_tage_idxs[i][t]; }
        inflight.push_back(ln);
      }
      while (inflight.size() > 96) inflight.pop_front();
    }
    if (in.refetch) inflight.clear();
    // ---- trace record ----
    S("refetch", 0, in.refetch); S("refetch_address", 0, in.refetch_address); S("icache_read_ready", 0, in.icache_read_ready);
    for (int l = 0; l < COMMIT_WIDTH; l++) {
      S("upd_valid", l, in.in_upd_valid[l]); S("base_pc", l, in.in_update_base_pc[l]); S("actual_dir", l, in.in_actual_dir[l]);
      S("br_type", l, in.in_actual_br_type[l]); S("target", l, in.in_actual_targets[l]); S("pred_dir", l, in.in_pred_dir[l]);
      S("alt_pred", l, in.in_alt_pred[l]); S("pcpn", l, in.in_pcpn[l]);
      for (int t = 0; t < 4; t++) { S("tags", l * 4 + t, in.in_tage_tags[l][t]); S("idxs", l * 4 + t, in.in_tage_idxs[l][t]); }
    }
    S("icache_read_valid", 0, out.icache_read_valid); S("fetch_address", 0, out.fetch_address);
    S("ptab_write_enable", 0, out.PTAB_write_enable); S("predict_next_fetch_address", 0, out.predict_next_fetch_address);
    for (int i = 0; i < FETCH_WIDTH; i++) {
      S("out_pred_dir", i, out.out_pred_dir[i]); S("out_alt_pred", i, out.out_alt_pred[i]);
      S("out_pcpn", i, out.out_pcpn[i]); S("out_altpcpn", i, out.out_altpcpn[i]);
      for (int t = 0; t < 4; t++) { S("out_tage_tags", i * 4 + t, out.out_tage_tags[i][t]); S("out_tage_idxs", i * 4 + t, out.out_tage_idxs[i][t]); }
    }
    commit_cycle();
  }
  std::fprintf(stderr, "COV rand: cycles=%ld pred=%ld refetch=%ld q_drop=%ld tage_upd=%ld tage_hit_lanes=%ld alloc=%ld useful_reset=%ld usealt_we=%ld btb_upd=%ld tc_write=%ld tc_mode_write=%ld idirect_pred=%ld ras_spec_max=%ld ras_arch_max=%ld ras_spec_full_cycles=%ld\n", N, cv_pred, cv_refetch, cv_drop, cv_tage_upd, cv_tage_hit, cv_alloc, cv_reset, cv_usealt, cv_btb_upd, cv_tc, cv_mode, cv_idir_pred, cv_ras_s, cv_ras_a, cv_ras_full);
  return 0;
}
