// Verification plugin: per-cycle FNV hash of front.out (+ cycle counter); optionally the tap (-DUSE_TAP).
// Env CHK_N: stop after N cycles (prints hash). Without CHK_N, runs to completion and prints at exit.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#define private public
#define protected public
#include "SimCpu.h"
#ifdef USE_TAP
#include "front_tap.h"
#endif
#undef private
#undef protected
static uint64_t H = 1469598103934665603ull, HT = 1469598103934665603ull, cnt = 0, N = ~0ull;
static void mix(uint64_t &h, uint64_t v) { h ^= v; h *= 1099511628211ull; }
static void fin() { std::printf("CHK cycles=%llu hash=%016llx taphash=%016llx\n", (unsigned long long)cnt, (unsigned long long)H, (unsigned long long)HT); }
extern "C" void ttg_rec_cycle(SimCpu *c, uint64_t cycle) {
  static bool init = false;
  if (!init) { init = true; if (const char *e = std::getenv("CHK_N")) N = std::strtoull(e, 0, 0); std::atexit(fin); }
  auto &o = c->front.out;
  mix(H, cycle); mix(H, o.FIFO_valid); mix(H, o.commit_stall); mix(H, o.predict_next_fetch_address);
  for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) { mix(H, o.pc[i]); mix(H, o.instructions[i]); mix(H, o.inst_valid[i]); mix(H, o.predict_dir[i]); }
  mix(H, c->ctx.perf.commit_num);
#ifdef USE_TAP
  auto &t = g_ttg_front_tap;
  mix(HT, t.count); mix(HT, t.global_refetch); mix(HT, t.bpu_out.fetch_address); mix(HT, t.icache_out.icache_read_complete);
  mix(HT, t.ptab_req.push_write_en); mix(HT, t.ptab_req.pop_en); mix(HT, t.front2back_req.push_en); mix(HT, t.front2back_req.pop_en);
  mix(HT, t.saved_ptab_out.predict_next_fetch_address); mix(HT, t.checker_out.predecode_flush_enable);
#endif
  if (++cnt >= N) { fin(); std::fflush(stdout); std::_Exit(0); }
}
