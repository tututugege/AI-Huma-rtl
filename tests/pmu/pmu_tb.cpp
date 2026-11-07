// Random test of rtl/pmu/pmu.sv against a C++ model of the same CSR/counter semantics (EXP-013).
// Per cycle: random event increments (within each event's width), random CSR traffic on the PMU addresses
// (reads every cycle, writes now and then, machine and user privilege). Compares csr_hit / csr_rdata / csr_illegal
// every cycle and all counters at the end. Mutation hook: PMU_TB_MUTATE=1 corrupts the model's inhibit rule, the test
// must then fail (checks that the check itself can fail).
#include "Vpmu.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

constexpr int NUM_EV = 52, INC_W = 8, NUM_HPM = 8, NCNT = 2 + NUM_HPM;
static const int EV_W[NUM_EV] = {
#include "pmu_ev_widths.inc"
};

struct Model {
  uint64_t cnt[NCNT] = {};
  uint8_t ev[NUM_HPM] = {};
  uint32_t inhibit = 0, counteren = 0;
  bool mutate = false;
  static int bit_of(int i) { return i == 0 ? 0 : i == 1 ? 2 : i + 1; }
  void step(const uint8_t *inc_by_ev, uint16_t addr, bool wen, uint32_t wdata, bool m, bool &hit, uint32_t &rd, bool &ill) {
    // combinational view first (reads see the registered state)
    hit = false; rd = 0; ill = false;
    int idx = -1; bool hi = false, user = false, is_ev = false, is_en = false, is_inh = false;
    if (addr == 0x306) is_en = true;
    else if (addr == 0x320) is_inh = true;
    else if (addr >= 0x323 && addr < 0x323 + NUM_HPM) { is_ev = true; idx = addr - 0x323; }
    else if (addr == 0xB00 || addr == 0xB02 || (addr >= 0xB03 && addr < 0xB03 + NUM_HPM)) idx = addr == 0xB00 ? 0 : addr == 0xB02 ? 1 : addr - 0xB03 + 2;
    else if (addr == 0xB80 || addr == 0xB82 || (addr >= 0xB83 && addr < 0xB83 + NUM_HPM)) { hi = true; idx = addr == 0xB80 ? 0 : addr == 0xB82 ? 1 : addr - 0xB83 + 2; }
    else if (addr == 0xC00 || addr == 0xC02 || (addr >= 0xC03 && addr < 0xC03 + NUM_HPM)) { user = true; idx = addr == 0xC00 ? 0 : addr == 0xC02 ? 1 : addr - 0xC03 + 2; }
    else if (addr == 0xC80 || addr == 0xC82 || (addr >= 0xC83 && addr < 0xC83 + NUM_HPM)) { user = true; hi = true; idx = addr == 0xC80 ? 0 : addr == 0xC82 ? 1 : addr - 0xC83 + 2; }
    hit = is_en || is_inh || is_ev || idx >= 0;
    if (hit && !m && !user) ill = true;
    if (is_en) rd = counteren;
    else if (is_inh) rd = inhibit;
    else if (is_ev) rd = ev[idx];
    else if (idx >= 0) {
      rd = hi ? (uint32_t)(cnt[idx] >> 32) : (uint32_t)cnt[idx];
      if (user) { if (!m && !((counteren >> bit_of(idx)) & 1)) ill = true; if (wen) ill = true; }
    }
    // next state
    uint64_t nxt[NCNT];
    for (int i = 0; i < NCNT; i++) {
      uint32_t inc = 0;
      if (i == 0) inc = inc_by_ev[0]; else if (i == 1) inc = inc_by_ev[1];
      else for (int e = 0; e < NUM_EV; e++) if (ev[i - 2] == e + 1) inc = inc_by_ev[e];
      bool inh = (inhibit >> bit_of(i)) & 1;
      if (mutate && i == 1) inh = false;
      nxt[i] = inh ? cnt[i] : cnt[i] + inc;
    }
    uint32_t ninh = inhibit, nen = counteren;
    uint8_t nev[NUM_HPM]; for (int k = 0; k < NUM_HPM; k++) nev[k] = ev[k];
    if (wen && m && hit && !user) {
      uint32_t mask = 0; for (int i = 0; i < NCNT; i++) mask |= 1u << bit_of(i);
      if (is_en) nen = wdata & mask;
      if (is_inh) ninh = wdata & mask;
      if (is_ev) nev[idx] = wdata & 0xff;
      if (!is_en && !is_inh && !is_ev) {
        if (hi) nxt[idx] = (nxt[idx] & 0xffffffffull) | ((uint64_t)wdata << 32);
        else nxt[idx] = (nxt[idx] & ~0xffffffffull) | wdata;
      }
    }
    for (int i = 0; i < NCNT; i++) cnt[i] = nxt[i];
    inhibit = ninh; counteren = nen;
    for (int k = 0; k < NUM_HPM; k++) ev[k] = nev[k];
  }
};

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vpmu dut;
  Model m;
  m.mutate = std::getenv("PMU_TB_MUTATE") != nullptr;
  std::mt19937_64 rng(12345);
  long errors = 0, cycles = 300000;
  auto tick = [&]() { dut.clk = 0; dut.eval(); dut.clk = 1; dut.eval(); };
  dut.rst_n = 0; dut.csr_wen = 0; dut.csr_addr = 0; dut.csr_prv_m = 1;
  for (int i = 0; i < 3; i++) tick();
  dut.rst_n = 1;
  std::vector<uint16_t> addrs;
  for (uint16_t a : {0x306, 0x320, 0xB00, 0xB02, 0xB80, 0xB82, 0xC00, 0xC02, 0xC80, 0xC82, 0x305, 0x300}) addrs.push_back(a);
  for (int k = 0; k < NUM_HPM; k++) for (uint16_t b : {0x323, 0xB03, 0xB83, 0xC03, 0xC83}) addrs.push_back(b + k);
  addrs.push_back(0x323 + NUM_HPM); addrs.push_back(0xB03 + NUM_HPM);  // just outside: must not hit
  for (long c = 0; c < cycles; c++) {
    uint8_t inc[NUM_EV];
    for (int e = 0; e < NUM_EV; e++) {
      uint32_t v = (rng() % 3 == 0) ? (uint32_t)(rng() & ((1u << EV_W[e]) - 1)) : 0;
      if (e == 0) v = 1;
      inc[e] = (uint8_t)v;
      for (int b = 0; b < INC_W; b++) dut.ev_inc[(e * INC_W + b) / 32] = 0;
    }
    // pack the bus (PMU_NUM_EV lanes of INC_W bits, lane 0 at the bottom)
    for (int w = 0; w < (NUM_EV * INC_W + 31) / 32; w++) dut.ev_inc[w] = 0;
    for (int e = 0; e < NUM_EV; e++) dut.ev_inc[(e * INC_W) / 32] |= (uint32_t)inc[e] << ((e * INC_W) % 32);
    uint16_t addr = addrs[rng() % addrs.size()];
    bool wen = rng() % 6 == 0, mprv = rng() % 4 != 0;
    uint32_t wdata = (uint32_t)rng();
    if (rng() % 3 == 0 && (addr >= 0x323 && addr < 0x323 + NUM_HPM)) wdata = 1 + rng() % (NUM_EV + 2);  // plausible selectors
    if (rng() % 8 == 0 && (addr == 0xB03 || addr == 0xB83)) wdata = 0xfffffff0u;                         // carry into the high half
    dut.csr_addr = addr; dut.csr_wen = wen; dut.csr_wdata = wdata; dut.csr_prv_m = mprv;
    dut.eval();
    bool hit, ill; uint32_t rd;
    m.step(inc, addr, wen, wdata, mprv, hit, rd, ill);
    if ((bool)dut.csr_hit != hit || (bool)dut.csr_illegal != ill || (hit && !ill && dut.csr_rdata != rd)) {
      if (errors < 5) std::printf("MISMATCH cycle %ld addr %#x wen %d m %d: dut hit=%d ill=%d rd=%#x  model hit=%d ill=%d rd=%#x\n", c, addr, wen, mprv, dut.csr_hit, dut.csr_illegal, dut.csr_rdata, hit, ill, rd);
      errors++;
    }
    tick();
  }
  // final counter check through the CSR port as machine
  dut.csr_wen = 0; dut.csr_prv_m = 1;
  for (int i = 0; i < NCNT; i++) for (int hi = 0; hi < 2; hi++) {
    uint16_t a = (hi ? 0xB80 : 0xB00) + (i == 0 ? 0 : i == 1 ? 2 : i + 1);
    dut.csr_addr = a; dut.eval();
    uint32_t exp = hi ? (uint32_t)(m.cnt[i] >> 32) : (uint32_t)m.cnt[i];
    if (dut.csr_rdata != exp) { std::printf("FINAL MISMATCH counter %d %s: dut %#x model %#x\n", i, hi ? "hi" : "lo", dut.csr_rdata, exp); errors++; }
  }
  std::printf("PMU_TB %s cycles=%ld errors=%ld\n", errors ? "FAIL" : "PASS", cycles, errors);
  return errors ? 1 : 0;
}
