// Generic trace replayer: drives a Verilated <mod>_tbwrap with the recorded inputs of every cycle and
// compares each output with what the C++ reference produced.
//
// Build-time macros (set by harness/Makefile):
//   TOP_HDR     e.g. "Vtoy_fifo_tbwrap.h"        TOP_T   e.g. Vtoy_fifo_tbwrap
//   FIELDS_HDR  e.g. "toy_fifo_fields.h"
//
// Usage: replay <trace> [--max-fail N] [--max-records N] [--vcd file] [--vcd-window N] [--quiet]
//   Per cycle:  apply inputs -> eval -> compare outputs -> posedge clk.
//   On the first mismatching cycle the run is repeated from scratch with a VCD of the last
//   --vcd-window cycles (default 32) so the failure can be inspected without tracing the whole run.
#include TOP_HDR
#include FIELDS_HDR
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cinttypes>
#include <memory>

using namespace ttg_io;

namespace {

// ---- raw port access: Verilator uses uintN_t for <= 64 bits and VlWide<N> beyond ----
template <class T>
void poke(T &port, const uint8_t *src, unsigned nbytes) {
  T v = 0;
  std::memcpy(&v, src, nbytes < sizeof(T) ? nbytes : sizeof(T));
  port = v;
}
template <size_t N>
void poke(VlWide<N> &port, const uint8_t *src, unsigned nbytes) {
  std::memset(port.data(), 0, N * 4);
  std::memcpy(port.data(), src, nbytes < N * 4 ? nbytes : N * 4);
}
template <class T>
void peek(const T &port, uint8_t *dst, unsigned nbytes) {
  T v = port;
  std::memset(dst, 0, nbytes);
  std::memcpy(dst, &v, nbytes < sizeof(T) ? nbytes : sizeof(T));
}
template <size_t N>
void peek(const VlWide<N> &port, uint8_t *dst, unsigned nbytes) {
  std::memset(dst, 0, nbytes);
  std::memcpy(dst, port.data(), nbytes < N * 4 ? nbytes : N * 4);
}

std::string hexstr(const uint8_t *p, int ebytes) {
  std::string s = "0x";
  bool lead = true;
  char b[4];
  for (int i = ebytes - 1; i >= 0; --i) {
    if (lead && p[i] == 0 && i != 0) continue;
    std::snprintf(b, sizeof b, lead ? "%x" : "%02x", p[i]);
    s += b;
    lead = false;
  }
  return s;
}

std::string elem_name(const ttg::FieldInfo &f, int elem) {
  std::string s = f.name;
  int idx[4] = {0, 0, 0, 0};
  int rem = elem;
  for (int d = f.ndims - 1; d >= 0; --d) {
    idx[d] = rem % f.dims[d];
    rem /= f.dims[d];
  }
  for (int d = 0; d < f.ndims; ++d) s += "[" + std::to_string(idx[d]) + "]";
  return s;
}

struct Args {
  const char *trace = nullptr;
  const char *vcd = nullptr;
  uint64_t max_records = ~0ull;
  int max_fail = 8;
  int vcd_window = 32;
  bool quiet = false;
};

struct Rec {
  uint64_t cycle;
  uint8_t flags;
  std::vector<uint8_t> in, out;
};

bool read_trace(const char *path, std::vector<Rec> &recs, uint64_t max) {
  std::FILE *f = std::fopen(path, "rb");
  if (!f) {
    std::perror(path);
    return false;
  }
  char magic[8];
  uint32_t ib, ob;
  uint64_t hash;
  uint16_t n;
  if (std::fread(magic, 1, 8, f) != 8 || std::memcmp(magic, ttg::kMagic, 8) != 0) {
    std::fprintf(stderr, "%s: bad magic\n", path);
    return false;
  }
  if (std::fread(&ib, 4, 1, f) != 1 || std::fread(&ob, 4, 1, f) != 1 || std::fread(&hash, 8, 1, f) != 1 ||
      std::fread(&n, 2, 1, f) != 1) {
    std::fprintf(stderr, "%s: truncated header\n", path);
    return false;
  }
  std::string name(n, '\0');
  if (n && std::fread(&name[0], 1, n, f) != n) return false;
  if (name != kModule || ib != kInBytes || ob != kOutBytes || hash != kSpecHash) {
    std::fprintf(stderr,
                 "%s: trace is for module '%s' (in=%u out=%u hash=%016" PRIx64
                 ") but this harness is built for '%s' (in=%u out=%u hash=%016llx)\n"
                 "  -> the spec changed since the trace was recorded; re-record the trace\n",
                 path, name.c_str(), ib, ob, hash, kModule, kInBytes, kOutBytes, kSpecHash);
    return false;
  }
  Rec r;
  r.in.resize(ib);
  r.out.resize(ob);
  while (recs.size() < max && std::fread(&r.cycle, 8, 1, f) == 1) {
    if (std::fread(&r.flags, 1, 1, f) != 1 || std::fread(r.in.data(), 1, ib, f) != ib ||
        std::fread(r.out.data(), 1, ob, f) != ob) {
      std::fprintf(stderr, "%s: truncated record %zu\n", path, recs.size());
      return false;
    }
    recs.push_back(r);
  }
  std::fclose(f);
  return true;
}

// Compare the DUT outputs of one cycle with the recorded ones; return the number of mismatches.
int compare(const Rec &r, const uint8_t *got, int max_print, bool quiet, size_t rec_idx) {
  int bad = 0;
  for (const auto &f : kFields) {
    if (!f.is_out) continue;
    for (int e = 0; e < f.nelem; ++e) {
      if (f.when >= 0) {
        const auto &w = kFields[f.when];
        int we = (w.nelem == 1) ? 0 : e;
        const std::vector<uint8_t> &src = w.is_out ? r.out : r.in;  // the qualifier may be an input or an output
        if (!(src[w.byte_off + we * w.ebytes] & 1)) continue;
      }
      std::vector<uint8_t> a(&r.out[f.byte_off + e * f.ebytes], &r.out[f.byte_off + e * f.ebytes] + f.ebytes);
      std::vector<uint8_t> b(got + f.byte_off + e * f.ebytes, got + f.byte_off + (e + 1) * f.ebytes);
      ttg::mask_elem(a.data(), f.width, f.ebytes);
      ttg::mask_elem(b.data(), f.width, f.ebytes);
      if (a != b) {
        ++bad;
        if (!quiet && bad <= max_print)
          std::printf("  MISMATCH rec=%zu cycle=%" PRIu64 " %s: ref=%s rtl=%s\n", rec_idx, r.cycle,
                      elem_name(f, e).c_str(), hexstr(a.data(), f.ebytes).c_str(),
                      hexstr(b.data(), f.ebytes).c_str());
      }
    }
  }
  return bad;
}

void print_inputs(const Rec &r) {
  std::printf("  inputs this cycle (non-zero):\n");
  for (const auto &f : kFields) {
    if (f.is_out) continue;
    for (int e = 0; e < f.nelem; ++e) {
      const uint8_t *p = &r.in[f.byte_off + e * f.ebytes];
      bool nz = false;
      for (int i = 0; i < f.ebytes; ++i) nz |= p[i] != 0;
      if (nz) std::printf("    %s = %s\n", elem_name(f, e).c_str(), hexstr(p, f.ebytes).c_str());
    }
  }
}

// Replays recs; returns index of the first failing record or -1. With vcd != null traces records
// [vcd_from, ...).
long replay(const std::vector<Rec> &recs, const Args &a, const char *vcd, size_t vcd_from, bool report) {
  // one context per pass: a second model must not join the first pass's trace file
  auto ctx = std::make_unique<VerilatedContext>();
  ctx->traceEverOn(true);
  auto top = std::make_unique<TOP_T>(ctx.get());
  std::unique_ptr<VerilatedVcdC> tfp;
  uint64_t t = 0;
  if (vcd) {
    tfp = std::make_unique<VerilatedVcdC>();
    top->trace(tfp.get(), 99);
    tfp->open(vcd);
  }
  std::vector<uint8_t> got(kOutBytes);
  long first_bad = -1;
  auto dump = [&](bool on) {
    if (tfp && on) tfp->dump(t);
    ++t;
  };
  top->clk = 0;
  for (size_t i = 0; i < recs.size(); ++i) {
    const Rec &r = recs[i];
    const bool tr = tfp && i >= vcd_from;
    top->rst_n = (r.flags & ttg::kFlagReset) ? 0 : 1;
    poke(top->in_bits, r.in.data(), kInBytes);
    top->eval();
    peek(top->out_bits, got.data(), kOutBytes);
    if (!(r.flags & ttg::kFlagReset)) {
      int bad = compare(r, got.data(), a.max_fail, !report || a.quiet, i);
      if (bad && first_bad < 0) {
        first_bad = long(i);
        if (report) {
          std::printf("FAIL %s: first mismatch at record %zu (cycle %" PRIu64 "), %d field(s)\n", kModule, i,
                      r.cycle, bad);
          print_inputs(r);
        }
        if (!tfp) return first_bad;
      }
    }
    dump(tr);  // settled values of this cycle, before the edge
    top->clk = 1;
    top->eval();
    dump(tr);
    top->clk = 0;
    top->eval();
    if (tfp && first_bad >= 0) break;  // traced up to and including the failing cycle
  }
  top->final();
  if (tfp) tfp->close();
  return first_bad;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Args a;
  for (int i = 1; i < argc; ++i) {
    std::string s = argv[i];
    if (s == "--max-fail" && i + 1 < argc) a.max_fail = std::atoi(argv[++i]);
    else if (s == "--max-records" && i + 1 < argc) a.max_records = std::strtoull(argv[++i], nullptr, 0);
    else if (s == "--vcd" && i + 1 < argc) a.vcd = argv[++i];
    else if (s == "--vcd-window" && i + 1 < argc) a.vcd_window = std::atoi(argv[++i]);
    else if (s == "--quiet") a.quiet = true;
    else if (s[0] != '-') a.trace = argv[i];
    else {
      std::fprintf(stderr, "unknown option %s\n", argv[i]);
      return 2;
    }
  }
  if (!a.trace) {
    std::fprintf(stderr, "usage: %s <trace> [--max-fail N] [--max-records N] [--vcd f] [--vcd-window N] [--quiet]\n",
                 argv[0]);
    return 2;
  }
  std::vector<Rec> recs;
  if (!read_trace(a.trace, recs, a.max_records)) return 2;
  long bad = replay(recs, a, nullptr, 0, true);
  if (bad < 0) {
    std::printf("PASS %s: %zu records\n", kModule, recs.size());
    return 0;
  }
  if (a.vcd) {
    size_t from = size_t(bad) > size_t(a.vcd_window) ? size_t(bad) - a.vcd_window : 0;
    replay(recs, a, a.vcd, from, false);
    std::printf("  waveform of records %zu..%ld written to %s\n", from, bad, a.vcd);
  }
  return 1;
}
