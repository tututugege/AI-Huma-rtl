// Trace generator for predecode_checker: C++ golden = the reference predecode_checker_comb() (front-end/predecode_checker.cpp).
// Random + directed stimulus (every first-taken position x type, flush / no-flush balanced).
// usage: gen_checker <out.trc> <seed> <random cycles>
#include "predecode_checker.h"
#include "predecode.h"
#include MODFIELDS
#include "gen_common.h"
GEN_BEGIN(MOD)

static std::mt19937_64 rng;
static uint32_t R32() { return (uint32_t)rng(); }
static int R(int n) { return (int)(rng() % n); }

static void drive(const predecode_checker_in &in) {
  predecode_checker_read_data rd{};
  predecode_checker_seq_read(const_cast<predecode_checker_in *>(&in), &rd);
  predecode_checker_out o{};
  predecode_checker_comb(rd, o);
  for (int i = 0; i < 8; i++) {
    S("predict_dir", i, in.predict_dir[i]);
    S("predecode_type", i, in.predecode_type[i]);
    S("predecode_target_address", i, in.predecode_target_address[i]);
    S("predict_dir_corrected", i, o.predict_dir_corrected[i]);
  }
  S("predict_next_fetch_address", 0, in.predict_next_fetch_address);
  S("seq_next_pc", 0, in.seq_next_pc);
  S("predict_next_fetch_address_corrected", 0, o.predict_next_fetch_address_corrected);
  S("predecode_flush_enable", 0, o.predecode_flush_enable);
  commit_cycle();
}

// fill predict_next_fetch_address: 50% the value the checker will compute (no flush), else random / near miss
static void pick_pred_next(predecode_checker_in &in) {
  in.predict_next_fetch_address = 0;
  predecode_checker_read_data rd{};
  predecode_checker_seq_read(&in, &rd);
  predecode_checker_out o{};
  predecode_checker_comb(rd, o);
  uint32_t c = o.predict_next_fetch_address_corrected;
  switch (R(4)) {
    case 0: case 1: in.predict_next_fetch_address = c; break;
    case 2: in.predict_next_fetch_address = c ^ (1u << R(32)); break;     // differs in one bit
    default: in.predict_next_fetch_address = R32(); break;
  }
}

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "gen.trc";
  rng.seed(argc > 2 ? strtoull(argv[2], 0, 0) : 1);
  int nrand = argc > 3 ? atoi(argv[3]) : 200000;
  GEN_OPEN(out)
  predecode_checker_in in{};
  // directed: for each lane k, type t, dir d: lanes before k are non-taken (NON_BRANCH or untaken branch), lane k taken
  for (int k = 0; k <= 8; k++)
    for (int t = 0; t < 4; t++)
      for (int d = 0; d < 2; d++)
        for (int rep = 0; rep < 8; rep++) {
          std::memset(&in, 0, sizeof(in));
          for (int i = 0; i < 8; i++) {
            in.predecode_target_address[i] = R32();
            in.predict_dir[i] = R(2);
            if (i < k) { in.predecode_type[i] = R(2) ? PREDECODE_NON_BRANCH : PREDECODE_DIRECT_JUMP_NO_JAL;
                         if (in.predecode_type[i] == PREDECODE_DIRECT_JUMP_NO_JAL) in.predict_dir[i] = 0; }
            else if (i == k) { in.predecode_type[i] = t; in.predict_dir[i] = d; }
            else in.predecode_type[i] = R(4);
          }
          in.seq_next_pc = R32();
          pick_pred_next(in);
          drive(in);
        }
  for (int c = 0; c < nrand; c++) {
    std::memset(&in, 0, sizeof(in));
    int mode = R(4);   // 0: uniform, 1: mostly non-branches, 2: many branches (dir random), 3: jalr/jal heavy
    for (int i = 0; i < 8; i++) {
      in.predict_dir[i] = R(2);
      in.predecode_target_address[i] = R(3) ? R32() : in.seq_next_pc;
      in.predecode_type[i] = mode == 0 ? R(4) : mode == 1 ? (R(6) ? 0 : R(4)) : mode == 2 ? (R(4) ? 1 : R(4)) : (R(2) ? 2 + R(2) : R(4));
    }
    in.seq_next_pc = R32();
    pick_pred_next(in);
    drive(in);
  }
  w.flush();
  std::printf("%s: %llu records\n", kModule, (unsigned long long)g_cycle);
  return 0;
}
