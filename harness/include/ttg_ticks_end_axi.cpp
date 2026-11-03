// End-of-CPU-cycle hook for the AXI interconnect / LLC fast-tick lock-step: the reference simulator patched with
// docs/analysis/memsys-record-hook.patch + axi-record-hook.patch calls ttg_rec_cycle_end(cpu, cycle) once per CPU cycle after all
// 16 ticks; every recorded tick t = 0..15 is replayed through the generated lock plugin's ttg_rec_cycle (one RTL clock per tick).
// The "cycle" shown in a mismatch message is cycle*16 + tick.  Compiled into the plugin by scripts/lockstep_ticks_axi.sh.
#include <cstdint>
#include <cstdio>
#include <cstdlib>

class SimCpu;
extern "C" void ttg_rec_cycle(SimCpu *cpu, uint64_t cycle);
#include "memsys_tap.h"
#include "axi_tap.h"

extern "C" void ttg_rec_cycle_end(SimCpu *cpu, uint64_t cycle) {
  for (int t = 0; t < TTG_AXI_TICKS; ++t) {
    TTG_MS.cur = t;
    ttg_rec_cycle(cpu, cycle * TTG_AXI_TICKS + t);
  }
}
