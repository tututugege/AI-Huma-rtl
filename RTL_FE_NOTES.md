# RTL front-end fast paths (FE_RFAST / FE_BFAST), notes

Branch `exp/fe-rtl` (rtl), model references from trace-model `exp/fe-refs` (= `exp/combo` merged with main `7f8456e`, so the model
configuration equals RTL main; only the CFG_FE_* macros were added to the model). Nothing is merged, nothing is pushed.

## What is implemented (all default 0, compile-time parameters of `ttg_cfg_pkg`)

`ttg_cfg_pkg` gets `FE_RFAST` and `FE_BFAST` from trace-model `include/config.h` (`CFG_FE_RFAST`, `CFG_FE_BFAST`, `#ifndef` defaults 0; the model
env vars `FE_RFAST` / `FE_BFAST` still override). Switches on: `bash scripts/gen_cfg.sh -DCFG_FE_RFAST=15 -DCFG_FE_BFAST=3`
(with `SIM_SRC=<trace-model-ferefs>` until the model change is merged), references `scripts/ref_cycles_fe_on.txt`.

| switch | RTL |
|---|---|
| RFAST bit0 (S0 issues in the refetch cycle) | `bpu`: S0 looks up pc / history / RAS of the state the redirect command leaves (`pc1`, `spec1_*` from `bpu_spec`); the S0 push of the guess is a second step (`h2_*`, `r2_*`); `bpu_ctl.fast`, `s0_go = issue | fast` drives `icache_read_valid`, `r0_d`, fetch address |
| RFAST bit1 (PTAB write-to-read bypass) | `front_fifo` parameter `BYPASS` (read port shows the write of an empty queue, `ptab`), `front_ctrl_enables.predecode_can_run` accepts `bpu_ptab_write_enable` |
| RFAST bit2 (I$ ready right after a kill) | `icache_kill`: `ifu_ready = (next state == IDLE) && !accepted_now` (see "finding" below) |
| RFAST bit3 (pre-IDU buffer bypass) | `pre_idu_ibuf` parameter `BYPASS`: with an empty buffer the issue group is the accepted group (compacted by rank); the buffer update is unchanged (push, then pop of what decode took) |
| BFAST bit0 / bit1 (corrected block issues in the same cycle after an S1 (L1) / S_D override) | same `fast` path as RFAST bit0 with `l1_ov` / `ovr` as first command (credit `ptab_size + 1 < PTAB_SIZE - 1`); `fetch_addr_fifo`/`front_fifo` `WR_AFTER_DROP`: the push of the cycle takes the slot of the dropped entry |

With FAST (RFAST bit0 or any BFAST) off, the generated netlist is unchanged (parameters fold): `bpu` 222,883 cells before and after.

### Finding that needed a fix (RFAST bit2)

The reference model sees the I$ AXI accept pulse one cycle later than this RTL (valid 2 cycles then accept in the RTL, 3 cycles then accept in the
model; the DDR request itself reaches DRAMsim3 in the same cycle). Without bit2 this is invisible (kill in the pulse cycle: model CANCEL_WAIT, RTL IDLE,
both ready again at the same later cycle). With bit2 the ready is given in the kill cycle, so a kill in the pulse cycle must still count as
"accept outstanding" (model: not ready). `accepted_now` holds the ready back. Before this fix 6 of 67 programs differed by 1..4 cycles (coremark -4,
memory-stress-small +116, pf-stress +201 with DS3=0). It was found with a fixed-latency memory (`DS3=0` build of both sides: off config 67/67 equal,
on config 67/67 equal after the fix); DRAMsim3 phase differences between the RTL testbench and the model turned out to be a red herring.

## Verification (local, Verilator, DS3 on = default harness)

| check | switches off | RFAST=15 BFAST=3 |
|---|---|---|
| `scripts/lint.sh` | 0 warnings (325 files) | 0 warnings |
| `scripts/lint_chip.sh` | 0 warnings | 0 warnings |
| `fm_gate.sh` per-commit function-model check | 67/67 PASS | 67/67 PASS |
| cycles equal to trace-model | 67/67 equal to `ref_cycles.txt` (0 different) | 67/67 equal to `ref_cycles_fe_on.txt` (model exp/fe-refs, `LSU_PIPE_NOWD=1`), 0 different |
| `DS3=0` (fixed-latency DDR on both sides) | 67/67 equal | 67/67 equal |

Model cycle geomean over the 67 programs (small programs, not a performance claim): off 3623, FE_RFAST=15 FE_BFAST=3 3542 (-2.25 %); single bits
(model only): RFAST 1 / 2 / 4 / 8 = 3596 / 3596 / 3623 / 3590, BFAST 1 / 2 = 3621 / 3618.
The individual bits were not run separately in the RTL (only the all-on combination and, early on, RFAST=7 BFAST=3 / RFAST=15 BFAST=1 builds
that showed the bit2 issue above).

Reproduce (model references): `trace-model-ferefs` `make BUILD_DIR=build_fe0 LDFLAGS=-lz`, then
`FE_RFAST=15 FE_BFAST=3 LSU_PIPE_NOWD=1 bash scripts/tm_cycles.sh <simulator> out.txt`; RTL: build `SOC_FM=1 tb/soc/build.sh`, `REF_CYCLES=out.txt scripts/fm_gate.sh`.

## Same-cycle path depth (synth_depth.sh, generic gates, depth = longest path in gate levels, flip-flops excluded; relative proxy)

| module | switches | cells | depth (gate levels) |
|---|---|---|---|
| `bpu` | off | 222,883 | 148 |
| `bpu` | RFAST=1 only | 236,428 | 186 |
| `bpu` | BFAST=2 only | 232,726 | 196 |
| `bpu` | RFAST=15 BFAST=3 | 224,501 (+0.7 %) | 187 (+39, +26 %) |
| `front_pred_path` (BPU + PTAB + checker + front2back queue; synthesised from a scratch copy with `slot_kind` declared earlier: slang rejects the use-before-declaration in the committed file) | off | 226,649 | 134 |
| `front_pred_path` | RFAST=15 BFAST=3 | 233,537 (+3.0 %) | 192 (+58, +43 %) |
| `pre_idu_queue` (RFAST bit3 bypass mux) | off / RFAST=15 | 65,829 / 69,125 (+5.0 %) | 30 / 30 |

ABC noise is large (`bpu` alone is deeper than `front_pred_path`, which contains it): read the numbers as "about +40 levels, +25-40 %".
The longest path with the switches on starts at `r1_q` (the S2 stage register) and ends at `u_spec.spec_d` (the speculative history register):
S2 select / compare (`fin`) -> override -> corrected pc (`pc1`) -> uBTB set read and way compare for the S0 guess -> `g0.hbits` -> second history push.
It is the BFAST bit1 chain (S2 override -> same-cycle S0 re-lookup) and it is clearly too deep for one cycle at the current clock budget (the S0 lookup alone
was 148 in total, before the change the path ended in the uBTB train queue). The same structure (`pc1` mux with `fin.next`) is also built when only RFAST bit0 is on, so bit0
alone is as deep (186) although its own path (refetch address -> S0) is short. Cheaper variants, in order of effort:
1. RFAST bit0 only: take S0's pc / history / RAS from a refetch-only copy of the restore command (inputs are registers: `refetch_address`, `rf_ck`, `pd_ck`), not from `pc1` / `spec1_*`: removes the S2 dependency completely, about the old depth plus one mux.
2. Replace the two sequential 3-bit `hist_push_sym` steps (6 single-bit pushes of the 12 folded histories in series) by one multi-bit push computed as a linear (XOR) map like `bpu_hist_vec` already does for the committed history: cuts the tail of the path (the history update is the last third of it) to log depth.
3. BFAST bit1 only if still needed: issue the corrected block's fetch address in the S2 cycle but look it up in S0 with the *registered* corrected pc one cycle later (that is the current design: no gain) or issue it with a fall-through guess (no S0 lookup) and let S2 fix a wrong taken guess with a normal override (keeps the 1-cycle gain on not-taken blocks, costs a bubble on taken ones). The model needs a run to price that.
The PTAB bypass path (S2 `fin` -> PTAB write-through -> checker -> `predecode_refetch_q`) is the second same-cycle path; it is inside `front_pred_path` (+58 levels in total, mostly the S0 chain above, not separable with this proxy). `pre_idu_queue`: the bypass mux is one mux level inside the module, the real path (front2back bypass -> `front_valid` -> issue group -> IDU decode -> `consume_fire` -> pop count) crosses modules and was not measured.

## FE_PAIR (dual-block fetch): cost and plan, not started

FE_PAIR fetches the block at a predicted-taken target in the same cycle as the first block. In the RTL this is a rewrite of the BPU front, not a
switch: (1) S0 needs a second uBTB read whose set index is the first block's guessed target (a serial uBTB -> target -> uBTB chain in one cycle, plus
a second history / RAS step and a second TAGE index generation from the history after the first block); the 256-bit history ring becomes 512 bits and
the 12 folded histories take two pushes (up to 6 bits) per cycle; (2) the main arrays need a second read set per bank in S1 (today one set per
bank and array, NBB banked; either dual-ported arrays or more banks plus conflict handling), and `bpu_main_sel` / the override compare are
duplicated for the second block (the select logic is the biggest non-array piece of the BPU); (3) one PTAB / fetch-address / front2back entry carries both blocks
(explicit pc per slot instead of `base + 4*i`, per-slot meta, second block id and checkpoint, `pdq` / FTQ records for B): PTAB entry about +50 %,
every `out_pc` / FTQ slot pc consumer changes; (4) the I$ reads the second block functionally in the same cycle (same page, resident line): a second
tag/data read per way, no state change; (5) the predecode checker and `sequential_next_pc` work per segment (a segment ends where the pc is not consecutive);
(6) the back end FTQ entry gets two segments and the branch ending the first one gets the second segment's first pc as predicted target.
Estimate: 3-4 weeks including verification, front-end area (without the I$ arrays) +30 % or more, and the S0 double lookup does not fit one cycle
at the current depth (the single lookup after a redirect is already 26 % deeper, see above). A realistic variant pipelines the second lookup
(second block is looked up in S1 from the registered first guess, 2 blocks per cycle only in steady state, 1 bubble after a redirect), which costs
part of the +2.9 % the model shows. Model effect (25 points, notes in trace-model FRONTEND_NOTES.md): +2.9 % IPC on top of RFAST+BFAST.
FE_IPF (I$ prefetch) is not started: the model's version bypasses the real LLC/AXI path.

## Server / Linux

Server 106.14.7.26 (shared; load 20-40 from other agents' jobs when I started, 12 of my 13 segments ran at once = 12 cores). Source sent with
`RTL_SRC=rtl-fe RTL_DST=/root/rtlroot/rtlfe ./fleet.sh rtlsrc` (tree checked: my `icache_kill` comment present), package switched to RFAST=15 BFAST=3 with `sed`,
testbench `SOC_FM=1 SOC_VOPT=-DTTG_EBREAK_TRAP tb/soc/build.sh` (single thread), `add` = 1276 cycles (= `ref_cycles_fe_on.txt`).
`scripts/linux_segments.sh` on the 13 checkpoints `/root/rtlroot/linux/ckpt` (16,000,000 cycles per segment, per-commit function-model check):
**13 PASS, 0 FAIL**, 0 mismatch lines, 7.0 M - 25.0 M instructions checked per segment (s01 25.0 M, s02 24.5 M, s03 18.8 M, s04 17.7 M, s05 19.7 M, s06 22.0 M, s07 22.8 M,
s08 22.8 M, s09 18.5 M, s10 11.6 M, s11 7.0 M, s12 7.0 M, s13 7.1 M). Wall time about 1 h 15 min (s13 about 1 h 5 min alone). Results stay on the server in
`/root/rtlroot/rtlfe/linux_seg` (summary.txt, logs). A single from-reset run to `rv32 login:` (3-4 h) was not repeated for this configuration;
the segments cover the whole boot (s01-s13) with cold microarchitectural state at every segment start.

## Housekeeping

Scratch rsync copies with a different generated package (`rtl-fe-on`, `rtl-fe-off`, `rtl-fe-r1`, `rtl-fe-b2`, next to this worktree) were used for the switches-on builds and
synthesis and were deleted at the end; `/root/rtlroot/rtlfe` on the server (about 2 GB) is kept until the results are copied. The first attempt to build a second testbench (`rtl-fe-b2`) ran in the main `rtl` checkout by mistake (`cd` into a directory that was not
created yet): it rebuilt `rtl/build/soc_fm/obj/soc_tb` from the unchanged main sources (same source, new timestamp); nothing else there changed.
