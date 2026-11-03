// Trace generator for front_ctrl.  Golden = a LITERAL transcription of the control logic of front_top.cpp
// (front_global_control_comb, front_read_enable_comb, front_read_stage_input_comb, front_bpu_control_comb, S5/S9/S10/S11/S14,
// the FIFO "do_read = read_enable && has_data" rule, next_predecode_refetch), global_reset = 0, compiled-out paths removed.
// Stimulus: EXHAUSTIVE over the 13 one-bit inputs x both values of the registered predecode_refetch flag (set-up cycles force
// the flag), plus random cycles with random addresses.   usage: gen_ctrl <out.trc> <seed> <random cycles>
#include MODFIELDS
#include "gen_common.h"
GEN_BEGIN(front_ctrl)

static std::mt19937_64 rng;
static uint32_t R32() { return (uint32_t)rng(); }

struct In {
  bool be_refetch, be_fifo_read_enable, icache_ready, fa_full, fa_empty, inst_empty, ptab_full, ptab_empty, f2b_full,
      f2b_empty, bpu_icache_read_valid, bpu_ptab_write_enable, checker_flush_enable;
  uint32_t be_refetch_address, checker_flush_address;
};
static bool st_pr = false;            // predecode_refetch
static uint32_t st_pra = 0;           // predecode_refetch_address

static void cycle(const In &in) {
  const bool global_reset = false;
  // S1 front_global_control_comb
  bool global_refetch = in.be_refetch || st_pr;
  uint32_t refetch_address = in.be_refetch ? in.be_refetch_address : st_pra;
  // S2 front_read_enable_comb
  bool fa_rd_en = in.icache_ready && !in.fa_empty && !global_reset && !global_refetch;
  bool predecode_can_run_old = !in.inst_empty && !in.ptab_empty && !in.f2b_full && !global_reset && !global_refetch;
  bool inst_fifo_read_enable = predecode_can_run_old, ptab_read_enable = predecode_can_run_old;
  (void)ptab_read_enable;
  bool front2back_read_enable = in.be_fifo_read_enable;
  // S3: front2back FIFO read: refetch = backend refetch only; has_data_before_read = size>0 (and no refetch)
  bool f2b_has_data = !in.f2b_empty && !in.be_refetch;
  bool saved_f2b_valid = front2back_read_enable && f2b_has_data;      // do_read (write_enable = 0 in the read call)
  // S4 front_bpu_control_comb
  bool bpu_stall = in.fa_full || in.ptab_full;
  bool bpu_can_run = !bpu_stall || global_reset || global_refetch;
  bool bpu_icache_ready = !in.fa_full;
  bool bpu_in_icache_read_ready = bpu_icache_ready;
  if (!bpu_can_run) bpu_in_icache_read_ready = false;
  // S5 (mini_flush_correct = 0, bypass = false)
  bool normal_write_enable = in.bpu_icache_read_valid && bpu_can_run && !global_reset;
  bool fa_wr_en = normal_write_enable;
  // S8
  bool predecode_can_run = inst_fifo_read_enable;                     // !dummy (=0) && inst_fifo_read_enable
  // S9
  bool ptab_can_write = in.bpu_ptab_write_enable && !in.ptab_full && !global_reset && !global_refetch;
  // S10
  bool do_flush = false;
  uint32_t flush_addr = 0;
  if (predecode_can_run && in.checker_flush_enable) { do_flush = true; flush_addr = in.checker_flush_address; }
  // S11
  bool f2b_can_write = predecode_can_run && !in.f2b_full && !global_reset;
  bool bypass = front2back_read_enable && in.f2b_empty && !saved_f2b_valid && f2b_can_write;
  bool f2b_wr_en = f2b_can_write && !bypass;
  // S14: out_src = saved if saved.valid else (bypass ? bypass_entry : saved)
  bool front_out_valid = saved_f2b_valid || (!saved_f2b_valid && bypass);

  S("be_refetch", 0, in.be_refetch); S("be_refetch_address", 0, in.be_refetch_address);
  S("be_fifo_read_enable", 0, in.be_fifo_read_enable); S("icache_ready", 0, in.icache_ready);
  S("fa_full", 0, in.fa_full); S("fa_empty", 0, in.fa_empty); S("inst_empty", 0, in.inst_empty);
  S("ptab_full", 0, in.ptab_full); S("ptab_empty", 0, in.ptab_empty); S("f2b_full", 0, in.f2b_full);
  S("f2b_empty", 0, in.f2b_empty); S("bpu_icache_read_valid", 0, in.bpu_icache_read_valid);
  S("bpu_ptab_write_enable", 0, in.bpu_ptab_write_enable); S("checker_flush_enable", 0, in.checker_flush_enable);
  S("checker_flush_address", 0, in.checker_flush_address);
  S("global_refetch", 0, global_refetch); S("refetch_address", 0, refetch_address);
  S("fa_rd_en", 0, fa_rd_en); S("predecode_can_run", 0, predecode_can_run); S("bpu_can_run", 0, bpu_can_run);
  S("bpu_icache_read_ready", 0, bpu_in_icache_read_ready); S("fa_wr_en", 0, fa_wr_en); S("ptab_wr_en", 0, ptab_can_write);
  S("f2b_wr_en", 0, f2b_wr_en); S("f2b_use_bypass", 0, bypass); S("front_out_valid", 0, front_out_valid);
  S("do_predecode_flush", 0, do_flush);
  commit_cycle();
  // next_predecode_refetch(_address)
  st_pr = do_flush;
  st_pra = do_flush ? flush_addr : 0;
}

static In from_bits(uint32_t c) {
  In in{};
  in.be_refetch = c & 1; in.be_fifo_read_enable = c >> 1 & 1; in.icache_ready = c >> 2 & 1; in.fa_full = c >> 3 & 1;
  in.fa_empty = c >> 4 & 1; in.inst_empty = c >> 5 & 1; in.ptab_full = c >> 6 & 1; in.ptab_empty = c >> 7 & 1;
  in.f2b_full = c >> 8 & 1; in.f2b_empty = c >> 9 & 1; in.bpu_icache_read_valid = c >> 10 & 1;
  in.bpu_ptab_write_enable = c >> 11 & 1; in.checker_flush_enable = c >> 12 & 1;
  in.be_refetch_address = R32(); in.checker_flush_address = R32();
  return in;
}

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "gen.trc";
  rng.seed(argc > 2 ? strtoull(argv[2], 0, 0) : 1);
  int nrand = argc > 3 ? atoi(argv[3]) : 100000;
  GEN_OPEN(out)
  // set-up cycles: "idle" gives do_flush = 0 (inst FIFO empty); "flush" gives do_flush = 1 when the flag is 0 and no refetch
  In idle = from_bits(1u << 5);                                       // inst_empty
  In flush = from_bits(1u << 12); flush.checker_flush_enable = true;  // inst/ptab non-empty, f2b not full, no refetch
  for (uint32_t c = 0; c < (1u << 13); c++) {
    // state flag = 0
    cycle(idle); cycle(from_bits(c));
    // state flag = 1 (the cycle before must see flag = 0: idle first)
    cycle(idle); cycle(flush); cycle(from_bits(c));
  }
  for (int k = 0; k < nrand; k++) {
    uint32_t c = R32() & 0x1fff;
    if (k & 1) c &= R32();                                            // thin out: more zeros
    cycle(from_bits(c));
  }
  w.flush();
  std::printf("front_ctrl: %llu records\n", (unsigned long long)g_cycle);
  return 0;
}
