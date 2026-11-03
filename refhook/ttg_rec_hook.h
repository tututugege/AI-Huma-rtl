// Recording / lock-step hook compiled into the reference simulator (refsim). It loads the plugin(s) named by $TTG_REC
// (shared libraries generated from specs, see scripts/record.sh and scripts/lockstep.sh; several plugins may be given
// separated by ':') and calls every one once per cycle, after BackTop::comb() and before any sequential update.
// Without $TTG_REC it does nothing.
// Multi-plugin mode ($TTG_MULTI set): the plugins neither stop nor exit on their own; when $TTG_REC_N cycles have run the
// hook calls each plugin's ttg_rec_finish() (final report) and exits.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>
#include <string>
#include <vector>

class SimCpu;

namespace ttg_rec {
using CycleFn = void (*)(SimCpu *, uint64_t);
using FinishFn = void (*)();

struct Plugins {
  std::vector<CycleFn> cycle;
  std::vector<FinishFn> finish;
  uint64_t limit = ~0ull;
  Plugins() {
    const char *list = std::getenv("TTG_REC");
    if (!list || !*list) return;
    if (const char *n = std::getenv("TTG_REC_N")) limit = std::strtoull(n, nullptr, 0);
    std::string s = list;
    size_t pos = 0;
    while (pos <= s.size()) {
      size_t e = s.find(':', pos);
      if (e == std::string::npos) e = s.size();
      std::string path = s.substr(pos, e - pos);
      pos = e + 1;
      if (path.empty()) continue;
      void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
      if (!h) {
        std::fprintf(stderr, "TTG_REC: dlopen(%s) failed: %s\n", path.c_str(), dlerror());
        std::exit(1);
      }
      auto fn = reinterpret_cast<CycleFn>(dlsym(h, "ttg_rec_cycle"));
      if (!fn) {
        std::fprintf(stderr, "TTG_REC: %s has no ttg_rec_cycle\n", path.c_str());
        std::exit(1);
      }
      cycle.push_back(fn);
      finish.push_back(reinterpret_cast<FinishFn>(dlsym(h, "ttg_rec_finish")));
    }
  }
};

inline void cycle(SimCpu *cpu, uint64_t n) {
  static Plugins p;
  if (p.cycle.empty()) return;
  for (auto fn : p.cycle) fn(cpu, n);
  if (std::getenv("TTG_MULTI") && n >= p.limit) {
    for (auto f : p.finish)
      if (f) f();
    std::fflush(stdout);
    std::_Exit(0);
  }
}
}  // namespace ttg_rec
