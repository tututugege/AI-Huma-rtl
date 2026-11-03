// Read-only recording tap of the front-end (added for the RTL trace harness, refsim only).
//
// front_comb_calc() (front-end/front_top.cpp) evaluates the front-end in ONE call per cycle, but most of the
// interesting signals (icache outputs, BPU output, FIFO read results, predecode / checker results, bypass
// decisions) are function-local variables that are gone when the recording hook runs (after BackTop::comb()).
// With TTG_REC set, front_comb_calc() copies those locals into g_ttg_front_tap right before returning.
// The tap only COPIES values; it never feeds anything back (checked: cycle counts are bit-identical).
//
// Spec expressions read it through TTG_FT (= g_ttg_front_tap), e.g.
//     out ptab_wr_en 1 @ TTG_FT.ptab_req.push_write_en
//     in  pop_en 1     @ TTG_FT.ptab_req.pop_en
#pragma once
#include "front_IO.h"
#include "front_module.h"
#include "predecode_checker.h"
#include "train_IO.h"
#include <cstdint>

// Flat copy of BPU_TOP::OutputPayload (avoids pulling BPU/BPU.h into every translation unit).
struct FrontTapBpuOut {
  fetch_addr_t fetch_address;
  wire1_t icache_read_valid;
  fetch_addr_t predict_next_fetch_address;
  wire1_t PTAB_write_enable;
  wire1_t pred_dir[FETCH_WIDTH];
  wire1_t alt_pred[FETCH_WIDTH];
  pcpn_t pcpn[FETCH_WIDTH];
  pcpn_t altpcpn[FETCH_WIDTH];
  tage_tag_t tage_tags[FETCH_WIDTH][TN_MAX];
  tage_idx_t tage_idxs[FETCH_WIDTH][TN_MAX];
  wire1_t sc_used[FETCH_WIDTH];
  wire1_t sc_pred[FETCH_WIDTH];
  tage_scl_meta_sum_t sc_sum[FETCH_WIDTH];
  tage_scl_meta_idx_t sc_idx[FETCH_WIDTH][BPU_SCL_META_NTABLE];
  wire1_t loop_used[FETCH_WIDTH];
  wire1_t loop_hit[FETCH_WIDTH];
  wire1_t loop_pred[FETCH_WIDTH];
  tage_loop_meta_idx_t loop_idx[FETCH_WIDTH];
  tage_loop_meta_tag_t loop_tag[FETCH_WIDTH];
  pc_t pred_base_pc;
  wire1_t update_queue_full;
  wire1_t two_ahead_valid;
  fetch_addr_t two_ahead_target;
  wire1_t mini_flush_req;
  wire1_t mini_flush_correct;
  fetch_addr_t mini_flush_target;
};

struct FrontTap {
  uint64_t count = 0;   // number of front_comb_calc() calls that filled the tap
  // ---- stage 1/2: global control and read enables -------------------------------------------------------
  wire1_t global_reset = false;
  wire1_t global_refetch = false;
  fetch_addr_t refetch_address = 0;
  wire1_t icache_ready = false;               // icache_peek_ready()
  wire1_t fetch_addr_fifo_read_enable_slot0 = false;
  wire1_t inst_fifo_read_enable = false;      // == predecode_can_run_old
  wire1_t ptab_read_enable = false;
  wire1_t front2back_read_enable = false;
  // ---- stage 3: FIFO read results (before any write of this cycle) --------------------------------------
  fetch_address_FIFO_out fa_out0{};            // saved_fetch_addr_fifo_out_0
  // ---- stage 4/5: BPU and fetch_address_FIFO write -----------------------------------------------------
  wire1_t bpu_stall = false;
  wire1_t bpu_can_run = false;
  FrontTapBpuOut bpu_out{};
  wire1_t normal_write_enable = false;
  wire1_t can_bypass_fetch_to_icache = false;
  fetch_address_FIFO_out fa_out_final{};       // fetch_addr_fifo_out after the (optional) write call
  // ---- stage 6: icache (main icache_comb_calc call; snapshot taken right after it) ---------------------
  icache_in icache_in{};
  icache_out icache_out{};
  wire1_t icache_slot0_data_valid = false;
  // ---- stage 7: instruction_FIFO write / predecode bypass ---------------------------------------------
  wire1_t can_bypass_icache_to_predecode = false;
  wire1_t use_icache_to_predecode_bypass = false;
  wire1_t predecode_source_valid = false;
  wire1_t predecode_can_run = false;
  instruction_FIFO_out saved_fifo_out{};       // instruction_FIFO head (or icache bypass) feeding the checker
  PTAB_out saved_ptab_out{};                   // PTAB head feeding the checker / front2back write
  // ---- stage 8: PTAB write, checker, front2back write ---------------------------------------------------
  wire1_t ptab_can_write = false;
  predecode_checker_in checker_in{};
  predecode_checker_out checker_out{};
  wire1_t do_predecode_flush = false;
  fetch_addr_t predecode_flush_address = 0;
  wire1_t front2back_can_write = false;
  wire1_t can_bypass_front2back_to_output = false;
  wire1_t use_front2back_output_bypass = false;
  front2back_FIFO_out saved_front2back_fifo_out{};
  front2back_FIFO_out bypass_front2back_fifo_out{};
  // ---- accumulated per-FIFO requests (what front_seq_write will apply: clear -> push -> pop) ----------
  FetchAddrCombOut fetch_addr_req{};
  InstructionCombOut inst_req{};
  PtabCombOut ptab_req{};
  Front2BackCombOut front2back_req{};
  // ---- FIFO state at the START of the cycle (== seq_read snapshots) ------------------------------------
  fetch_address_FIFO_read_data fa_rd{};
  instruction_FIFO_read_data inst_rd{};
  PTAB_read_data ptab_rd{};
  front2back_FIFO_read_data f2b_rd{};
  // ---- registered flags (latches) seen by this cycle, and the values they take next cycle ---------------
  wire1_t predecode_refetch_q = false;
  fetch_addr_t predecode_refetch_address_q = 0;
  wire1_t full_q[4] = {}, empty_q[4] = {};     // order: fetch_addr, instruction, ptab, front2back
  wire1_t next_full[4] = {}, next_empty[4] = {};
};

extern bool g_ttg_front_tap_on;     // true iff $TTG_REC is set (so normal runs pay nothing)
extern FrontTap g_ttg_front_tap;
#define TTG_FT (g_ttg_front_tap)
// Used inside front_comb_calc(): runs the statements only when recording.
#define TTG_TAP(...) do { if (g_ttg_front_tap_on) { __VA_ARGS__ } } while (0)
