// 16-tick lock-step shell for spec/axi_cpu_port_adapter.io (one CPU cycle = 16 internal ticks = 16 records).
// The generated lock-step plugin has ONE entry (ttg_rec_cycle) that compares ONE record per call.  Build it with
//   -Dttg_rec_cycle=ttg_rec_cycle_gen        (renames the generated entry)
// and link this file, which exports the real ttg_rec_cycle symbol (the one the reference's hook dlsym()s): per CPU cycle it
// replays the 16 tick records of the memcpu tap (TTG_MC.pub.ax[t], TTG_MC.t = t) through the generated entry.
// The shell is module-generic: it replays 16 ticks only when the module being built is the adapter (its fields header is on the
// include path), otherwise 1 call per cycle, so ONE shared EXTRA_CPP also works for lockstep_multi.sh over all four memcpu modules:
//   EXTRA_CPP="-Dttg_rec_cycle=ttg_rec_cycle_gen $PWD/tb/memcpu/axi_shell.cpp" REFSIM=.. bash scripts/lockstep_multi.sh \
//       mem_route ptw_walk peripheral_axi axi_cpu_port_adapter
//   single module:  EXTRA_CPP=".." BUILD_ONLY=1 bash scripts/lockstep.sh axi_cpu_port_adapter x ;  NOBUILD=1 .. lockstep.sh <mod> <prog> [cycles]
#include <cstdint>
#define private public
#define protected public
#include "SimCpu.h"
#undef private
#undef protected

extern "C" void ttg_rec_cycle_gen(SimCpu *cpu, uint64_t cycle);
extern "C" void ttg_rec_cycle_shell(SimCpu *cpu, uint64_t cycle) __asm__("_ttg_rec_cycle");

#if __has_include("axi_cpu_port_adapter_fields.h")
constexpr int kTicks = 16;
#else
constexpr int kTicks = 1;
#endif

extern "C" void ttg_rec_cycle_shell(SimCpu *cpu, uint64_t cycle) {
  if (kTicks == 1) {
    ttg_rec_cycle_gen(cpu, cycle);
    return;
  }
  for (int t = 0; t < 16; ++t) {
    g_ttg_mc.t = t;
    ttg_rec_cycle_gen(cpu, cycle * 16 + t);
  }
}
