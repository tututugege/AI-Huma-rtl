// Exu/FU coverage plugin (tier-0: reads only members visible after BackTop::comb(); NO simulator patch needed).
#include <algorithm>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#define private public
#define protected public
#include "SimCpu.h"
#undef private
#undef protected

static std::map<std::string, uint64_t> C;
static uint64_t N = ~0ull, cnt = 0;
#define CNT(k) (C[k]++)
#define CNTS(s) (C[std::string(s)]++)
static void fin() {
  for (auto &kv : C) std::printf("COV %s %llu\n", kv.first.c_str(), (unsigned long long)kv.second);
  std::printf("COV cycles %llu\n", (unsigned long long)cnt);
}
static std::string fmt(const char *f, ...) {
  char b[200]; va_list ap; va_start(ap, f); vsnprintf(b, sizeof b, f, ap); va_end(ap); return b;
}
// name of the ALU behaviour exercised by a UOP_ADD / misc uop (mirrors AluUnit::impl_compute's decision chain)
static std::string alu_name(const ExuInst &i) {
  const bool imm = i.src2_is_imm; const int f3 = i.func3, f7 = i.func7;
  if (i.op == UOP_WFI) return "wfi";
  if (i.op != UOP_ADD) return "other_op_add_default";   // ecall/ebreak/mret/sret/sfence/fence(.i): result = op1+op2
  switch (f3) {
    case 0: return (((f7 >> 5) & 1) && !imm) ? "sub" : "add";
    case 1:
      if (f7 == 0) return "sll"; if (f7 == 0x30 && !imm) return "rol"; if (f7 == 0x24) return "bclr"; if (f7 == 0x14) return "bset";
      if (f7 == 0x34) return "binv"; if (f7 == 0x05) return "clmul";
      if (f7 == 0x30 && imm) { int s = i.imm & 0x1f; return s == 0 ? "clz" : s == 1 ? "ctz" : s == 2 ? "pcnt" : s == 4 ? "sext.b" : s == 5 ? "sext.h" : "zbb_unary_other"; }
      return "sll_other";
    case 2: if (f7 == 0) return "slt"; if (f7 == 0x10 && !imm) return "sh1add"; if (f7 == 0x05 && !imm) return "clmulr"; return "slt_default";
    case 3: if (f7 == 0) return "sltu"; if (f7 == 0x05 && !imm) return "clmulh"; return "sltu_default";
    case 4: if (f7 == 0) return "xor"; if (f7 == 0x20 && !imm) return "xnor"; if (f7 == 0x10 && !imm) return "sh2add";
            if (f7 == 0x05 && !imm) return "min"; if (f7 == 0x04 && !imm) return "pack"; return "xor_default";
    case 5:
      if (f7 == 0) return "srl"; if (f7 == 0x20 && !imm) return "sra";
      if (((f7 >> 5) & 1) && imm && f7 != 0x30 && f7 != 0x24 && f7 != 0x34 && f7 != 0x14) return "srai";
      if (f7 == 0x30) return "ror"; if (f7 == 0x24) return "bext";
      if (f7 == 0x34 && imm) return ((i.imm & 0x1f) == 24) ? "rev8" : "rev8_other";
      if (f7 == 0x14 && imm) return ((i.imm & 0x1f) == 7) ? "orc.b" : "orcb_other";
      if (f7 == 0x05 && !imm) return "minu"; return "srl_default";
    case 6: if (f7 == 0) return "or"; if (f7 == 0x20 && !imm) return "orn"; if (f7 == 0x05 && !imm) return "max";
            if (f7 == 0x10 && !imm) return "sh3add"; return "or_default";
    case 7: if (f7 == 0) return "and"; if (f7 == 0x20 && !imm) return "andn"; if (f7 == 0x05 && !imm) return "maxu";
            if (f7 == 0x04 && !imm) return "packh"; return "and_default";
  }
  return "?";
}
static const char *fclass(uint32_t v) {
  uint32_t e = (v >> 23) & 0xff, m = v & 0x7fffff;
  if (e == 0xff) return m ? ((m >> 22) ? "qnan" : "snan") : "inf";
  if (e == 0) return m ? "subn" : "zero";
  return "norm";
}
static std::string fp_name(const ExuInst &i) {
  const int f7 = i.func7;
  if (f7 == 0x60) return (i.imm & 0x1f) == 0 ? "fcvt.w.s" : (i.imm & 0x1f) == 1 ? "fcvt.wu.s" : "fcvt.w_other";
  if (f7 == 0x68) return (i.imm & 0x1f) == 0 ? "fcvt.s.w" : (i.imm & 0x1f) == 1 ? "fcvt.s.wu" : "fcvt.s_other";
  switch (f7 >> 2) { case 0: return "fadd"; case 1: return "fsub"; case 2: return "fmul"; case 3: return "fdiv"; }
  if (f7 == 0x2C) return "fsqrt";
  if (f7 == 0x10) return i.func3 == 0 ? "fsgnj" : i.func3 == 1 ? "fsgnjn" : "fsgnjx";
  if (f7 == 0x14) return i.func3 == 0 ? "fmin" : "fmax";
  if (f7 == 0x50) return i.func3 == 2 ? "feq" : i.func3 == 1 ? "flt" : "fle";
  if (f7 == 0x70) return "fclass";
  return fmt("fp_other_f7_%02x", f7);
}

extern "C" void ttg_rec_cycle(SimCpu *c, uint64_t cycle) {
  static bool init = false;
  static std::string type[TOTAL_FU_COUNT];
  if (!init) {
    init = true; if (const char *e = std::getenv("CHK_N")) N = std::strtoull(e, 0, 0); std::atexit(fin);
    Exu &x = *c->back.exu;
    for (int p = 0; p < ISSUE_WIDTH; p++)
      for (auto &en : x.port_mappings[p].entries) {
        uint64_t m = en.support_mask;
        type[en.fu_idx] = m == OP_MASK_MUL ? "MUL" : m == OP_MASK_DIV ? "DIV" : m == OP_MASK_LD ? "AGU_LD" : m == OP_MASK_STA ? "AGU_STA" :
                          m == OP_MASK_STD ? "SDU" : m == OP_MASK_BR ? "BRU" : m == OP_MASK_ALU ? "ALU" : m == OP_MASK_CSR ? "CSR" : m == OP_MASK_FP ? "FPU" : "?";
      }
  }
  ++cnt;
  BackTop &bt = c->back;
  Exu &x = *bt.exu;
  const bool flush = bt.rob_bcast.flush;
  if (flush) CNT("ev_rob_flush");
  if (bt.dec_bcast.mispred) CNT("ev_dec_mispred");
  if (bt.dec_bcast.clear_mask) CNT("ev_dec_clear_mask");
  if (bt.exu2id.mispred) CNT("ev_exu_mispred_out");
  if (bt.exu2id.clear_mask) CNT("ev_exu_clear_mask_out");
  int ncompl_total = 0;
  for (int p = 0; p < ISSUE_WIDTH; p++) {
    int ncomplete_on_port = 0;
    for (auto &en : x.port_mappings[p].entries) if (x.in.fu2exu->entry[en.fu_idx].complete) ncomplete_on_port++;
    if (ncomplete_on_port > 1) CNTS(fmt("ev_port%d_multi_complete", p));
    ncompl_total += ncomplete_on_port ? 1 : 0;
    if (bt.exu2rob.entry[p].valid) CNT("ev_exu2rob_valid");
    if (bt.exe2prf.entry[p].valid) CNT("ev_exe2prf_entry_valid");
  }
  C["max_ports_completing"] = std::max<uint64_t>(C["max_ports_completing"], ncompl_total);
  int nb = 0, nmisp = 0;
  for (int i = 0; i < TOTAL_FU_COUNT; i++) if (bt.exe2prf.bypass[i].valid) nb++;
  C["max_bypass_valid"] = std::max<uint64_t>(C["max_bypass_valid"], nb);
  // lsu writeback into exu
  for (int i = 0; i < LSU_LOAD_WB_WIDTH; i++) if (bt.lsu2exe.wb_req[i].valid) CNT("ev_lsu_load_wb");
  for (int i = 0; i < LSU_STA_COUNT; i++) if (bt.lsu2exe.sta_wb_req[i].valid) CNT("ev_lsu_sta_wb");
  for (int i = 0; i < LSU_AGU_COUNT; i++) if (bt.exe2lsu.agu_req[i].valid) CNT("ev_exe2lsu_agu");
  for (int i = 0; i < LSU_SDU_COUNT; i++) if (bt.exe2lsu.sdu_req[i].valid) CNT("ev_exe2lsu_sdu");
  if (bt.exe2csr.we || bt.exe2csr.re) CNT("ev_exe2csr_active");
  if (bt.exe2csr.we && bt.exe2csr.re) CNT("ev_exe2csr_we_and_re");
  // per FU
  for (int i = 0; i < TOTAL_FU_COUNT; i++) {
    AbstractFU *fu = x.units[i];
    const auto &fin_ = fu->in;                       // FuInput after comb (en/consume/flush/masks/inst)
    const auto &fo = x.in.fu2exu->entry[i];          // FuOutput after consume (ready) / issue (complete, inst)
    const std::string &T = type[i];
    if (x.fu_inst_r[i].valid) CNTS("slot_valid_" + T);
    if (fo.complete && !fin_.consume) CNTS("fu_complete_not_consumed_" + T);   // result waits (arbitration loss / flush)
    if (x.fu_inst_r[i].valid && !fo.ready) CNTS("slot_held_fu_not_ready_" + T);
    if (!fin_.en) continue;
    const ExuInst &in = fin_.inst;
    // accepted?  single-cycle FUs: always; MUL/DIV/FPU: only when the unit actually took it
    bool accepted = true;
    if (T == "DIV" || T == "FPU") { auto *f = dynamic_cast<IterativeFU *>(fu); accepted = f && !f->busy && f->busy_1; }
    else if (T == "MUL") { auto *f = dynamic_cast<FixedLatencyFU *>(fu); accepted = f && (f->pipeline_1.size() + (fin_.consume && x.in.fu2exu->entry[i].complete ? 1 : 0) > f->pipeline.size()); }
    if (!accepted) { CNTS("fu_en_not_accepted_" + T); continue; }
    CNTS("fu_accept_" + T);
    if (T == "ALU") CNTS("alu_" + alu_name(in));
    else if (T == "BRU") {
      std::string k = in.op == UOP_JUMP ? (in.src1_en ? "jalr" : "jal") : fmt("br_f3_%d", (int)in.func3);
      CNTS("bru_" + k);
      const ExuInst &res = fo.inst;   // BRU is single-cycle: fo.inst holds the computed result
      CNTS("bru_" + k + (res.br_taken ? "_taken" : "_nt"));
      if (res.mispred) CNTS("bru_" + k + "_mispred");
      if (in.src2_en == 0 && in.op == UOP_BR) CNT("bru_br_src2_en0");
    } else if (T == "MUL") CNTS(fmt("mul_f3_%d", (int)in.func3));
    else if (T == "DIV") {
      CNTS(fmt("div_f3_%d", (int)in.func3));
      int32_t a = in.src1_rdata, b = in.src2_rdata;
      if (b == 0) CNTS(fmt("div_f3_%d_by_zero", (int)in.func3));
      if (a == INT32_MIN && b == -1) CNTS(fmt("div_f3_%d_overflow", (int)in.func3));
    } else if (T == "AGU_LD" || T == "AGU_STA") { if (in.is_atomic) CNTS(T + "_atomic"); CNTS(fmt("%s_f3_%d", T.c_str(), (int)in.func3)); }
    else if (T == "SDU") { if (in.is_atomic) CNTS(fmt("sdu_amo_%d", (int)(in.func7 >> 2))); else CNT("sdu_store"); }
    else if (T == "CSR") { CNTS(fmt("csr_f3_%d", (int)in.func3)); }
    else if (T == "FPU") {
      std::string n = fp_name(in);
      CNTS("fp_" + n);
      CNTS(fmt("fp_rm_%d", in.func3));
      if (in.op != UOP_FP) CNT("fp_nonfp_op");
      if (n == "fadd" || n == "fsub" || n == "fmul" || n == "fdiv" || n == "fsqrt" || n[0] == 'f' ) {
        CNTS(std::string("fp_opA_") + fclass(in.src1_rdata));
        if (n == "fadd" || n == "fsub" || n == "fmul" || n == "fdiv") CNTS(std::string("fp_opB_") + fclass(in.src2_rdata));
      }
    }
  }
  if (cnt >= N) { fin(); std::fflush(stdout); std::_Exit(0); }
}
