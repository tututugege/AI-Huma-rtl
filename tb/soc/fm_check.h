// Per-commit check against the function model (librefcpu): every instruction the RTL core commits is executed once by the
// function model; the commit pc and the value written to the destination register must agree.
// Enabled with SOC_TB_FM=1 in a build made with SOC_FM=1 (tb/soc/build.sh).  Not RTL: testbench code.
#pragma once
#include "refcpu_api.h"
#include <cstdint>
#include <cstdio>
#include <functional>

// A committed store as the RTL's store queue holds it (physical address, data, func3); kind 0: RAM (the function model's memory is compared),
// 2: any device (only the address is compared: the model keeps no readable copy of a device store)
struct StoreChk { bool v = false; uint32_t pa = 0; uint64_t data = 0; uint8_t f3 = 0; uint8_t kind = 2; };

struct FmCheck {
  RefCpuContext *ctx = nullptr;
  uint64_t steps = 0, synced_io = 0, irqs = 0, forced_pf = 0, io_loads = 0, stores_checked = 0, mmio_stores_checked = 0, csr_checks = 0;
  const uint64_t *mmio_reads = nullptr;   // number of device reads the testbench's peripheral model has served (every committed device load must have had one)
  bool strict = false;                    // SOC_TB_FM_STRICT=1: also check MMIO store data and architectural CSR/privilege state
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
              uint64_t frd_val = 0, int force_pf = -1, const StoreChk *st = nullptr) {
    RefCpuState before{}, after{};
    refcpu_get_state(ctx, &before);
    if (before.pc != dut_pc) {
      std::fprintf(stderr, "[FM] cycle %llu commit #%llu: pc rtl=%llx fm=%llx\n", (unsigned long long)cycle, (unsigned long long)steps, (unsigned long long)dut_pc, (unsigned long long)before.pc);
      return failed = true, false;
    }
    if (force_pf >= 0) { refcpu_force_next_page_fault(ctx, uint32_t(force_pf)); ++forced_pf; }   // the DUT's TLB / walker saw a stale PTE (legal until sfence.vma): same fault in the model
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
    if (st && st->v && !trapped && ((info.instruction & 0x7f) == 0x23 || (info.instruction & 0x7f) == 0x27)) {   // store: same address, same data as the model's
      const uint32_t ins = info.instruction;
      int32_t imm = int32_t(((ins >> 25) << 5) | ((ins >> 7) & 0x1f)); imm = (imm << 20) >> 20;
      const refcpu_xlen_t va = before.gpr[(ins >> 15) & 31] + refcpu_xlen_t(int64_t(imm));
      uint32_t fpa = 0;
      if (refcpu_translate_data(ctx, va, 2, &fpa) && fpa != st->pa) {
        std::fprintf(stderr, "[FM] cycle %llu commit #%llu pc=%llx inst=%08x: store address rtl=%08x fm=%08x (va=%llx)\n", (unsigned long long)cycle, (unsigned long long)steps,
                     (unsigned long long)dut_pc, ins, st->pa, fpa, (unsigned long long)va);
        return failed = true, false;
      }
      const unsigned sz = 1u << (st->f3 & 3);
      const uint64_t mask = sz == 8 ? ~0ull : ((1ull << (8 * sz)) - 1);
      bool have = false; uint64_t fmv = 0;
      if (st->kind == 0 && (st->pa & 3) + sz <= 8) {
        const uint32_t base = st->pa & ~3u;
        const uint64_t lo = uint64_t(refcpu_load_word(ctx, base)) | (uint64_t(refcpu_load_word(ctx, base + 4)) << 32);
        fmv = (lo >> ((st->pa & 3) * 8)) & mask; have = true;
      } else if (strict) {
        // Strict mode: also compare MMIO store data and unaligned/cross-word RAM store data directly against architectural rs2.
        const unsigned rs2 = (ins >> 20) & 31;
#if FP
        fmv = ((ins & 0x7f) == 0x27 ? before.fpr[rs2] : before.gpr[rs2]) & mask;
#else
        fmv = before.gpr[rs2] & mask;
#endif
        have = true;
        if (st->kind != 0) ++mmio_stores_checked;
      }
      if (have && fmv != (st->data & mask)) {
        std::fprintf(stderr, "[FM] cycle %llu commit #%llu pc=%llx inst=%08x: store(%s) pa=%08x size=%u data rtl=%llx fm=%llx\n", (unsigned long long)cycle, (unsigned long long)steps,
                     (unsigned long long)dut_pc, ins, st->kind == 0 ? "RAM" : "MMIO", st->pa, sz, (unsigned long long)(st->data & mask), (unsigned long long)fmv);
        return failed = true, false;
      }
      ++stores_checked;
    }
    if (mmio_reads && !trapped && info.is_io && (info.instruction & 0x7f) == 0x03 && ++io_loads > *mmio_reads) {   // a device load the RTL completed without any request reaching the peripheral model
      std::fprintf(stderr, "[FM] cycle %llu commit #%llu pc=%llx inst=%08x: device load #%llu committed but only %llu device reads were served (the RTL returned %llx)\n", (unsigned long long)cycle,
                   (unsigned long long)steps, (unsigned long long)dut_pc, info.instruction, (unsigned long long)io_loads, (unsigned long long)*mmio_reads, (unsigned long long)rd_val);
      return failed = true, false;
    }
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

  // Strict mode: compare architectural privilege and CSR registers at a commit-cycle boundary.
  // rtl_regs[0..18] matches csr_pkg.sv: 0=mtvec 1=mepc 2=mcause 3=mie 4=mip 5=mtval 6=mscratch 7=mstatus
  // 8=mideleg 9=medeleg 10=sepc 11=stvec 12=scause 13=sscratch 14=stval 15=satp 16=mhartid 17=misa 18=fcsr.
  bool check_csr_state(uint64_t cycle, uint8_t rtl_priv, const uint64_t *rtl_regs) {
    if (!strict) return true;
    RefCpuState st{};
    refcpu_get_state(ctx, &st);
    if (rtl_priv != st.privilege) {
      std::fprintf(stderr, "[FM] cycle %llu commit #%llu: privilege rtl=%u fm=%u\n",
                   (unsigned long long)cycle, (unsigned long long)steps, unsigned(rtl_priv), unsigned(st.privilege));
      return failed = true, false;
    }
    struct Map { int rtl_idx; int fm_idx; const char *name; uint64_t mask; };
    // Exclude mip (index 4, async platform IRQ injection). mstatus SD bit (bit 63) is derived in csr_read, not stored in regs[7].
    static constexpr Map kCsrs[] = {
      { 0,  0, "mtvec",    ~0ull}, { 1,  1, "mepc",     ~0ull}, { 2,  2, "mcause",   ~0ull},
      { 3,  3, "mie",      ~0ull}, { 5,  5, "mtval",    ~0ull}, { 6,  6, "mscratch", ~0ull},
      { 7,  7, "mstatus",  ~(1ull << 63)},
      { 8,  8, "mideleg",  ~0ull}, { 9,  9, "medeleg",  ~0ull},
      {10, 10, "sepc",     ~0ull}, {11, 11, "stvec",    ~0ull}, {12, 12, "scause",   ~0ull},
      {13, 13, "sscratch", ~0ull}, {14, 14, "stval",    ~0ull},
      {15, 18, "satp",     ~0ull}, {16, 19, "mhartid",  ~0ull}, {17, 20, "misa",     ~0ull},
    };
    for (const auto &m : kCsrs) {
      const uint64_t rv = rtl_regs[m.rtl_idx] & m.mask;
      const uint64_t fv = uint64_t(st.csr[m.fm_idx]) & m.mask;
      if (rv != fv) {
        std::fprintf(stderr, "[FM] cycle %llu commit #%llu: csr %s rtl=%016llx fm=%016llx\n",
                     (unsigned long long)cycle, (unsigned long long)steps, m.name,
                     (unsigned long long)rv, (unsigned long long)fv);
        return failed = true, false;
      }
    }
#if FP
    const uint32_t rtl_fcsr = uint32_t(rtl_regs[18] & 0xFFu);
    if (rtl_fcsr != (st.fcsr & 0xFFu)) {
      std::fprintf(stderr, "[FM] cycle %llu commit #%llu: csr fcsr rtl=%02x fm=%02x\n",
                   (unsigned long long)cycle, (unsigned long long)steps, rtl_fcsr, st.fcsr & 0xFFu);
      return failed = true, false;
    }
#endif
    ++csr_checks;
    return true;
  }
};
