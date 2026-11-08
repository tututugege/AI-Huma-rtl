# EXP-019 RTL: memory-dependence speculation in the staged LSU (branch exp/memspec-rtl)

Model reference: trace-model `exp/memspec-refs` (EXP-018 `exp/mem-spec` 2196889 + main EXP-016/017 + the changes of section 5).
Switch: `LSU_MEMSPEC` (ttg_cfg_pkg, from trace-model `CFG_LSU_MEMSPEC`, default 0). `LSU_MDP_BITS` (12) and `LSU_MDP_CLR` (2000) are exported too.
With the switch off the RTL is the old design (67/67 programs equal to `scripts/ref_cycles.txt`, lint and lint_chip 0 warnings, the new logic folds away).
Turn it on: `bash scripts/gen_cfg.sh -DCFG_LSU_MEMSPEC=1` (generated package = `exp/memspec-rtl-on`, one commit).

## 1. What is implemented (RTL <-> model)

| model | RTL |
| --- | --- |
| `stq_cam(spec_ok)`: unknown-address older stores are skipped, `spec` = one was passed that is younger than the forwarding candidate | `lp_cam`: `spec_ok` in, `unk` out (prefix-OR over the hit vector in rank order); `lp_l1b` writes it to the LDQ entry (`sp_we/sp_val`); `spec_ok` per L1 slot = no LR, not `second`, wait-table bit clear (`lp_ms`) |
| `L_SPD`, `rob_defer`, `second`, `vio`, `spec`, `wait` | new LDQ state `LS_SPD`, flags `spec vio second wait_b` + 12-bit wait-table index per entry (`lp_ldq_ent`, logic of one entry in `lp_ent_ms`); the data of a deferred direct write-back is kept in `result` |
| first write-back deferred, completion write-back, `flush_pipe` | `lp_wb`: `wb_defer` / `wb_flushp` per load port -> `lsu2exe_wb_req_uop_rob_defer/flush_pipe` -> `exu_ctrl_wb_rob` -> ROB (`rob_wb_t.defer/flush_pipe`) |
| ROB: `rob_defer` skips the completion, `flush_pipe` = flush instruction (single commit, redirect pc+4) | `rob_pkg`: `rob_make_event` drops a deferred event, `rob_entry_t.flush_pipe`, `rob_is_flush_inst`; the back end already redirects to `rob_bcast_pc + 4` for a flush without cause |
| SPD release scan (no unknown store older than the load) | `lp_ms`: first unknown store from the head (rotate + find-first), `lp_ent_ms`: `older_cnt <= unk_rank`; registered SPD entries and the direct write-backs of the cycle (not the WBP picks), as in the model |
| STA arrival CAM over the LDQ | `lp_ent_ms`: per entry, per STA port: rank < older count and 12-bit overlap (`rel12`); `vio_new` sets `vio`, SPD -> RDY + `second` |
| wait table, PC hash, clear every 2000 cycles | `lp_mdp`: 4096 x 1 flops, 2 write ports (the two lowest violating LDQ entries), `LSU_MDP_CLR` saturating down counter, lazy clear at the first load dispatch after it expires (identical to the model) |
| `dis2lsu.ldq_pc` | **PC hash, not the PC**: the FTQ gets 8 extra read ports (one per rename slot, `pre_idu_queue`), the hash `pc[13:2] ^ pc[25:14]` goes into `dis_inst_t` (12 flops per slot, 96 total) and through `dispatch_lsu_req` into the LDQ allocation. The hash is computed before the dispatch register, so the FTQ read is not in the dispatch/LSU path. |
| L3 wake of a `second` write-back | `lp_wake`: no wake for `second` (the PRF-side wake of the RTL is idempotent) |

Not implemented (model modes that stay off): store-set mode (`LSU_MDP_MODE=1`), confidence counter (`THR/DEC`: the RTL needs THR=1, DEC=0 = a sticky 1-bit table).

## 2. Model changes needed for the RTL (trace-model exp/memspec-refs, all keep the default off identical)

* Wait-table training is implementable (`LSU_MDP_HW=1`, default): the violating loads of a cycle are all marked, the table is trained by the **two lowest LDQ indices** of the cycle (`LSU_MDP_NTR=2`), and the bit is written at the clock edge (visible to the lookups of the next cycle, the lookups of the cycle of the violation did not see it in EXP-018). `LSU_MDP_HW=0` = EXP-018 behaviour. 67 gate programs: identical cycles either way (NTR=1 loses 1.2% on dhrystone: 75 of 414 violations come two in one cycle).
* `CFG_LSU_MDP_BITS` / `CFG_LSU_MDP_CLR` in `config.h`, env override kept.
* `LSU_MS_TRACE=1` (per-event print, same cycle numbers as an RTL debug print), `[MS_PENALTY]` statistics (section 6), `LSU_MS_SLOTS=N` (section 7).
* `LSU_MS_SLOTS=N` (section 7) and the **fix found by the RTL Linux check**: the violation check must also cover loads parked in `L_RPW` (a load parked behind an older store forwards from it when woken, with no second CAM pass, and silently missed a younger store whose address it had passed; the oracle-driven model never noticed because it has no data). 67 programs: cycles unchanged by the fix.

## 3. Verification (final trees: `exp/memspec-rtl` = switch off, `exp/memspec-rtl-on` = same + `LSU_MEMSPEC = 1`)

| check | off | on |
| --- | --- | --- |
| `scripts/lint.sh`, `scripts/lint_chip.sh` | 0 / 0 warnings | 0 / 0 warnings |
| `fm_gate.sh` (per-commit function-model check) | 67/67 PASS, cycles equal to `ref_cycles.txt`: 67/67 | 68/68 PASS (67 + `directed/memspec_vio`) |
| RTL cycles = trace-model cycles (`REF_CYCLES=scripts/ref_cycles_memspec.txt`, model `LSU_MEMSPEC=1 LSU_PIPE_NOWD=1`) | - | **66 of 68 equal**; `dhrystone` 115,896 vs 115,830 (+66, +0.06%), `vm_pagefault_test` 19,271 vs 19,270 (+1) |

Why two programs differ (not an RTL or model bug, an inherent limit of an oracle-driven model): the RTL executes with real data. A younger consumer of a stale load result can resolve a branch on the stale value and mispredict although the model (values are facts of the trace) never does. dhrystone: first divergence at cycle 3568, a mispredict of the branch at pc 0x800003f8 (`bne a0,x0` after `lbu a0,55(sp)` that read the byte before the older `sb` to the same address); the mispredict blocks the commit of the violating load by one cycle. vm_pagefault_test: the RTL has two extra mispredicts (cycles 11097, 14337) that the model does not have. Everything up to the divergence is event-for-event equal (SPD / release / violation / second write-back cycles compared with `LSU_MS_TRACE=1` against an RTL debug print). This is also why the directed test has **no branch on a loaded value** (with one, RTL 3914 vs model 3579 cycles); without it RTL = model = 3451 cycles (59 violations, partial / byte overlap, chains of 1..7 loads).

Linux: `scripts/linux_segments.sh` on the server (13 checkpoint segments, per-commit check). First run (before the RPW fix): 7 PASS, 6 FAIL (all the same instruction pattern, a user-mode `lbu` returning a stale byte) -> root cause above, reproduced in 62k cycles locally (s06), fixed (s06 now runs 3M cycles clean). Second run on the fixed tree: see section 8.

## 4. Cost (yosys generic gates, `scripts/synth_cfg.sh`, light ABC; area proxy, not timing)

| module | main | with LSU_MEMSPEC=1 | delta |
| --- | --- | --- | --- |
| `lsu` (= `lp_core`) cells / flops | 969,441 / 22,572 | 1,128,323 / 27,703 | +158.9k (+16.4%) / +5,131 |
| `lp_ldq` (64 entries) | 330,074 / 11,456 | 412,184 / 12,480 | +82.1k / +1,024 (16 bits per entry: spec, vio, second, wait, 12-bit table index) |
| of which `lp_ent_ms` (STA CAM + SPD release, per entry 1,183 cells) | - | 75.7k for 64 | |
| `lp_mdp` (wait table + 2 write ports + 8 read ports + timer) | - | 69,524 / 4,107 | 4096 flops + 11-bit timer |
| `lp_cam` (4 ports) / `lp_wb` / `lp_l1b` | 69,666 / 124,377 / 248,896 | 70,480 / 126,729 / 251,484 | +0.8k / +2.4k / +2.6k |
| `rob` | 201,672 / 17,802 | 206,695 / 17,930 | +5.0k / +128 (flush_pipe bit per entry) |
| `dispatch` | 91,937 / 1,632 | 93,082 / 1,728 | +1.1k / +96 (12-bit hash per rename slot) |
| `pre_idu_queue` | 49,795 | 51,237 | +1.4k (hash); the 8 extra FTQ read ports are `$mem` ports in this flow and are not in the cell count (estimate: 8 x 24 bits x 512:1 mux, order of 100k gates) |

**PC choice**: PC hash (12 bits) from the FTQ at rename -> dispatch register (96 flops) -> LDQ entry (64 x 12 flops), not the full PC. Total new state: 5,131 flops in the LSU + 128 (ROB) + 96 (dispatch).

Logic depth (generic gate levels after `strash;balance;dc2;balance;map`, flip-flops excluded, `scripts/synth_depth.sh`):
| path | levels |
| --- | --- |
| STA arrival -> per-entry violation check (`lp_ent_ms`, inputs registered / STA broadcast; the rank subtract `stq - head` in `lp_ms` comes before it, about 10) | 32 |
| SPD release: oldest unknown store (rotate + find-first + index, `lp_ms`) then the per-entry compare (in `lp_ent_ms`) | 43 + part of the 32 |
| wait-table train: `vio_new` -> 2 lowest violators -> index mux -> 4096 decode (`lp_mdp`) | 49 |
| `lp_cam` | 81 -> 96 (+15: the unknown-store prefix OR) |
| `lp_ldq_ent` longest path | 61 -> 64 |
Chained worst case STA arrival -> vio_new -> train -> table write is about 10 + 32 + 49 = 90 levels, shorter than the existing critical path of `lp_core` (section 9 of docs/analysis/lsu-pipe.md), but not free. Cut if needed: register `vio_new` and train from the registered `vio` bits one cycle later.

## 5. Cheaper variants (model, 30 points of `points_p30_local.txt`, `PF_ENABLE=1 PMU=1 FASTWARM=1000000`, results in `~/personal/AI-Huma-data/memspec-rtl/r3_*.txt`, geomean IPC vs the `base` run)

| variant | geomean IPC | RTL effect |
| --- | --- | --- |
| default (12 bit table, 2 train ports, unlimited speculative loads) | +5.26% | as measured above |
| 8-bit table | +5.27% | `lp_mdp` 69.5k -> 7.0k cells, 4096 -> 256 flops |
| 6-bit table (64 x 1) | +5.37% | smaller still; **the table size does not matter** (the 2000-cycle clear dominates) |
| 1 train port (NTR=1) | +5.26% | one decoder less (the 1.2% dhrystone loss of NTR=1 is below the noise on the 30 points) |
| at most 16 speculative loads (`LSU_MS_SLOTS=16`) | +4.95% | the CAM / release scan could shrink from 64 entries to 16 tracking entries |
| at most 8 | +3.76% | too few |
| 8-bit table + 1 train port + 16 slots | +4.95% | |
Recommendation: keep the 64-entry LDQ check (it is 76k of the 159k cells) only if the 0.3 point matters; take the 6..8-bit table and one train port (nothing lost, saves about 60k cells and 3.8k flops).

## 6. Violation penalty (model `[MS_PENALTY]`, env `LSU_PIPE_STATS=1`)

Per violation that reaches its flush commit (the others die on the wrong path before): detect -> flush commit (replay + completion + waiting for the ROB head), flush commit -> next commit (refetch bubble), and the cycles in that window in which nothing committed ("idle").
| point | violations | flush commits | detect->flush commit | refetch bubble | total | idle-commit cycles | flushed younger |
| --- | --- | --- | --- | --- | --- | --- | --- |
| astar sp13 / sp21 | 8194 / 8111 | 4439 / 4434 | 21.7 / 21.5 | 12.3 | 34.0 / 33.9 | 17.7 / 17.8 | 92 / 91 |
| perlbench sp3 | 5205 | 3140 | 17.4 | 10.7 | 28.1 | 13.4 | 82 |
| bzip2 sp23 / sp39 | 6560 / 5669 | 3292 / 2830 | 41.1 / 32.7 | 11.0 | 52.1 / 43.8 | 32.0 / 24.3 | 98 |
So the span from detection to resumption is 28..52 cycles (the earlier 20-30 guess is low), but the cycles actually lost (commit idle) are 13..32. dhrystone: 27 / 11.6. Only about 55% of the violations reach their flush commit. bzip2 (3 points): IPC +126% / +99% / +0.3% against `MEMSPEC=0`.

## 7. Remaining / not done
* The two cycle differences of section 3 are inherent to the oracle model; a model that tracks data would be needed to close them.
* FTQ read-port area not measured (memory ports in the flow), cheaper alternative: carry the hash from the front end through pre_idu_queue / idu / ren (about 96 flops per stage) instead of 8 FTQ read ports.
* RTL for store sets, confidence counters not done; `spec/*.io` boundary specs (retired harness) not updated.
* Server 24-core budget was kept; the server was shared (OOM killed 8 of my model points once, rerun).

## 8. Linux result (server, `exp/memspec-rtl-on` at the RPW fix, tb `SOC_FM=1 --threads 4 -DTTG_EBREAK_TRAP`, `linux_segments.sh` JOBS=4)
13/13 segments PASS (10.7M..23.6M instructions checked per segment, no mismatch). Reproduce: `bash scripts/gen_cfg.sh -DCFG_LSU_MEMSPEC=1` (or check out `exp/memspec-rtl-on`), build the tb, `scripts/linux_segments.sh <tb> <ckpt dir> <out>`.


# Part 2 (follow-up): align with the model value path, reduce area and depth

## 9. Model value path (exp/ms-data merged into exp/memspec-refs)
`LSU_MS_DATA=1` (model, default off, off identical) gives the stale-value effects of the RTL. With it: dhrystone 115,896 and vm_pagefault_test 19,271 =
RTL; `fm_gate` on 68/68, **RTL cycles equal to the model on all 68** (the two differences of section 3 are gone), off trees 67/67 equal to `ref_cycles.txt`.
`scripts/ref_cycles_memspec.txt` is generated with `LSU_MEMSPEC=1 LSU_MS_DATA=1 LSU_PIPE_NOWD=1`. The RTL needs nothing from `LSU_MS_DATA`.

## 10. What changed in the RTL (model first, then RTL, cycle equality on all 68 after every step)
| change | model | effect |
| --- | --- | --- |
| overlap test `lp_ovl`: one log-depth comparator (|so - lo| < access size via equality / "a == b + 1" prefix-AND on the upper address bits) instead of two adders + three compares (`rel32/rel12 != 0`); exact incl. the no-wrap case, checked against `rel12/rel32` on 6M random + corner vectors | none | `lp_cam` 73.7k -> 31.3k cells (x4 ports), `lp_ent_ms` 1,183 -> 697; **helps the switch-off design too** |
| wait-table training from a flag register (`trn_q`, one bit per LDQ entry), one write port, table written two cycles after the violation | `LSU_MDP_HW=2` (new default); 67 programs identical to HW=1 | no STA-arrival -> table-write path (it ends in 64 flops); 2 -> 1 write port |
| wait table 64 x 1 (`LSU_MDP_BITS=6`) | default 6 | 69.5k -> 2.7k cells, 4,096 -> 64 flops; IPC +5.35% (12 bit: +5.27%) |
| FTQ: 8 dispatch lookups read the 64:1 base pc and add 4 * offset (slots of an entry are consecutive) instead of 8 x 512:1 slot-pc read ports | none | +16.9k cells (measured with memories mapped to logic: base 340.0k, +8 old-style ports 491k incl. unused outputs, new 356.9k; the old-style used-bits-only estimate is about 100k) |
| `lp_cam`: `unk` built on the prefix-OR of the find-first-set, no redundant `spec_ok` gate | none | `lp_cam` 96 -> 82 levels |
Not done: carrying the hash through ibuf / idu / ren (64 x 6 + 3 x 8 x 6 flops plus write ports, more than the +16.9k of the FTQ read); `LSU_MS_SLOTS` in the RTL (section 11).

## 11. Model data (30 points, `PF_ENABLE=1 PMU=1 FASTWARM=1000000 LSU_MEMSPEC=1 LSU_MS_DATA=1`, geomean IPC; `base` = `~/personal/AI-Huma-data/memspec/base`, `msdata1` = the earlier default run, reproduced exactly by `def`)
| variant | vs base | vs msdata1 |
| --- | --- | --- |
| def (12 bit, 2 train ports, direct train) | +5.21% | 0 |
| HW=2, 12 bit | +5.27% | +0.06% |
| HW=2, 8 bit | +5.30% | +0.08% |
| **HW=2, 6 bit (new default)** | **+5.35%** | **+0.13%** |
| HW=1, 1 train port, 6 bit (dhrystone no longer loses with LSU_MS_DATA=1) | +5.31% | +0.09% |
| HW=2, 6 bit, `LSU_MS_SLOTS=16` | +5.06% | -0.15% |
`LSU_MS_SLOTS=16` would shrink the per-entry check (now 697 cells x 64 = 45k, plus the release logic) to at most 16 tracking entries: at most about 30k cells (3%) for -0.4 point, and a new slot table; rejected.

## 12. Depth (generic gate levels, `synth_depth.sh`) and area, main vs final (switch on)
Worst path per module, main -> now: `lp_cam` 81 -> 82 (ABC noise: without the unknown-store output the module is 67), `lp_l1b` 82 -> 83, `lp_ldq` 78 -> 78, `lp_ldq_ent` 61 -> 61, `lp_wb` 63 -> 57, `lp_core` 131 -> 128, `rob` 47 -> 46, `dispatch` 46 -> 45, `pre_idu_queue` 30 -> 30. New modules: `lp_ent_ms` 34, `lp_ms` 45, `lp_mdp` 43 (all inside the depth of `lp_core`). Only `lp_cam` / `lp_l1b` are +1 over main; every other module is not deeper.
| module | main cells / flops | now cells / flops |
| --- | --- | --- |
| `lsu` / `lp_core` | 969,441 / 22,572 | **894,874** / 23,351 (-7.7%, +779 flops) |
| `lp_ldq` | 330,074 / 11,456 | 386,345 / 12,096 |
| `lp_cam` | 69,666 | 31,279 |
| `lp_ms` + `lp_mdp` + `lp_ent_ms` x 64 | - | 4.3k (incl. 2.7k table) + 44.6k |
| `lp_l1b` | 248,896 | 110,854 |
| `rob` | 201,672 / 17,802 | 206,695 / 17,930 |
| `dispatch` | 91,937 / 1,632 | 92,518 / 1,680 |
| `pre_idu_queue` + FTQ pc reads | 49,795 | 50,138 (+16.9k for the base-pc reads, counted separately above) |
Flops added in total: 779 (LSU) + 128 (ROB) + 48 (dispatch).

## 13. Final-tree verification (exp/memspec-rtl 74cbd42+, exp/memspec-rtl-on 37182cd)
lint / lint_chip: 0 / 0 warnings for both trees. `fm_gate` off 67/67 (cycles equal to `ref_cycles.txt`), on 68/68 (cycles equal to `ref_cycles_memspec.txt` on all 68, directed test 3,438). Linux, server, tb of the on tree: **13/13 segments PASS** (5.9M..23.6M instructions each).
Recommended default: `LSU_MEMSPEC=1`-capable design as built here with `LSU_MDP_HW=2`, `LSU_MDP_BITS=6` (price versus the old 12-bit / 2-port design: none, +0.13% geomean). Model geomean 30 points: +5.35% vs base (msdata1: +5.21%).
