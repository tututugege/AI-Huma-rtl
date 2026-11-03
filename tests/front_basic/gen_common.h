// Shared helpers of the front_basic random/exhaustive trace generators (pure functions + front_ctrl).
// Each generator is compiled against its own generated build/<mod>/<mod>_fields.h and the reference sources.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <random>
#include <string>

#define GEN_BEGIN(MOD)                                                                                        \
  using namespace ttg_io;                                                                                     \
  static ttg::TraceWriter<decltype(kFields)> *tw;                                                             \
  static std::map<std::string, int> ids;                                                                      \
  static void S(const char *n, int e, uint64_t v) { tw->set(ids.at(n), e, v); }                               \
  static uint64_t g_cycle = 0;                                                                                \
  static void commit_cycle() { tw->commit(++g_cycle, 0); }

#define GEN_OPEN(outpath)                                                                                     \
  for (int i = 0; i < (int)kNumFields; i++) ids[kFields[i].name] = i;                                         \
  static ttg::TraceWriter<decltype(kFields)> w(outpath, kModule, kInBytes, kOutBytes, kSpecHash, kFields);    \
  tw = &w;                                                                                                    \
  for (int k = 0; k < 3; k++) w.commit(0, ttg::kFlagReset);
