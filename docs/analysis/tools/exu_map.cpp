#include <cstdio>
#include <cstdlib>
#define private public
#define protected public
#include "SimCpu.h"
#undef private
#undef protected
extern "C" void ttg_rec_cycle(SimCpu *c, uint64_t) {
  static bool done = false; if (done) return; done = true;
  Exu &x = *c->back.exu;
  std::printf("ISSUE_WIDTH=%d TOTAL_FU_COUNT=%d ALU_NUM=%d BRU_NUM=%d LSU_LDU=%d LSU_STA=%d LSU_SDU=%d LSU_AGU=%d BR_MASK_WIDTH=%d PRF_NUM=%d ROB_NUM=%d MAX_WAKEUP_PORTS=%d\n",
    ISSUE_WIDTH, TOTAL_FU_COUNT, ALU_NUM, BRU_NUM, LSU_LDU_COUNT, LSU_STA_COUNT, LSU_SDU_COUNT, LSU_AGU_COUNT, (int)BR_MASK_WIDTH, PRF_NUM, ROB_NUM, MAX_WAKEUP_PORTS);
  std::printf("IQ_ALU_PORT_BASE=%d IQ_LD=%d IQ_STA=%d IQ_STD=%d IQ_BR=%d MUL_LAT=%d DIV_LAT=%d\n", IQ_ALU_PORT_BASE, IQ_LD_PORT_BASE, IQ_STA_PORT_BASE, IQ_STD_PORT_BASE, IQ_BR_PORT_BASE, MUL_MAX_LATENCY, DIV_MAX_LATENCY);
  for (int p = 0; p < ISSUE_WIDTH; p++) {
    std::printf("port %2d mask=%llx:", p, (unsigned long long)GLOBAL_ISSUE_PORT_CONFIG[p].support_mask);
    for (auto &e : x.port_mappings[p].entries) std::printf(" [fu%d %s agu=%d sdu=%d]", e.fu_idx, typeid(*e.fu).name(), e.lsu_agu_port, e.lsu_sdu_port);
    std::printf("\n");
  }
  std::fflush(stdout); std::_Exit(0);
}
