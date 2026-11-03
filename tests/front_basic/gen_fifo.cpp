// Constrained-random trace generator for the four front-end FIFO modules (fetch_addr_fifo, inst_fifo, ptab, front2back_fifo).
// Golden = a plain queue driven spec-generically (every wr_* field is paired with its rd_* field), and in lock step the REAL
// reference FIFO class (front-end/fifo/*.cpp) is driven with the front_top.cpp protocol (read call, write call, accumulate,
// seq_write) on one tag field; the generator aborts if the reference class and the golden queue disagree on rd_valid, the
// head tag, or the size.  So the golden queue is validated against the reference for random sequences, and the same
// sequence (with full-width random payloads) goes to the RTL.
// Legal stimulus only: a push into a full queue (after the clear) is never issued (the reference exit(1)s on overflow).
// usage: gen_fifo <out.trc> <seed> <cycles>
#include <deque>
#include <vector>
#include "front_module.h"
#include "train_IO.h"
#include MODFIELDS
#include "gen_common.h"
GEN_BEGIN(MOD)

static std::mt19937_64 rng;
static uint64_t R64() { return rng(); }
static int R(int n) { return (int)(rng() % n); }

// ---- reference class adapters (control + one tag field) ----
struct RefStep { bool rv; uint64_t head; unsigned size; };
struct RefFifo {
  virtual ~RefFifo() {}
  virtual RefStep step(bool refetch, bool rd_en, bool wr_en, uint64_t tag) = 0;
};
#define ACCUM_COMMON(acc, step) \
  acc.pop_en |= step.pop_en
struct FetchRef : RefFifo {
  RefStep step(bool refetch, bool rd_en, bool wr_en, uint64_t tag) override {
    fetch_address_FIFO_in in{}; fetch_address_FIFO_read_data rd{}, next{};
    fetch_address_FIFO_out out{}, out0{}; FetchAddrCombOut st{}, acc{};
    fetch_address_FIFO_seq_read(&in, &rd);
    unsigned size = rd.size;
    in.refetch = refetch; in.read_enable = rd_en;
    fetch_address_FIFO_comb_calc(&in, &rd, &out, &next, &st); out0 = out;
    acc.clear_fifo |= st.clear_fifo; acc.pop_en |= st.pop_en; rd = next;
    if (wr_en) {
      in.refetch = false; in.read_enable = false; in.write_enable = true; in.fetch_address = (uint32_t)tag;
      fetch_address_FIFO_comb_calc(&in, &rd, &out, &next, &st);
      acc.push_en = st.push_en; acc.push_data = st.push_data; acc.pop_en |= st.pop_en;
    }
    fetch_address_FIFO_seq_write(&acc);
    return {acc.pop_en, out0.fetch_address, size};
  }
};
struct InstRef : RefFifo {
  RefStep step(bool refetch, bool rd_en, bool wr_en, uint64_t tag) override {
    instruction_FIFO_in in{}; instruction_FIFO_read_data rd{}, next{};
    instruction_FIFO_out out{}, out0{}; InstructionCombOut st{}, acc{};
    instruction_FIFO_seq_read(&in, &rd);
    unsigned size = rd.size;
    in.refetch = refetch; in.read_enable = rd_en;
    instruction_FIFO_comb_calc(&in, &rd, &out, &next, &st); out0 = out;
    acc.clear_fifo |= st.clear_fifo; acc.pop_en |= st.pop_en; rd = next;
    if (wr_en) {
      in.refetch = false; in.read_enable = false; in.write_enable = true; in.seq_next_pc = (uint32_t)tag;
      instruction_FIFO_comb_calc(&in, &rd, &out, &next, &st);
      acc.push_en = st.push_en; acc.push_entry = st.push_entry; acc.pop_en |= st.pop_en;
    }
    instruction_FIFO_seq_write(&acc);
    return {acc.pop_en, out0.seq_next_pc, size};
  }
};
struct PtabRef : RefFifo {
  RefStep step(bool refetch, bool rd_en, bool wr_en, uint64_t tag) override {
    PTAB_in in{}; PTAB_read_data rd{}, next{};
    PTAB_out out{}, out0{}; PtabCombOut st{}, acc{};
    PTAB_seq_read(&in, &rd);
    unsigned size = rd.size;
    in.refetch = refetch; in.read_enable = rd_en;
    PTAB_comb_calc(&in, &rd, &out, &next, &st); out0 = out;
    acc.clear_ptab |= st.clear_ptab; acc.pop_en |= st.pop_en; rd = next;
    if (wr_en) {
      in.refetch = false; in.read_enable = false; in.write_enable = true; in.predict_next_fetch_address = (uint32_t)tag;
      PTAB_comb_calc(&in, &rd, &out, &next, &st);
      acc.push_write_en = st.push_write_en; acc.push_write_entry = st.push_write_entry; acc.pop_en |= st.pop_en;
    }
    PTAB_seq_write(&acc);
    return {acc.pop_en, out0.predict_next_fetch_address, size};
  }
};
struct F2bRef : RefFifo {
  RefStep step(bool refetch, bool rd_en, bool wr_en, uint64_t tag) override {
    front2back_FIFO_in in{}; front2back_FIFO_read_data rd{}, next{};
    front2back_FIFO_out out{}, out0{}; Front2BackCombOut st{}, acc{};
    front2back_FIFO_seq_read(&in, &rd);
    unsigned size = rd.size;
    in.refetch = refetch; in.read_enable = rd_en;
    front2back_FIFO_comb_calc(&in, &rd, &out, &next, &st); out0 = out;
    acc.clear_fifo |= st.clear_fifo; acc.pop_en |= st.pop_en; rd = next;
    if (wr_en) {
      in.refetch = false; in.read_enable = false; in.write_enable = true;
      in.predict_next_fetch_address_corrected = (uint32_t)tag;
      front2back_FIFO_comb_calc(&in, &rd, &out, &next, &st);
      acc.push_en = st.push_en; acc.push_entry = st.push_entry; acc.pop_en |= st.pop_en;
    }
    front2back_FIFO_seq_write(&acc);
    return {acc.pop_en, out0.predict_next_fetch_address_corrected, size};
  }
};

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "gen.trc";
  rng.seed(argc > 2 ? strtoull(argv[2], 0, 0) : 1);
  int ncyc = argc > 3 ? atoi(argv[3]) : 100000;
  GEN_OPEN(out)
  const std::string mod = kModule;
  RefFifo *ref = nullptr;
  const char *tagname = nullptr;
  int depth = 0, full_at = 0;
  if (mod == "fetch_addr_fifo") { ref = new FetchRef; tagname = "wr_fetch_address"; depth = 16; full_at = 15; }
  if (mod == "inst_fifo")       { ref = new InstRef;  tagname = "wr_seq_next_pc"; depth = 16; full_at = 16; }
  if (mod == "ptab")            { ref = new PtabRef;  tagname = "wr_predict_next_fetch_address"; depth = 16; full_at = 15; }
  if (mod == "front2back_fifo") { ref = new F2bRef;  tagname = "wr_predict_next_fetch_address_corrected"; depth = 32; full_at = 32; }
  if (!ref) { std::fprintf(stderr, "unknown module %s\n", kModule); return 1; }

  // pair wr_X (in) with rd_X (out)
  struct Pair { int w, r; };
  std::vector<Pair> pairs; int tag_pair = -1;
  for (int i = 0; i < (int)kNumFields; i++) {
    std::string n = kFields[i].name;
    if (kFields[i].is_out || n.rfind("wr_", 0) || n == "wr_en") continue;
    std::string rn = "rd_" + n.substr(3);
    pairs.push_back({i, ids.at(rn)});
    if (n == tagname) tag_pair = (int)pairs.size() - 1;
  }
  if (tag_pair < 0) { std::fprintf(stderr, "tag field missing\n"); return 1; }
  typedef std::vector<uint64_t> Entry;                 // all elements of all paired fields, concatenated
  std::deque<Entry> q;
  uint64_t n_push = 0, n_pop = 0, n_clear_nonempty = 0, n_clear_push = 0, n_full = 0, n_full_cyc = 0, n_empty_rd = 0, n_dropped = 0;
  unsigned max_size = 0;
  int p_wr = 50, p_rd = 50, p_clr = 1, regime_left = 0;
  for (int c = 0; c < ncyc; c++) {
    if (regime_left-- <= 0) {          // change the traffic regime every ~50-400 cycles
      regime_left = 50 + R(350);
      switch (R(6)) {
        case 0: p_wr = 90; p_rd = 15; break;   // fill up (reaches full)
        case 1: p_wr = 15; p_rd = 90; break;   // drain (reaches empty)
        case 2: p_wr = 50; p_rd = 50; break;
        case 3: p_wr = 100; p_rd = 100; break; // steady 1-in-1-out
        case 4: p_wr = 100; p_rd = 0; break;   // push only: forces full
        default: p_wr = 60; p_rd = 70; break;
      }
      p_clr = R(3) == 0 ? 8 : (R(2) ? 1 : 0);
    }
    bool refetch = R(100) < p_clr;
    bool rd_en = R(100) < p_rd;
    bool wr_en = R(100) < p_wr;
    size_t size_after_clear = refetch ? 0 : q.size();
    if (wr_en && size_after_clear >= (size_t)depth) { wr_en = false; n_dropped++; }   // illegal: overflow
    Entry e;
    for (auto &p : pairs) {
      const ttg::FieldInfo &f = kFields[p.w];
      for (int k = 0; k < f.nelem; k++) {
        uint64_t v = R64();
        if (f.width < 64) v &= (1ull << f.width) - 1;
        e.push_back(v);
      }
    }
    // reference class, one step in lock step
    uint64_t tag = e[0];
    { size_t off = 0; for (int i = 0; i < tag_pair; i++) off += kFields[pairs[i].w].nelem; tag = e[off]; }
    RefStep rs = ref->step(refetch, rd_en, wr_en, tag);
    // golden
    bool rd_valid = rd_en && !refetch && !q.empty();
    bool full = q.size() >= (size_t)full_at, empty = q.empty();
    if (rs.size != q.size()) { std::fprintf(stderr, "cycle %d: size ref=%u golden=%zu\n", c, rs.size, q.size()); return 1; }
    if (rs.rv != rd_valid) { std::fprintf(stderr, "cycle %d: rd_valid ref=%d golden=%d\n", c, rs.rv, rd_valid); return 1; }
    if (rd_valid) {
      size_t off = 0; for (int i = 0; i < tag_pair; i++) off += kFields[pairs[i].w].nelem;
      if (q.front()[off] != rs.head) { std::fprintf(stderr, "cycle %d: head tag ref=%llx golden=%llx\n", c, (unsigned long long)rs.head, (unsigned long long)q.front()[off]); return 1; }
    }
    // record
    S("refetch", 0, refetch); S("rd_en", 0, rd_en); S("wr_en", 0, wr_en);
    { size_t off = 0; for (auto &p : pairs) { const ttg::FieldInfo &f = kFields[p.w]; for (int k = 0; k < f.nelem; k++) tw->set(p.w, k, e[off++]); } }
    S("rd_valid", 0, rd_valid); S("full", 0, full); S("empty", 0, empty);
    if (rd_valid) {
      size_t off = 0;
      for (auto &p : pairs) { const ttg::FieldInfo &f = kFields[p.r]; for (int k = 0; k < f.nelem; k++) tw->set(p.r, k, q.front()[off++]); }
    }
    commit_cycle();
    // statistics + state update: clear -> push -> pop
    if (refetch && !q.empty()) n_clear_nonempty++;
    if (refetch) q.clear();
    if (wr_en) { q.push_back(e); n_push++; if (refetch) n_clear_push++; }
    if (rd_valid) { q.pop_front(); n_pop++; }
    if (rd_en && !rd_valid && empty && !refetch) n_empty_rd++;
    if (full) n_full_cyc++;
    if (q.size() > max_size) max_size = q.size();
  }
  w.flush();
  std::printf("%s: %llu records; push %llu pop %llu clear(non-empty) %llu clear+push %llu full-flag cycles %llu max size %u "
              "read-when-empty %llu dropped(illegal) pushes %llu\n", kModule, (unsigned long long)g_cycle, (unsigned long long)n_push,
              (unsigned long long)n_pop, (unsigned long long)n_clear_nonempty, (unsigned long long)n_clear_push,
              (unsigned long long)n_full_cyc, max_size, (unsigned long long)n_empty_rd, (unsigned long long)n_dropped);
  (void)n_full;
  return 0;
}
