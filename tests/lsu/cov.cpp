// Port-level coverage summary for spec/lsu.io: reads .trc files and prints which events occurred (summed over files).
// Build: clang++ -std=c++17 -O2 -Iharness/include -Ibuild/lsu tests/lsu/cov.cpp -o build/lsu/cov ; run: build/lsu/cov traces/lsu/*.trc
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include "lsu_fields.h"
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
  for (int a = 1; a < argc; a++) {
    FILE *fp = fopen(argv[a], "rb");
    if (!fp) continue;
    char hdr[8]; uint32_t ib, ob; uint64_t h; uint16_t n;
    if (fread(hdr, 1, 8, fp) != 8 || fread(&ib, 4, 1, fp) != 1 || fread(&ob, 4, 1, fp) != 1 || fread(&h, 8, 1, fp) != 1 ||
        fread(&n, 2, 1, fp) != 1) continue;
    fseek(fp, n, SEEK_CUR);
    std::vector<uint8_t> rec(9 + ib + ob);
    int prev_tail_flag = -1;
    while (fread(rec.data(), 1, rec.size(), fp) == rec.size()) {
      if (rec[8] & ttg::kFlagReset) continue;
      const uint8_t *in = rec.data() + 9, *out = in + ib;
      auto G = [&](const char *nm, int e = 0) { return get(in, out, nm, e); };
      c["records"]++;
      bool fl = G("rob_bcast_flush"), mp = G("dec_bcast_mispred");
      c["flush"] += fl; c["mispred"] += mp; c["mispred&flush"] += fl && mp; c["clear_mask!=0"] += G("dec_bcast_clear_mask") != 0;
      c["committed_store_pending"] += G("lsu2rob_committed_store_pending");
      c["head_incomplete_valid"] += G("rob_bcast_head_incomplete_valid");
      c["ldq_free==0"] += G("lsu2dis_ldq_free") == 0; c["stq_free==0"] += G("lsu2dis_stq_free") == 0;
      c["ldq_free<8"] += G("lsu2dis_ldq_free") < 8;
      int tf = G("lsu2dis_stq_tail_flag"); if (prev_tail_flag >= 0 && tf != prev_tail_flag) c["stq tail flag toggles"]++; prev_tail_flag = tf;
      int na = 0, ncm = 0, nst_alloc = 0, nld_alloc = 0;
      for (int i = 0; i < 8; i++) {
        na += G("lsu2dis_ldq_alloc_valid", i);
        nst_alloc += G("dis2lsu_alloc_req", i); nld_alloc += G("dis2lsu_ldq_alloc_req", i);
        if (G("rob_commit_commit_entry_valid", i)) { int t = G("rob_commit_commit_entry_uop_type", i); if (t == 6 || (t == 18 && G("rob_commit_commit_entry_uop_amo_op", i) != 2)) ncm++; }
      }
      c["dis ldq alloc>=1"] += nld_alloc > 0; c["dis ldq alloc>=4"] += nld_alloc >= 4; c["dis stq alloc>=1"] += nst_alloc > 0;
      c["dis stq alloc>=4"] += nst_alloc >= 4; c["dis alloc & flush/mispred"] += (nst_alloc + nld_alloc) > 0 && (fl || mp);
      c["commit stores>=1"] += ncm >= 1; c["commit stores>=2"] += ncm >= 2; c["commit stores>=4"] += ncm >= 4; c["commit store & flush"] += ncm && fl;
      int nl = 0, ns = 0, nd = 0;
      for (int i = 0; i < 4; i++) {
        nd += G("exe2lsu_sdu_req_valid", i);
        if (G("exe2lsu_ldu_req_valid", i)) { nl++; if (G("exe2lsu_ldu_req_uop_is_atomic", i)) c[std::string("ld atomic amo_op ") + std::to_string(G("exe2lsu_ldu_req_uop_amo_op", i))]++; }
        if (G("exe2lsu_sta_req_valid", i)) { ns++; if (G("exe2lsu_sta_req_uop_is_atomic", i)) c[std::string("sta atomic amo_op ") + std::to_string(G("exe2lsu_sta_req_uop_amo_op", i))]++; }
      }
      c["exe ld>=1"] += nl >= 1; c["exe ld==4"] += nl == 4; c["exe sta>=1"] += ns >= 1; c["exe sta>=3"] += ns >= 3; c["exe std>=1"] += nd >= 1;
      c["exe std>=3"] += nd >= 3; c["exe ld&sta&std"] += nl && ns && nd;
      int nm_l = 0, nm_s = 0;
      for (int i = 0; i < 4; i++) {
        if (G("mmu2lsu_ldq_resp_valid", i)) { int r = G("mmu2lsu_ldq_resp_result", i); c["mmu ld result " + std::to_string(r)]++; nm_l++; }
        if (G("mmu2lsu_stq_resp_valid", i)) { int r = G("mmu2lsu_stq_resp_result", i); c["mmu st result " + std::to_string(r)]++; nm_s++; }
      }
      c["mmu ld resp>=2"] += nm_l >= 2; c["mmu st resp>=2"] += nm_s >= 2;
      for (int i = 0; i < 4; i++) {
        if (G("dcache2lsu_load_resps_valid", i)) { c["dc ld resp replay " + std::to_string(G("dcache2lsu_load_resps_replay", i))]++; if (G("dcache2lsu_load_resps_req_id", i) >> 31) c["dc ld resp non-LSU id"]++; }
        if (G("dcache2lsu_store_resps_valid", i)) c["dc st resp replay " + std::to_string(G("dcache2lsu_store_resps_replay", i))]++;
      }
      c["mshr_fill"] += G("dcache2lsu_mshr_fill");
      int nlr = 0, nsr = 0, nwl = 0, nws = 0, nwsta = 0;
      for (int i = 0; i < 4; i++) {
        nlr += G("lsu2dcache_load_ports_valid", i); nsr += G("lsu2dcache_store_ports_valid", i);
        if (G("lsu2exe_wb_req_valid", i)) { nwl++; if (G("lsu2exe_wb_req_uop_page_fault_load", i)) c["wb page_fault_load"]++; if (G("lsu2exe_wb_req_uop_page_fault_store", i)) c["wb(SC) page_fault_store"]++; if (!G("lsu2exe_wb_req_uop_dest_en", i)) c["wb dest_en=0"]++; }
        if (G("lsu2exe_sta_wb_req_valid", i)) { nwsta++; if (G("lsu2exe_sta_wb_req_uop_page_fault_store", i)) c["sta_wb page_fault_store"]++; }
        if (G("lsu2dcache_store_ports_valid", i)) { int sb = G("lsu2dcache_store_ports_strb", i); c["store strb " + std::to_string(sb)]++; }
      }
      c["dc ld req>=1"] += nlr >= 1; c["dc ld req==4"] += nlr == 4; c["dc st req>=1"] += nsr >= 1; c["dc st req>=3"] += nsr >= 3;
      c["wb ld>=1"] += nwl >= 1; c["wb ld==4"] += nwl == 4; c["wb sta>=1"] += nwsta >= 1; c["wb sta==4"] += nwsta == 4;
      (void)nws; (void)nwl; (void)na;
      if (G("peripheral_req_is_mmio")) { c[G("peripheral_req_wen") ? "periph req store" : "periph req load"]++; c["periph func3 " + std::to_string(G("peripheral_req_mmio_fun3"))]++; }
      c["periph resp ready=0"] += !G("peripheral_resp_ready"); c["periph resp is_mmio"] += G("peripheral_resp_is_mmio");
      c["periph req while !ready? (should be 0)"] += G("peripheral_req_is_mmio") && !G("peripheral_resp_ready");
    }
    fclose(fp);
  }
  for (auto &kv : c) printf("%-44s %llu\n", kv.first.c_str(), (unsigned long long)kv.second);
}
