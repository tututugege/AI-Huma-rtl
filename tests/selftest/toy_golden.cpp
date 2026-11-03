// Golden model + trace recorder for the toy_fifo selftest. It plays the role of the C++ simulator hook:
// it computes every output of the cycle (comb), records the port values, then advances the state (seq).
#include "toy_fifo_fields.h"
#include "trace_format.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>

using namespace ttg_io;

struct Toy {
  uint8_t mem[4] = {};
  unsigned head = 0, tail = 0, count = 0;
};

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: toy_golden <trace> <cycles> [seed]\n");
    return 2;
  }
  const uint64_t cycles = std::strtoull(argv[2], nullptr, 0);
  uint64_t rng = argc > 3 ? std::strtoull(argv[3], nullptr, 0) : 1;
  auto rnd = [&]() {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
  };
  ttg::TraceWriter<decltype(kFields)> tw(argv[1], kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  Toy s;
  for (uint64_t cyc = 0; cyc < cycles; ++cyc) {
    const bool reset = cyc < 3 || (rnd() % 997) == 0;
    const bool push_valid = rnd() & 1, pop_ready = (rnd() % 3) != 0, flush = (rnd() % 50) == 0;
    const uint8_t push_data = uint8_t(rnd());
    uint32_t blob[3] = {uint32_t(rnd()), uint32_t(rnd()), uint32_t(rnd() & 0xffff)};

    // ---- comb ----
    const bool push_ready = s.count < 4, pop_valid = s.count != 0;
    tw.set(F_push_valid, 0, push_valid);
    tw.set(F_push_data, 0, push_data);
    tw.set(F_pop_ready, 0, pop_ready);
    tw.set(F_flush, 0, flush);
    tw.set_words(F_blob, 0, blob, 3);
    tw.set(F_push_ready, 0, push_ready);
    tw.set(F_pop_valid, 0, pop_valid);
    tw.set(F_pop_data, 0, s.mem[s.head]);
    tw.set(F_count, 0, s.count);
    for (int i = 0; i < 4; ++i) {
      tw.set(F_slot_valid, i, ((i - s.head) & 3) < s.count);
      tw.set(F_slot_data, i, s.mem[i]);
    }
    uint32_t rot[3];
    rot[0] = (blob[0] << 1) | ((blob[2] >> 15) & 1);
    rot[1] = (blob[1] << 1) | (blob[0] >> 31);
    rot[2] = ((blob[2] << 1) | (blob[1] >> 31)) & 0xffff;
    tw.set_words(F_blob_rot, 0, rot, 3);
    for (int r = 0; r < 2; ++r)
      for (int c = 0; c < 2; ++c) tw.set(F_lane_sum, r * 2 + c, (s.count + r * 2 + c) & 15);
    tw.commit(cyc, reset ? ttg::kFlagReset : 0);

    // ---- seq ----
    if (reset) {
      s = Toy{};
      continue;
    }
    const bool do_push = push_valid && push_ready, do_pop = pop_ready && pop_valid;
    if (do_push) {
      s.mem[s.tail] = push_data;
      s.tail = (s.tail + 1) & 3;
    }
    if (do_pop) s.head = (s.head + 1) & 3;
    s.count = s.count + do_push - do_pop;
    if (flush) s.head = s.tail = s.count = 0;
  }
  return 0;
}
