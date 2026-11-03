// Recording hook compiled into the reference simulator (refsim). It loads the plugin named by $TTG_REC
// (a shared library generated from a spec, see scripts/record.sh) and calls it once per cycle, after
// BackTop::comb() and before any sequential update. Without $TTG_REC it does nothing.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>

class SimCpu;

namespace ttg_rec {
using CycleFn = void (*)(SimCpu *, uint64_t);

inline CycleFn load() {
  const char *path = std::getenv("TTG_REC");
  if (!path || !*path) return nullptr;
  void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
  if (!h) {
    std::fprintf(stderr, "TTG_REC: dlopen(%s) failed: %s\n", path, dlerror());
    std::exit(1);
  }
  auto fn = reinterpret_cast<CycleFn>(dlsym(h, "ttg_rec_cycle"));
  if (!fn) {
    std::fprintf(stderr, "TTG_REC: %s has no ttg_rec_cycle\n", path);
    std::exit(1);
  }
  return fn;
}

inline void cycle(SimCpu *cpu, uint64_t n) {
  static const CycleFn fn = load();
  if (fn) fn(cpu, n);
}
}  // namespace ttg_rec
