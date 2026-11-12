# Integrated RTL: LSU memory speculation + front-end fast paths (branch exp/integ)

> **Status (2026-11-12)**: a point-in-time record of the 2026-11-09 integration (gate counts 68/68 are from then). Since then: store write buffer (EXP-024, `RTL_WBUF_NOTES.md`), compact ROB (EXP-028, `ROB_COMPACT = 1`), removal of the 0x87f00000 window (EXP-027), and rv64 (EXP-029); `fm_gate.sh` is now 69/69 and `scripts/ref_cycles.txt` has 71 lines (69 programs).

Merged: `exp/memspec-rtl` (598f4f9, EXP-019/020, notes RTL_MEMSPEC_NOTES.md) and `exp/fe-rtl` (dbc1fa7, notes RTL_FE_NOTES.md) on rtl main edf9d3b.
The only conflict was the generated `ttg_cfg_pkg.sv` (regenerated, not hand-merged). Model: trace-model `exp/integ` (`/trace-model-integ`).

## Switch cleanup
| name | before | now |
| --- | --- | --- |
| `LSU_MEMSPEC` | config export, default 0 | config export, **default 1** (kill switch: `bash scripts/gen_cfg.sh -DCFG_LSU_MEMSPEC=0`) |
| `LSU_MDP_BITS` (6), `LSU_MDP_CLR` (2000) | config exports | fixed constants emitted by `harness/tools/gen_cfg_pkg.py` (`FIXED`), never taken from `config.h`; wait-table training is the one-flagged-entry-per-cycle `lp_mdp` (no variant left in the RTL) |
| `FE_RFAST` | config export (0..15) | fixed 15 (same mechanism); the generate structure of the bits is kept, the constant folds |
| `FE_BFAST` | config export, default 0 | unchanged, the single exported front-end switch, default 0 (+34% depth) |
Removed: `scripts/fe_sweep.sh`, `scripts/ref_cycles_fe_on.txt`, per-setting `scripts/fe_refs/*` except `ref_r15_b0.txt` / `ref_r15_b3.txt`, `scripts/ref_cycles_memspec.txt`.
References: `scripts/ref_cycles.txt` (default config, 67 programs + `directed/memspec_vio`), `scripts/ref_cycles_nomemspec.txt` (LSU_MEMSPEC=0, FE_RFAST=15), both from the model with `LSU_PIPE_NOWD=1`.

## Gates
| gate | default (MEMSPEC=1, RFAST=15) | kill switch (MEMSPEC=0) |
| --- | --- | --- |
| `lint.sh` / `lint_chip.sh` | 0 / 0 warnings | 0 / 0 warnings |
| `fm_gate.sh` (per-commit function-model check) | 68/68 PASS | 68/68 PASS (67 + directed) |
| RTL cycles == model on every program | 68/68 equal (0 different) | 68/68 equal (0 different) |
| Linux, 13 segments, 4-thread testbench, server (`scripts/linux_segments.sh`, per-commit check) | **13 PASS, 0 mismatches** (6.9M..24.1M instructions per segment) | - |

Model and RTL agree on every program in both configurations (first_diff / debug prints were not needed). Directed test: 3,420 cycles (MEMSPEC=1), 3,608 (MEMSPEC=0).

## Synthesis (yosys generic gates, `synth_cfg.sh` light ABC for cells, `synth_depth.sh` balanced ABC for depth levels; main = rtl edf9d3b, default config)
| module | cells main | cells integ | depth main | depth integ |
| --- | --- | --- | --- | --- |
| `lsu` (`lp_core`) | 969,441 | 894,874 (-7.7%) | 131 | 128 |
| `lp_cam` | 69,666 | 31,279 | 81 | 82 |
| `lp_ldq` | 330,074 | 386,345 | 78 | 78 |
| `lp_l1b` | 248,896 | 110,854 | 82 | 83 |
| `lp_wb` | 124,377 | 126,730 | 63 | 57 |
| `lp_ms` (wait table, new) | - | 4,264 | - | 45 |
| `bpu` | 223,476 | 202,257 | 149 | 141 |
| `front_pred_path` | 226,649 (FE notes, scratch copy: main does not synthesise) | 208,401 | 134 (same source) | 142 (+6%) |
| `pre_idu_queue` | 49,795 | 54,186 | 30 | 30 |
| `dispatch` | 91,937 | 92,518 | 46 | 46 |
| `rob` | 201,672 | 206,695 | 47 | 46 |
Depth criterion (nothing deeper than main by more than about 5%): met everywhere except `front_pred_path`, +6% (142 vs 134, FE_RFAST=15 with FE_BFAST=0; `bpu` itself is shallower). With FE_BFAST=3 the FE notes measure 192 (+43%), which is why BFAST stays off.
