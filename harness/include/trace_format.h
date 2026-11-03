// Trace file format shared by the C++ recorder (simulator side) and the RTL replayer.
//
//   header : "TTGTRC01" | u32 in_bytes | u32 out_bytes | u64 spec_hash | u16 name_len | name
//   record : u64 cycle | u8 flags | in_bytes | out_bytes          (repeated)
//
// One record is the settled value of every module port at the end of that cycle's comb phase, i.e.
// after all combinational evaluation and before the clock edge (seq) that follows.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace ttg {

constexpr char kMagic[8] = {'T', 'T', 'G', 'T', 'R', 'C', '0', '1'};
constexpr uint8_t kFlagReset = 1;  // rst_n is low this cycle; outputs are not compared

struct FieldInfo {
  const char *name;
  int is_out;
  int width;
  int ndims;
  int dims[4];
  int nelem;
  int ebytes;
  int byte_off;  // within the in or out part of a record
  int when;      // index of the 1-bit field gating comparison, or -1
};

// Little-endian value <-> element bytes helpers.
inline void put_elem(uint8_t *dst, int ebytes, uint64_t v) {
  for (int i = 0; i < ebytes && i < 8; ++i) dst[i] = uint8_t(v >> (8 * i));
}
inline uint64_t get_elem(const uint8_t *src, int ebytes) {
  uint64_t v = 0;
  for (int i = 0; i < ebytes && i < 8; ++i) v |= uint64_t(src[i]) << (8 * i);
  return v;
}
// Bytes of an element with the bits above `width` cleared.
inline void mask_elem(uint8_t *p, int width, int ebytes) {
  int top = width & 7;
  if (top) p[ebytes - 1] &= uint8_t((1u << top) - 1);
}

// Writer used by the C++ simulator hook. One instance per traced module.
template <class Fields>
class TraceWriter {
 public:
  TraceWriter(const std::string &path, const char *mod, unsigned in_bytes, unsigned out_bytes,
              uint64_t hash, const Fields &fields)
      : in_(in_bytes, 0), out_(out_bytes, 0), fields_(fields) {
    f_ = std::fopen(path.c_str(), "wb");
    if (!f_) {
      std::perror(path.c_str());
      std::exit(1);
    }
    std::fwrite(kMagic, 1, 8, f_);
    uint32_t ib = in_bytes, ob = out_bytes;
    std::fwrite(&ib, 4, 1, f_);
    std::fwrite(&ob, 4, 1, f_);
    std::fwrite(&hash, 8, 1, f_);
    uint16_t n = uint16_t(std::strlen(mod));
    std::fwrite(&n, 2, 1, f_);
    std::fwrite(mod, 1, n, f_);
  }
  ~TraceWriter() {
    if (f_) std::fclose(f_);
  }
  TraceWriter(const TraceWriter &) = delete;

  // Set element `elem` (row-major flat index) of field `id`; value is the low 64 bits.
  void set(int id, int elem, uint64_t v) {
    const FieldInfo &f = fields_[id];
    uint8_t *base = (f.is_out ? out_.data() : in_.data()) + f.byte_off + elem * f.ebytes;
    put_elem(base, f.ebytes, v);
    mask_elem(base, f.width, f.ebytes);
  }
  // Wide element: little-endian 32-bit words.
  void set_words(int id, int elem, const uint32_t *w, int nwords) {
    const FieldInfo &f = fields_[id];
    uint8_t *base = (f.is_out ? out_.data() : in_.data()) + f.byte_off + elem * f.ebytes;
    std::memset(base, 0, f.ebytes);
    for (int i = 0; i < f.ebytes; ++i) {
      int wi = i / 4;
      if (wi < nwords) base[i] = uint8_t(w[wi] >> (8 * (i % 4)));
    }
    mask_elem(base, f.width, f.ebytes);
  }
  void flush() {
    if (f_) std::fflush(f_);
  }
  void commit(uint64_t cycle, uint8_t flags = 0) {
    std::fwrite(&cycle, 8, 1, f_);
    std::fwrite(&flags, 1, 1, f_);
    std::fwrite(in_.data(), 1, in_.size(), f_);
    std::fwrite(out_.data(), 1, out_.size(), f_);
    std::fill(in_.begin(), in_.end(), 0);
    std::fill(out_.begin(), out_.end(), 0);
  }

 private:
  std::FILE *f_ = nullptr;
  std::vector<uint8_t> in_, out_;
  const Fields &fields_;
};

}  // namespace ttg
