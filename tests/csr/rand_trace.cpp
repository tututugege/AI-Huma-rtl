// Constrained-random trace generator for the csr module: drives the *reference* Csr class (back-end/Exu/Csr.cpp) in the
// BackTop::comb() call order and records spec/csr.io fields. Reaches what the real programs barely touch: every
// trap/xRET kind in every privilege, delegation combinations, interrupt pending/enable/delegation combinations,
// vectored mtvec/stvec, every CSR address with csrrw/csrrs/csrrc, inject toggling, staged-write corner cases.
//   usage: rand_trace <out.trc> <seed> <cycles> <profile 0..3>
// Stimulus legality (from Rob.cpp comb_commit): per cycle at most ONE of {interrupt_resp (only when csr2rob.interrupt_req),
// ecall, mret, sret, page_fault_inst/load/store, illegal_inst, CSR commit}; rob_bcast.exception = ecall|pf|illegal|resp.
// mret never executes with MPP==2 (reserved privilege level; the reference then neither traps on ecall nor defines trap_pc).
// Profile 3 additionally lets a CSR commit coincide with a trap/xRET and a new execute-stage write coincide with a
// commit (the Csr class accepts both; the real ROB/EXU never produce them), to pin the reference's merge priorities.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <random>
#include <string>
#include "Csr.h"
#include "csr_fields.h"
using namespace ttg_io;

long long sim_time = 0;
static ttg::TraceWriter<decltype(kFields)> *tw;
static std::map<std::string, int> ids;
static void S(const char *n, uint64_t v) { tw->set(ids.at(n), 0, v); }

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "rand.trc";
  uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
  int ncyc = argc > 3 ? atoi(argv[3]) : 40000;
  int prof = argc > 4 ? atoi(argv[4]) : 0;
  for (int i = 0; i < (int)kNumFields; i++) ids[kFields[i].name] = i;
  static ttg::TraceWriter<decltype(kFields)> w(out, kModule, kInBytes, kOutBytes, kSpecHash, kFields);
  tw = &w;
  std::mt19937_64 rng(seed);
  auto R = [&](int n) { return (int)(rng() % n); };
  auto P = [&](int pm) { return R(1000) < pm; };  // per mille
  //                       0    1    2    3
  const int p_event[4] = {120, 300,  60, 250};    // trap / xRET event per cycle
  const int p_csr[4]   = {100, 150, 300, 250};    // new CSR instruction executes
  const int p_commit[4]= {400, 500, 300, 500};    // staged CSR write commits
  const int p_inj[4]   = { 20,  60,  10,  80};    // inject value change

  static Csr csr;  // zero-initialised like the heap-allocated one in BackTop
  ExeCsrIO exe2csr; RobCsrIO rob2csr; RobBroadcastIO rob_bcast; CsrInterruptInjectIO inj;
  CsrExeIO csr2exe; CsrRobIO csr2rob; CsrFrontIO csr2front; CsrStatusIO csr_status;
  csr.in = {&exe2csr, &rob2csr, &rob_bcast, &inj};
  csr.out = {&csr2exe, &csr2rob, &csr2front, &csr_status};
  csr.init();
  for (int k = 0; k < 3; k++) w.commit(0, ttg::kFlagReset);

  static const int addrs[] = {number_mtvec, number_mepc, number_mcause, number_mie, number_mip, number_mtval, number_mscratch,
                              number_mstatus, number_mideleg, number_medeleg, number_sepc, number_stvec, number_scause,
                              number_sscratch, number_stval, number_sstatus, number_sie, number_sip, number_satp,
                              number_mhartid, number_misa};
  // addresses weighted toward the ones that steer traps and interrupts
  static const int hot[] = {number_mstatus, number_sstatus, number_mie, number_sie, number_mip, number_sip, number_mideleg,
                            number_medeleg, number_mtvec, number_stvec};
  auto pick_addr = [&]() { return P(600) ? hot[R(10)] : addrs[R(21)]; };
  auto pick_data = [&]() -> uint32_t {
    switch (R(8)) {
      case 0: return 0;
      case 1: return 0xFFFFFFFFu;
      case 2: return 1u << R(32);
      case 3: return (uint32_t)rng() & 0x00000BBBu;
      case 4: return (uint32_t)rng() | 0x00000888u;
      case 5: return ((uint32_t)rng() & 0x1888u) | 0x8u;      // mstatus-ish: MIE/MPP
      default: return (uint32_t)rng();
    }
  };

  bool inj_ext = false, inj_sext = false, inj_timer = false;
  bool csr_pending = false;
  for (int cyc = 0; cyc < ncyc; cyc++) {
    // peripheral model: valid flags are sticky 1 in the real system; also exercise valid=0 in profiles >= 1
    if (P(p_inj[prof])) inj_ext = R(2);
    if (P(p_inj[prof])) inj_sext = R(2);
    if (P(p_inj[prof])) inj_timer = R(2);
    inj.external_irq_pending_valid = prof == 0 ? 1 : !P(100);
    inj.external_irq_pending = inj_ext;
    inj.supervisor_external_irq_pending_valid = prof == 0 ? 1 : !P(100);
    inj.supervisor_external_irq_pending = inj_sext;
    inj.timer_irq_pending_valid = prof == 0 ? 1 : !P(100);
    inj.timer_irq_pending = inj_timer;

    exe2csr = {}; rob2csr = {}; rob_bcast = {};
    csr.comb_csr_status();
    csr.comb_begin();
    csr.comb_interrupt();

    // ---- ROB side: one event ----
    int ev = 0;  // 0 none, 1 irq, 2 ecall, 3 mret, 4 sret, 5 pf_inst, 6 pf_load, 7 pf_store, 8 illegal
    bool commit_slot = false;
    if (P(p_event[prof])) {
      ev = 1 + R(8);
      if (ev == 1 && !csr2rob.interrupt_req) ev = 2 + R(7);
    }
    // privilege 2 is reserved: mret with MPP==2 (only reachable by a non-WARL mstatus write) would enter it, where
    // ecall neither traps nor is defined; software never does this, so keep the stimulus out of it
    if (ev == 3 && ((((uint32_t)csr.CSR_RegFile[csr_mstatus]) >> 11) & 3) == 2) ev = 0;
    bool is_irq = ev == 1;
    rob2csr.interrupt_resp = is_irq;
    uint32_t pc = (uint32_t)rng() & ~1u;
    if (ev) { rob_bcast.pc = pc; }
    if (ev == 2) rob_bcast.ecall = 1;
    if (ev == 3) rob_bcast.mret = 1;
    if (ev == 4) rob_bcast.sret = 1;
    if (ev == 5) { rob_bcast.page_fault_inst = 1; rob_bcast.trap_val = pc; }
    if (ev == 6) { rob_bcast.page_fault_load = 1; rob_bcast.trap_val = (uint32_t)rng(); }
    if (ev == 7) { rob_bcast.page_fault_store = 1; rob_bcast.trap_val = (uint32_t)rng(); }
    if (ev == 8) { rob_bcast.illegal_inst = 1; rob_bcast.trap_val = (uint32_t)rng(); }
    rob_bcast.exception = is_irq || ev == 2 || ev >= 5;
    // CSR commit: not in a cycle with an event unless profile 3 (see header)
    if (csr_pending && P(p_commit[prof]) && (ev == 0 || (prof == 3 && P(500)))) { rob2csr.commit = 1; commit_slot = true; }
    if (prof == 3 && P(30)) rob2csr.commit = 1;  // commit with nothing staged / spurious
    // ---- EXU side: a CSR instruction executes (not while the ROB flushes) ----
    if (!rob_bcast.exception && !rob_bcast.mret && !rob_bcast.sret && P(p_csr[prof]) && (!csr_pending || prof >= 2)) {
      int f3 = 1 + R(7); if (f3 == 4) f3 = 1;                // csrrw/s/c and immediate forms
      bool fam_w = f3 == 1 || f3 == 5;
      bool src_zero = P(250);
      exe2csr.we = fam_w || !src_zero;
      exe2csr.re = !fam_w || P(600);
      exe2csr.idx = pick_addr();
      exe2csr.wcmd = f3 & 3;
      exe2csr.wdata = pick_data();
      if (exe2csr.we) csr_pending = true;
    }
    if (commit_slot && !(exe2csr.we && prof >= 2)) csr_pending = false;
    if (commit_slot && exe2csr.we) csr_pending = false;   // staged write is dropped by the reference (see notes)

    csr.comb_csr_read();
    csr.comb_exception();
    csr.comb_csr_write();
    csr.comb_interrupt_inject();

    S("exe2csr_we", exe2csr.we); S("exe2csr_re", exe2csr.re); S("exe2csr_idx", exe2csr.idx);
    S("exe2csr_wdata", exe2csr.wdata); S("exe2csr_wcmd", exe2csr.wcmd);
    S("rob_bcast_mret", rob_bcast.mret); S("rob_bcast_sret", rob_bcast.sret); S("rob_bcast_ecall", rob_bcast.ecall);
    S("rob_bcast_page_fault_inst", rob_bcast.page_fault_inst); S("rob_bcast_page_fault_load", rob_bcast.page_fault_load);
    S("rob_bcast_page_fault_store", rob_bcast.page_fault_store); S("rob_bcast_illegal_inst", rob_bcast.illegal_inst);
    S("rob_bcast_trap_val", rob_bcast.trap_val); S("rob_bcast_pc", rob_bcast.pc);
    S("rob2csr_interrupt_resp", rob2csr.interrupt_resp); S("rob2csr_commit", rob2csr.commit);
    S("interrupt_inject_external_irq_pending_valid", inj.external_irq_pending_valid);
    S("interrupt_inject_external_irq_pending", inj.external_irq_pending);
    S("interrupt_inject_supervisor_external_irq_pending_valid", inj.supervisor_external_irq_pending_valid);
    S("interrupt_inject_supervisor_external_irq_pending", inj.supervisor_external_irq_pending);
    S("interrupt_inject_timer_irq_pending_valid", inj.timer_irq_pending_valid);
    S("interrupt_inject_timer_irq_pending", inj.timer_irq_pending);
    S("csr2exe_rdata_vld", exe2csr.re); S("csr2exe_rdata", csr2exe.rdata);
    S("csr2rob_interrupt_req", csr2rob.interrupt_req);
    S("csr2front_epc_vld", rob_bcast.mret || rob_bcast.sret); S("csr2front_epc", csr2front.epc);
    S("csr2front_trap_pc_vld", rob_bcast.exception); S("csr2front_trap_pc", csr2front.trap_pc);
    S("csr_status_sstatus", csr_status.sstatus); S("csr_status_mstatus", csr_status.mstatus);
    S("csr_status_satp", csr_status.satp); S("csr_status_privilege", csr_status.privilege);
    w.commit(cyc + 3);
    csr.seq();
  }
  w.flush();
  return 0;
}
