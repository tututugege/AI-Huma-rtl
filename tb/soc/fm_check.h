// Per-commit check against the function model (librefcpu): every instruction the RTL core commits is executed once by the
// function model; the commit pc and the value written to the destination register must agree.
// Enabled with SOC_TB_FM=1 in a build made with SOC_FM=1 (tb/soc/build.sh).  Not RTL: testbench code.
#pragma once
#include "refcpu_api.h"
#include <cstdint>
#include <cstdio>
#include <functional>

struct FmCheck {
  RefCpuContext *ctx = nullptr;
  uint64_t steps = 0, synced_io = 0, irqs = 0;
  bool failed = false;
  std::function<uint32_t(uint32_t)> dut_mem;   // the testbench memory, for diagnostics

  // ram: the testbench's physical memory (already holding the image and the boot stub at 0x0)
  void init(uint32_t ram_bytes, const uint32_t *ram, uint32_t sdram_bytes, const uint32_t *sdram) {
    ctx = refcpu_init(0, ram_bytes);
    refcpu_set_uart_print(ctx, false);        // same configuration as trace-model's diff: no device side effects in the checker,
    refcpu_set_ref_only(ctx, true);           // device values come from the DUT (see commit())
    refcpu_set_device_effects(ctx, false);
    refcpu_set_interrupt_delivery(ctx, false);
    refcpu_sync_ram_from_dut(ctx, ram, ram_bytes);
    if (sdram != nullptr) refcpu_sync_sdram_from_dut(ctx, sdram, sdram_bytes);
  }

  // The core has taken an asynchronous interrupt between two instructions.
  bool interrupt(uint64_t cycle, refcpu_xlen_t cause, uint8_t target_priv, uint32_t pending) {
    if (!refcpu_take_forced_interrupt(ctx, cause, target_priv, pending)) {
      std::fprintf(stderr, "[FM] cycle %llu: function model rejects interrupt cause=%llx priv=%u\n", (unsigned long long)cycle, (unsigned long long)cause, target_priv);
      return failed = true, false;
    }
    ++irqs;
    return true;
  }

  // One committed instruction.  dut_pc: commit pc; rd/rd_val: destination architectural register and the value the core wrote
  // (rd == 0: none).  Returns false on the first disagreement (message already printed).
  bool commit(uint64_t cycle, refcpu_xlen_t dut_pc, unsigned rd, refcpu_xlen_t rd_val, bool fp_rd = false, unsigned frd = 0,
              uint64_t frd_val = 0) {
    RefCpuState before{}, after{};
    refcpu_get_state(ctx, &before);
    if (before.pc != dut_pc) {
      std::fprintf(stderr, "[FM] cycle %llu commit #%llu: pc rtl=%llx fm=%llx\n", (unsigned long long)cycle, (unsigned long long)steps, (unsigned long long)dut_pc, (unsigned long long)before.pc);
      return failed = true, false;
    }
    refcpu_step(ctx, 1);
    ++steps;
    RefCpuStepInfo info{};
    refcpu_get_step_info(ctx, &info);
    refcpu_get_state(ctx, &after);
    const bool trapped = info.is_exception || info.page_fault_inst || info.page_fault_load || info.page_fault_store;
    // F/D: an instruction whose destination is an FP register has no integer result to compare (FP registers: S6)
    const uint32_t opc = info.instruction & 0x7f, f5 = info.instruction >> 27;
    const bool fp_dest = opc == 0x07 || (opc & 0x73) == 0x43 || (opc == 0x53 && f5 != 0x14 && f5 != 0x18 && f5 != 0x1c);
#if FP
    if (fp_rd && !trapped) {   // F/D: the FP register the core wrote against the function model's (all 64 bits, NaN-boxing included)
      if (!fp_dest || after.fpr[frd] != frd_val) {
        std::fprintf(stderr, "[FM] cycle %llu commit #%llu pc=%llx inst=%08x: f%u rtl=%016llx fm=%016llx%s\n", (unsigned long long)cycle,
                     (unsigned long long)steps, (unsigned long long)dut_pc, info.instruction, frd, (unsigned long long)frd_val,
                     (unsigned long long)after.fpr[frd], fp_dest ? "" : " (the function model writes no FP register)");
        return failed = true, false;
      }
    }
#endif
    if (rd != 0 && !trapped && !fp_dest && after.gpr[rd] != rd_val) {   // a trapping instruction writes no register; the next commit pc checks the trap target
      const uint32_t csr_no = info.instruction >> 20;   // fflags / frm / fcsr, mstatus / sstatus, misa: architectural state, compared
      const bool arch_csr = (csr_no >= 1 && csr_no <= 3) || csr_no == 0x300 || csr_no == 0x100 || csr_no == 0x301;
      if (info.is_io || (info.is_csr && !arch_csr)) {   // device / counter values are the platform's, not the function model's: adopt the DUT's
        after.gpr[rd] = rd_val;
        refcpu_set_state(ctx, &after);
        ++synced_io;
      } else {
        std::fprintf(stderr, "[FM] cycle %llu commit #%llu pc=%llx inst=%08x: x%u rtl=%llx fm=%llx\n", (unsigned long long)cycle,
                     (unsigned long long)steps, (unsigned long long)dut_pc, info.instruction, rd, (unsigned long long)rd_val, (unsigned long long)after.gpr[rd]);
        if ((info.instruction & 0x7f) == 0x03) {   // load: show the address and both memories
          const refcpu_xlen_t va = before.gpr[(info.instruction >> 15) & 31] + refcpu_xlen_t(int64_t(int32_t(info.instruction) >> 20));
          uint32_t pa = 0; const bool ok = refcpu_translate_data(ctx, va, 1, &pa);
          std::fprintf(stderr, "[FM]   load va=%llx pa=%08x(xlate %d) priv=%u satp=%llx fm_mem=%08x rtl_mem=%08x\n", (unsigned long long)va, pa, int(ok), before.privilege, (unsigned long long)before.csr[18],
                       refcpu_load_word(ctx, pa & ~3u), dut_mem ? dut_mem(pa & ~3u) : 0u);
          std::fprintf(stderr, "[FM]   fm words around pa:");   // which neighbour does the RTL value come from?
          for (int d = -4; d <= 4; ++d) std::fprintf(stderr, " %08x", refcpu_load_word(ctx, (pa & ~3u) + 4 * d));
          std::fprintf(stderr, "\n");
        }
        return failed = true, false;
      }
    }
    return true;
  }
};
