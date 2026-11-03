// End-of-CPU-cycle hook for fast-tick lock-step (memory-subsystem domains): the patched reference simulator
// (docs/analysis/memsys-record-hook.patch) calls ttg_rec_cycle_end(cpu, cycle) once per CPU cycle after all 16 ticks;
// here every recorded tick t = 0..15 is replayed through the generated lock plugin's ttg_rec_cycle (one RTL clock per tick).
// The "cycle" shown in a mismatch message is cycle*16 + tick.  Compiled into the plugin by scripts/lockstep_ticks.sh.
#include <cstdint>
#include <cstdio>
#include <cstdlib>

class SimCpu;
extern "C" void ttg_rec_cycle(SimCpu *cpu, uint64_t cycle);
#include "memsys_tap.h"

extern "C" void ttg_rec_cycle_end(SimCpu *cpu, uint64_t cycle) {
  static const bool stat = std::getenv("TTG_TICK_STAT") != nullptr;  // diagnostics: how often is each tick populated
  static uint64_t missing = 0, nonzero_strb_hi = 0;
  // The tap is armed lazily by the first call of this hook (end of CPU cycle 1), so cycle 1 is not captured: it is replayed as idle
  // (the DCache domain is untouched in cycle 1: empty pipeline), i.e. the RTL simply stays in reset state.
  if (!TTG_MS.t[0].valid) return;
  for (int t = 0; t < TTG_MS_TICKS; ++t) {
    TTG_MS.cur = t;
    if (stat) {
      if (!TTG_MS.t[t].valid && ++missing == 1) std::fprintf(stderr, "ticks_end: tick %d of cycle %llu not captured\n", t, (unsigned long long)cycle);
      for (int i = 0; i < LSU_STA_COUNT; ++i)
        if (TTG_MS.t[t].req.req_ports.store_ports[i].valid && (TTG_MS.t[t].req.req_ports.store_ports[i].strb >> 4) &&
            ++nonzero_strb_hi == 1)
          std::fprintf(stderr, "ticks_end: store strb upper nibble non-zero at cycle %llu\n", (unsigned long long)cycle);
    }
    ttg_rec_cycle(cpu, cycle * TTG_MS_TICKS + t);
  }
}
