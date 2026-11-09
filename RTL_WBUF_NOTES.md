# EXP-024 write buffer in RTL (2026-11-09)

Model: trace-model `docs/LSU_PIPE.md` section 12. The RTL equals the model cycle for cycle (`fm_gate.sh`, 68 programs, `LSU_PIPE_NOWD=1` table in `scripts/ref_cycles.txt`).

## What changed

* `rtl/backend/lsu/lp_wbuf.sv`: the write buffer, `NWB` = 4 entries (`lp_pkg::wbe_t`): valid, sent, mergeable, two stores, line tag, STQ indices of the two stores and copies of their address, data and size, and an age matrix. Decision (registers only): ready (`d_rdy` of all its stores), not blocked by an older valid entry (byte overlap, only between entries), the oldest candidates take the free ports (`NDR` = 2). The request of the leader carries the second store as lane 2 (`req_l2`, 40 bits: strobe, word, data); `dr_pick` / `dr_fol` / `dr_ml` mark the stores in the STQ (the follower completes with the leader's response, `mf_q` / `ml_q` in `lp_stq`). Response: the leader's response frees the entry on a hit, else the entry waits again.
* `rtl/backend/lsu/lp_wbstep.sv`: one step of the insertion (4 steps in a chain in `lp_wbuf`): MMIO / suppressed stores are skipped, a store merges into the youngest entry that is still waiting and not sent in this cycle, or starts a new entry; a full buffer stops the batch.
* `rtl/backend/lsu/lp_drain.sv`: only the MMIO store path and the instance of `lp_wbuf` are left (the candidate selection, the 64-entry overlap CAM and the pairing chain of the first version are gone).
* `rtl/backend/lsu/lp_stq.sv`: a "handled by the insertion" bit per entry (`wbi_q`, set by `wb_mark`, cleared at allocation), the follower marks `mf_q` / `ml_q`.
* DCache: every store port carries a second store word (`dcache_pkg::st2_t`, `strb == 0` = none) through `lsu_pipe`, `lsu`, `back_top`, `core_top`, `soc_top`, `mem_top`, `mem_route` into `dcache_s1` (slot and retry registers, fill-snapshot merge), `dcache_arr` / `dcache_bank` (second word write of the same row), `dcache_mshr`, `dcache_wb`, `dcache_resp` (response forwarding). All stores of a tick merge into a line in one parallel per-byte step (`line_merge_n`). The legacy LSU (`LSU_PIPE=0`) ties the second word to zero.

## Verification

`lint.sh` and `lint_chip.sh` 0 warnings; `fm_gate.sh` 68/68 with 0 cycle differences to the trace-model; Linux 13 segments 13/13 (checked instructions 6.9M to 24.2M per segment, 0 mismatches).

## Synthesis (yosys generic gates, cells / depth, main -> this change)

`lsu` 1,276,574 / 130 -> 1,279,658 / 125; `lp_stq` 158,221 / 72 -> 161,937 / 74; `lp_drain` 86,260 / 83 -> 68,767 / 97 (module depth +17%, above the 5% criterion; `lsu` as a whole is shallower than main); `lp_wbuf` 59,014 / 89; `dcache_s1` 12,970 / 45 -> 16,101 / 28; `dcache_mshr` 110,574 / 114 -> 83,386 / 101; `dcache_resp` 14,188 / 34 -> 17,418 / 22; `dcache_wb` 20,563 / 69 -> 26,673 / 57. `dcache_arr` does not synthesise in either tree.

## Not done / risks

No SPEC on the RTL; the first version (in-drain pairing, rtl `b1e0335`) had one `sc.w` mismatch in Linux segment s04 (cause not found, this version passes); the entries copy the address and data of the stores (they stay in the STQ until the response); no PMU events for the buffer.
