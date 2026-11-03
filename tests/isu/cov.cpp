// Trace coverage summary for spec/isu.io: reads .trc files, prints which events occurred (per file totals are summed).
// Build: clang++ -std=c++17 -O2 -Iharness/include -Ibuild/isu tests/isu/cov.cpp -o build/isu/cov ; run: build/isu/cov traces/isu/*.trc
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include "isu_fields.h"
using namespace ttg_io;

static std::map<std::string, int> ids;
static uint64_t get(const uint8_t *in, const uint8_t *out, const char *n, int e = 0) {
  const ttg::FieldInfo &f = kFields[ids.at(n)];
  const uint8_t *b = (f.is_out ? out : in) + f.byte_off + e * f.ebytes;
  return ttg::get_elem(b, f.ebytes);
}

int main(int argc, char **argv) {
  for (int i = 0; i < (int)kNumFields; i++) ids[kFields[i].name] = i;
  std::map<std::string, uint64_t> c;
  const int IQ_SIZE[5] = {128, 64, 64, 64, 64};
  for (int a = 1; a < argc; a++) {
    FILE *fp = fopen(argv[a], "rb");
    if (!fp) continue;
    char hdr[8]; uint32_t ib, ob; uint64_t h; uint16_t n;
    if (fread(hdr, 1, 8, fp) != 8 || fread(&ib, 4, 1, fp) != 1 || fread(&ob, 4, 1, fp) != 1 || fread(&h, 8, 1, fp) != 1 ||
        fread(&n, 2, 1, fp) != 1) continue;
    fseek(fp, n, SEEK_CUR);
    std::vector<uint8_t> rec(9 + ib + ob);
    while (fread(rec.data(), 1, rec.size(), fp) == rec.size()) {
      if (rec[8] & ttg::kFlagReset) continue;
      const uint8_t *in = rec.data() + 9, *out = in + ib;
      c["records"]++;
      bool fl = get(in, out, "rob_bcast_flush"), mp = get(in, out, "dec_bcast_mispred");
      c["flush"] += fl; c["mispred"] += mp; c["mispred&flush"] += fl && mp;
      c["clear_mask!=0"] += get(in, out, "dec_bcast_clear_mask") != 0;
      c["mispred&!flush&clear!=0"] += mp && !fl && get(in, out, "dec_bcast_clear_mask") != 0;
      int enq_total = 0, nw = 0, nwfast = 0;
      for (int q = 0; q < 5; q++) {
        int ne = 0;
        for (int w = 0; w < 8; w++) ne += get(in, out, "dis2iss_req_valid", q * 8 + w);
        enq_total += ne;
        int rn = get(in, out, "iss2dis_ready_num", q);
        std::string qs = "q" + std::to_string(q);
        c[qs + " enq lanes>0"] += ne > 0;
        c[qs + " enq lanes>=4"] += ne >= 4;
        c[qs + " free==0"] += rn == 0;
        c[qs + " free<=8"] += rn <= 8;
        c[qs + " occupancy>=half"] += (IQ_SIZE[q] - rn) * 2 >= IQ_SIZE[q];
        c[qs + " enq&flush"] += ne > 0 && (fl || mp);
        c[qs + " enq at free==lanes"] += ne > 0 && ne == rn;
      }
      c["enq any"] += enq_total > 0;
      for (int k = 0; k < 15; k++) {
        bool v = get(in, out, "iss_awake_wake_valid", k);
        nw += v;
        if (k < 4) c["wake ld ch"] += v; else if (k < 6) c["wake mul ch"] += v; else if (k < 8) c["wake div ch"] += v;
        else if (k < 9) c["wake fp ch"] += v; else { c["wake fast ch"] += v; nwfast += v; }
      }
      c["wake>=2 same cycle"] += nw >= 2; c["wake>=5 same cycle"] += nw >= 5;
      c["wake mul ch1"] += get(in, out, "iss_awake_wake_valid", 5);
      c["wake div ch1"] += get(in, out, "iss_awake_wake_valid", 7);
      int ng = 0;
      for (int p = 0; p < 22; p++) {
        bool v = get(in, out, "iss2prf_iss_entry_valid", p);
        ng += v;
        if (!v) continue;
        int op = get(in, out, "iss2prf_iss_entry_uop_op", p);
        c["issue op" + std::to_string(op)]++;
        c["issue port" + std::to_string(p)]++;
        if (get(in, out, "iss2prf_iss_entry_uop_dest_en", p) && (op == 14 || op == 15 || op == 17)) c["issue delayed-wake op"]++;
      }
      c["issue>=4 same cycle"] += ng >= 4;
      c["issue>=8 same cycle"] += ng >= 8;
    }
    fclose(fp);
  }
  for (auto &kv : c) printf("%-32s %llu\n", kv.first.c_str(), (unsigned long long)kv.second);
}
