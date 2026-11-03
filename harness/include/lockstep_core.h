// Shared helpers for live lock-step co-simulation (plugin loaded into the reference simulator): drive the Verilated
// <mod>_tbwrap with the reference's inputs of the current cycle and compare every output bit immediately.
// (replay_main.cpp has its own copy of poke/peek/compare for trace replay.)
#pragma once
#include "trace_format.h"
#include "verilated.h"

#include <cinttypes>
#include <cstdio>
#include <string>
#include <vector>

namespace ttg {

// Same set/set_words API as TraceWriter, but into memory only.
class BufWriter {
 public:
  template <class Fields>
  BufWriter(const Fields &f, unsigned in_bytes, unsigned out_bytes) : in_(in_bytes, 0), out_(out_bytes, 0), f_(f) {}
  void set(int id, int elem, uint64_t v) {
    const FieldInfo &f = f_[id];
    uint8_t *base = (f.is_out ? out_.data() : in_.data()) + f.byte_off + elem * f.ebytes;
    put_elem(base, f.ebytes, v);
    mask_elem(base, f.width, f.ebytes);
  }
  void set_words(int id, int elem, const uint32_t *w, int nwords) {
    const FieldInfo &f = f_[id];
    uint8_t *base = (f.is_out ? out_.data() : in_.data()) + f.byte_off + elem * f.ebytes;
    std::memset(base, 0, f.ebytes);
    for (int i = 0; i < f.ebytes; ++i) {
      int wi = i / 4;
      if (wi < nwords) base[i] = uint8_t(w[wi] >> (8 * (i % 4)));
    }
    mask_elem(base, f.width, f.ebytes);
  }
  void clear() {
    std::fill(in_.begin(), in_.end(), 0);
    std::fill(out_.begin(), out_.end(), 0);
  }
  const std::vector<uint8_t> &in() const { return in_; }
  const std::vector<uint8_t> &out() const { return out_; }

 private:
  std::vector<uint8_t> in_, out_;
  const FieldInfo *f_;
};

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

inline std::string hexstr(const uint8_t *p, int ebytes) {
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

inline std::string elem_name(const FieldInfo &f, int elem) {
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

// Compare one cycle; returns the number of mismatching elements (prints up to max_print).
template <size_t N>
int compare_cycle(const FieldInfo (&F)[N], const std::vector<uint8_t> &ref_in, const std::vector<uint8_t> &ref_out,
                  const uint8_t *got, uint64_t cycle, int max_print) {
  int bad = 0;
  for (const auto &f : F) {
    if (!f.is_out) continue;
    for (int e = 0; e < f.nelem; ++e) {
      if (f.when >= 0) {
        const auto &w = F[f.when];
        int we = (w.nelem == 1) ? 0 : e;
        const std::vector<uint8_t> &src = w.is_out ? ref_out : ref_in;
        if (!(src[w.byte_off + we * w.ebytes] & 1)) continue;
      }
      std::vector<uint8_t> a(&ref_out[f.byte_off + e * f.ebytes], &ref_out[f.byte_off + e * f.ebytes] + f.ebytes);
      std::vector<uint8_t> b(got + f.byte_off + e * f.ebytes, got + f.byte_off + (e + 1) * f.ebytes);
      mask_elem(a.data(), f.width, f.ebytes);
      mask_elem(b.data(), f.width, f.ebytes);
      if (a != b) {
        ++bad;
        if (bad <= max_print)
          std::printf("  MISMATCH cycle=%" PRIu64 " %s: ref=%s rtl=%s\n", cycle, elem_name(f, e).c_str(),
                      hexstr(a.data(), f.ebytes).c_str(), hexstr(b.data(), f.ebytes).c_str());
      }
    }
  }
  return bad;
}

template <size_t N>
void print_inputs(const FieldInfo (&F)[N], const std::vector<uint8_t> &in) {
  std::printf("  inputs this cycle (non-zero):\n");
  for (const auto &f : F) {
    if (f.is_out) continue;
    for (int e = 0; e < f.nelem; ++e) {
      const uint8_t *p = &in[f.byte_off + e * f.ebytes];
      bool nz = false;
      for (int i = 0; i < f.ebytes; ++i) nz |= p[i] != 0;
      if (nz) std::printf("    %s = %s\n", elem_name(f, e).c_str(), hexstr(p, f.ebytes).c_str());
    }
  }
}

}  // namespace ttg
