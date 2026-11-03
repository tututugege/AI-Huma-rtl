// Trace generator for the pure modules predecode (predecode.io) and sequential_next_pc: C++ golden = the reference
// predecode_comb() (front-end/predecode.cpp) and a verbatim copy of sequential_next_pc (front_top.cpp:78-96, a static function).
// Directed + exhaustive + random stimulus.  usage: gen_predecode <out.trc> <seed> <random cycles>
#include "predecode.h"
#include MODFIELDS
#include "gen_common.h"
GEN_BEGIN(MOD)

static uint32_t sequential_next_pc(uint32_t fetch_pc, const bool *inst_valid) {
  uint32_t valid_prefix = 0;
  while (valid_prefix < FETCH_WIDTH && inst_valid[valid_prefix]) ++valid_prefix;
  uint32_t next_pc = fetch_pc + valid_prefix * 4u;
  const uint32_t line_mask = ~(ICACHE_LINE_SIZE - 1u);
  if ((next_pc & line_mask) != (fetch_pc & line_mask)) next_pc &= line_mask;
  return next_pc;
}

static std::mt19937_64 rng;
static uint32_t R32() { return (uint32_t)rng(); }
static int R(int n) { return (int)(rng() % n); }

static void drive_predecode(uint32_t pc, const uint32_t inst[8], const bool valid[8]) {
  S("fetch_pc", 0, pc);
  for (int i = 0; i < 8; i++) {
    S("inst", i, inst[i]);
    S("inst_valid", i, valid[i]);
    PredecodeResult r{};
    if (valid[i]) {
      predecode_read_data rd{inst[i], pc + (uint32_t)(i * 4)};
      predecode_comb(rd, r);
    } else {
      r.type = PREDECODE_NON_BRANCH; r.target_address = 0;   // front_top.cpp:1631-1634
    }
    S("predecode_type", i, r.type);
    S("predecode_target_address", i, r.target_address);
  }
  commit_cycle();
}

static void drive_seqpc(uint32_t pc, const bool valid[8]) {
  S("fetch_pc", 0, pc);
  for (int i = 0; i < 8; i++) S("inst_valid", i, valid[i]);
  S("seq_next_pc", 0, sequential_next_pc(pc, valid));
  commit_cycle();
}

static uint32_t rand_inst() {
  static const uint32_t opc[] = {0x6f, 0x63, 0x67, 0x13, 0x33, 0x03, 0x23, 0x37, 0x17, 0x73, 0x0f, 0x00};
  uint32_t i = R32();
  switch (R(8)) {
    case 0: case 1: return (i & ~0x7fu) | 0x6f;          // jal
    case 2: case 3: return (i & ~0x7fu) | 0x63;          // branch
    case 4: return (i & ~0x7fu) | 0x67;                  // jalr
    case 5: return (i & ~0x7fu) | opc[R(12)];
    case 6: return R(2) ? 0u : 0x00000013u;              // 0 and NOP: C++ early-out, must equal the opcode decode
    default: return i;
  }
}
static uint32_t rand_pc() {
  switch (R(5)) {
    case 0: return 0xfffffff0u + 4u * R(4);              // wrap-around region
    case 1: return 0x80000000u + 4u * R(16);
    case 2: return R32() & ~3u;
    case 3: return R32();                                // unaligned
    default: return 0x80000000u + (R32() & 0x00fffffcu);
  }
}

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "gen.trc";
  rng.seed(argc > 2 ? strtoull(argv[2], 0, 0) : 1);
  int nrand = argc > 3 ? atoi(argv[3]) : 200000;
  GEN_OPEN(out)
  const bool is_seq = std::strcmp(kModule, "sequential_next_pc") == 0;
  bool v8[8], vall[8];
  for (int i = 0; i < 8; i++) vall[i] = true;
  if (is_seq) {
    // exhaustive: every valid pattern x every 4-byte offset inside a cache line x a few high-address choices
    for (int pat = 0; pat < 256; pat++) {
      for (int i = 0; i < 8; i++) v8[i] = (pat >> i) & 1;
      for (int off = 0; off < ICACHE_LINE_SIZE; off += 4) {
        drive_seqpc(0x80000000u + off, v8);
        drive_seqpc((R32() & ~(ICACHE_LINE_SIZE - 1u)) + off, v8);
        drive_seqpc(0xffffffc0u + off, v8);                // wraps past 2^32 when the group crosses the end of memory
      }
    }
    for (int c = 0; c < nrand; c++) {
      for (int i = 0; i < 8; i++) v8[i] = R(4) ? (i < R(9)) : R(2);   // mostly prefixes, sometimes arbitrary
      drive_seqpc(rand_pc(), v8);
    }
  } else {
    uint32_t inst[8];
    // directed 1: every 7-bit opcode in every lane with random upper bits, all lanes valid / invalid
    for (int op = 0; op < 128; op++) {
      for (int rep = 0; rep < 4; rep++) {
        for (int i = 0; i < 8; i++) inst[i] = (R32() & ~0x7fu) | ((op + i) & 0x7f);
        drive_predecode(rand_pc(), inst, vall);
        bool vn[8] = {};
        drive_predecode(rand_pc(), inst, vn);              // invalid lanes must give NON_BRANCH / 0
      }
    }
    // directed 2: every single immediate bit (inst[31:7]) of jal / branch / jalr, pc one-hot and extremes
    const uint32_t ops[3] = {0x6f, 0x63, 0x67};
    for (int o = 0; o < 3; o++) {
      for (int b = 7; b <= 31; b++) {
        for (int i = 0; i < 8; i++) inst[i] = ops[o] | (1u << b) | ((i & 1) ? 0xfffff000u & R32() : 0u);
        drive_predecode(0x80000000u, inst, vall);
        drive_predecode(0x7ffffff0u, inst, vall);
        drive_predecode(0xfffffff0u, inst, vall);
        for (int i = 0; i < 8; i++) inst[i] = ops[o] | (0x1ffffffu << 7) & ~(1u << b);
        drive_predecode(0x80000000u, inst, vall);
        drive_predecode(0u, inst, vall);
      }
    }
    for (int c = 0; c < nrand; c++) {
      for (int i = 0; i < 8; i++) { inst[i] = rand_inst(); v8[i] = R(5) ? (R(8) > i / 2 || R(3) == 0) : R(2); }
      drive_predecode(rand_pc(), inst, v8);
    }
  }
  w.flush();
  std::printf("%s: %llu records\n", kModule, (unsigned long long)g_cycle);
  return 0;
}
