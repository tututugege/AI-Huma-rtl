# axi_llc — AXI last-level cache (AXI_LLC.cpp + MemSubsystem.cpp AxiLlcTableRuntime)

Ref: `axi-interconnect-kit/axi_interconnect/AXI_LLC.cpp` (`AXI_LLC::comb/seq`), tables: `MemSubSystem/MemSubsystem.cpp:44-247`.
Boundary / spec: `spec/axi_llc.io` (one record per tick, 16 per CPU cycle, `scripts/lockstep_ticks_axi.sh axi_llc`).
Default geometry 4 MiB / 16 way / 64 B line / 4096 sets / 8 MSHR; geometry macros `AXI_LLC_SETS`, `AXI_LLC_WAYS`, `AXI_LLC_MSHR` (see section 6).

## 1. Boundary and what "one tick" means
The C++ calls `llc.comb()` twice per tick (comb_outputs: ext_in with `read_resp.ready=0`; comb_inputs: final). Each call starts from
`reg_write = regs`, so only the **final** call defines the next state. Measured over 23.8 M ticks (68 programs, incl. CPU cycle 1 after the tap was armed before the first cycle): ext_out of both calls is
identical in every tick (an earlier tap version that armed itself only at the end of cycle 1 showed a spurious 16-tick difference per program). The RTL implements the final
call only: inputs `llc_in2` (ext_in) -> outputs `llc_out2`; `ext_out.mem.read_resp_ready/write_resp_ready` are constant 1 and are not ports.
Outputs `up_rd_resp_*`, `up_wr_resp_*` are plain functions of the registers; `up_*_req_ready` and `mem_*_req_*` come out of the stage chain.
`hz_*` = registers the interconnect reads directly for its hazard / id-conflict checks (state before the tick's seq).

## 2. Dead / constant paths (evidence: gcov over 68 programs x {4 MiB, 32 KiB/16w, 8 KiB/4w, 16 KiB/2w}, stat plugin)
Not implemented (assertions in the RTL flag them if they ever occur): prefetch (config off), invalidate_all/line (never requested), direct_mapped /
mode2 (mode=1), noalloc, MMIO, epoch/stale refill (epoch never changes), bypass **writes** (peripheral write master never active: `b_wr_valid_m1`=0
in all runs), partial-line write miss (DCache writes are always 64 B full strobe: `mshr_is_write`=0), victim owner-slot write-response branches
(`victim_wb_mshr_slot` is always INVALID when the response arrives), read-resp-queue pop-on-idle (C++ 1358), try_commit loop at C++ 1604, perf, debug,
`dirty_line_count`, `mem_issue_cycle`. Depths: read_resp_q (C++ 32) observed max 1 -> 2; write_q observed 0 at tick end -> 2; read_victim_wb_q max 2 -> 4.

## 3. Units and the stage chain
The seven C++ stages mix reads of `io.regs` (old) and `io.reg_write` (new). They are kept as seven combinational stage modules chained on one
`ch_t` (new state + table op + outputs); every stage also receives the old state `r`. Which version each stage reads:

| stage (C++) | reads old `r` | reads chain `n` (earlier stages of this tick) |
| --- | --- | --- |
| s1 drive_read_responses | resp regs/queue | - |
| s2 drive_write_path | resp regs, victim_wb, read_victim queue (head/count/entry), rr_write, write_q fullness | write_ctx, write_q, resp regs, victim_wb, lookup (launch) |
| s3 try_complete_lookup | lookup regs, mshr (merge/free/way reservation), write_ctx (way reservation) | table-busy (s2), read-resp regs (enqueue), write_ctx, victim_wb |
| s4 drive_mem_read_path | mshr (find id, issue pick, commit pick), write_ctx/lookup (victim waits) | mshr (s3 may have allocated / changed victim fields), victim_wb, rvq, resp regs, table-busy |
| s5 try_launch_pending_write_lookup | - | lookup, write_ctx, rr_write |
| s6 accept_new_requests | resp regs (start-of-tick) | lookup, resp regs, write_ctx, victim_wb/rvq, mshr |
| s7 drive_lookup_request | lookup valid/issued | lookup, victim_wb/rvq, write_ctx, mshr, table-busy |

C++ quirk reproduced on purpose: after a write response pops the read-victim queue head (s2), the "load next victim" step reads the **old**
count/head again, so the same victim is issued a second time (C++ 1526-1537 vs 1626-1640).

## 4. Tables (`axi_llc_tables.sv`)
data[sets][ways] x 64 B, meta[sets][ways] = {tag, dirty}, valid[sets] x ways bits, repl[sets] next-way. Writes at the end of the tick; one op per tick
(`table_busy` guards guarantee it). Read: S7 issues at tick t; three registered stages carry the set index; at tick t+3 the row is read
**asynchronously** (sees all writes of ticks <= t+2, none of t+3) and a `lookup_in valid` pulse is raised. Same-set writes inside the window occur
with small LLCs (stat: 27 ticks over 3 programs at 32 KiB) and are modelled automatically by this structure.

## 5. Verification (all with `scripts/lockstep_ticks_axi.sh axi_llc`, module-level, every tick compared, spec/axi_llc.io)
Driver: `tests/axi_llc/run_all.sh` (68 programs = 61 gate tests + 4 vm + dhrystone + coremark + float_test; cap 300000 CPU cycles; RTL geometry
macros must match the reference's `TTG_LLC_KB/TTG_LLC_WAYS`). `--assert` is on in every run (the `bad` assertion in `axi_llc.sv` flags any
C++ path of section 2 that the RTL does not implement).

| geometry (ref = RTL) | programs | result |
| --- | --- | --- |
| 4 MiB, 4096 sets x 16 ways (default) | 68, cap 300000 cycles | 68 / 68 PASS (run_all prints 67: float_test's own stdout contains the word `Error`, its LOCKSTEP PASS line was checked by hand) |
| 32 KiB, 32 sets x 16 ways (`TTG_LLC_KB=32 TTG_LLC_WAYS=16`) | 12 (see below), cap 150000 | 12 / 12 PASS |
| 8 KiB, 32 sets x 4 ways (`TTG_LLC_KB=8 TTG_LLC_WAYS=4`) | same 12 | 12 / 12 PASS |
| 16 KiB, 128 sets x 2 ways (`TTG_LLC_KB=16 TTG_LLC_WAYS=2`) | same 12 | 12 / 12 PASS |
The 12: dcache-conflict-writeback, dcache-mshr-pressure, memory-stress-small, memory-stress, bubble-sort, quick-sort, matrix-mul, crc32, shuixianhua,
vm_pagefault_test, coremark, dhrystone.  The small geometries exercise dirty victims of read misses (global write-back slot, queue, the duplicate
re-issue quirk), write misses with victim write-back (`write_ctx_victim_dirty` 48-73 k ticks), write hits on lines chosen as victims of in-flight
refills, and same-set table writes inside the 3-tick lookup window (`write_same_set_in_window_age2/3` 21-53 ticks).
Measured maxima (stat plugin, 12 programs x 3 small geometries, plus the 68-program 4 MiB run): read_resp_q count 1 (RQD=2), read_victim_wb_q 2 in the 68 programs (VQD raised from 4 to 8 after random traffic reached 7, see 5.2),
write_q 0 at tick end (WQD=2), r_pending 8, MSHR in use 8, `drop_resp_credit` 0, lookup delivery latency always 3 (65752+65864+97661 deliveries).

### Mutants (one build holds all; `tests/axi_llc/mut_llc.py`, selector TTG_MUT=K through DPI)
Run first on 5 programs at 32 KiB/16w x 150000 cycles; survivors re-run on the 12 programs.
| # | mutation | result |
| --- | --- | --- |
| 1 | replacement pointer never advances (`next_way`) | killed (dcache-conflict-writeback, tick 1655: up_rd_req_ready) |
| 2 | write hit does not set dirty | killed (memory-stress-small: mem_wr_req_valid) |
| 3 | refill installed dirty | killed (dcache-conflict-writeback: mem_wr_req_valid) |
| 4 | read-miss victim dirtiness dropped | killed (memory-stress-small: mem_wr_req_valid) |
| 5 | victim_line_pending ignores the global victim slot | killed (memory-stress-small: up_wr_req_ready) |
| 6 | read-victim-queue reload uses the new count (kills the duplicate-issue quirk) | killed (memory-stress-small: up_wr_req_ready) |
| 7 | read-response `fresh` flag ignored | killed (dcache-conflict-writeback tick 149: hz_rresp_fresh) |
| 8 | table delivery after 2 ticks | killed (tick 85: mem_rd_req_valid) |
| 9 | write miss never prefers an invalid way | killed (dcache-conflict-writeback: mem_wr_req_valid) |
| 10 | refill-way reservation also keeps committed refills | survived at 32x16 (12 programs), killed at 16 KiB/2w (dcache-conflict-writeback tick 2634: mem_rd_req_valid) |
| 11 | bypass direct-issue ignores old-slot occupancy | SURVIVED - equivalent: that scan only sees entries allocated this tick, whose old slot is invalid by construction |
| 12 | write hit marks every same-set MSHR as victim holder | killed (dcache-conflict-writeback: mem_wr_req_valid) |
| 13 | write merge ignores byte strobe | SURVIVED - DCache only writes full 64 B strobes; partial strobes never reach the LLC in any program |
| 14 | write-master round-robin not advanced | SURVIVED - only master 0 (DCache) ever writes |
| 15 | per-master MSHR limit for non-DCache masters removed | SURVIVED - the interconnect never issues a second ICache read while one is outstanding |
| 16 | read hit ignores the word offset | SURVIVED - no cached read hit with a non-zero word offset occurs (bypass reads always miss; line reads are aligned) |
11 of 16 mutants killed; survivors 11 (equivalent), 13-16 are traffic the real system never generates in the 68 programs; they are NOT verified by lock-step and are listed as open issues.

### Quirks of the C++ reproduced on purpose (C++ line numbers)
* 1526-1537 vs 1626-1640: after a write response pops the read-victim queue head, the "load next victim" step reads the old count/head again and re-issues the same victim (mutant 6).
* 1643-1675: while a victim write-back is active (valid), stage 2 returns early: no write is accepted, no context filled, no write lookup launched.
* 1102/1724 vs 1807: write master pick and context fill use the old `rr_write`, the lookup launch the updated one.
* 1561 (dead): `victim_writeback_done` is never set for read victims, so `victim_line_pending` / the commit rely on `refill_valid` and the global slot.
* 2622, 968: a bypass MSHR keeps the unaligned byte address as its line address; `find_mshr_by_line_addr` ignores bypass entries but bypass lookups are compared against them.
* 2739-2755: bypass entries allocated in this very tick can issue their memory read in the same tick (reads reg_write.mshr).
* 2908-3016: a refill takes two ticks (table write + `refill_committed`, then response + MSHR free); a dirty victim is parked (global slot / queue) before the table write.
* 1088-1090: non-DCache masters may not have two MSHRs.
* 2079-2105: a write hit on the way an in-flight refill is going to replace updates that MSHR's victim snapshot.
* comb() #1 vs #2: identical ext_out in every tick (see section 1); nothing to reproduce.

## 5.2 Random-traffic verification (added by the interconnect work)
`tests/axi_llc/rand_axi.cpp` drives the reference AXI_Interconnect + LLC + sim_ddr with random DCache reads/writes, ICache reads (line and 4-byte
bypass) and peripheral bypass reads (`rand_run.sh axi_subsys|axi_llc <seed> <cycles>`, `rand_all.sh`).  Bypass writes and partial strobes are switched off
(`RAND_PWR=0 RAND_PARTIAL=0`: not implemented here).  `axi_subsys` 4 seeds x 3 small geometries (8KB/4w, 16KB/2w, 32KB/16w), 30000 cycles each: 12/12 PASS.
Random traffic reached a read-victim queue depth of 7 (the 68 programs: 2): `VQD` became 8 (head/tail 3 bits, count 4 bits, `vq_idx_t/vq_cnt_t`).
Mutants on random traffic (8KB/4w, 3 seeds, `mut_llc_rand.sh`): 1-8, 10, 12, 15, 16 killed; 15 (per-master MSHR limit) and 16 (read hit word offset) are NEW kills;
9 survived; 11 equivalent; 13 (partial strobe) and 14 (write round robin) need the unimplemented bypass/partial writes.  Total: 13 of 16 killed.

## 5.1 Open issues / not verified
Partial-line and bypass writes (peripheral write master), partial-line write miss (C++ MSHR write refill merge, 2343-2405), MSHR-owned victim write response (1547-1584),
read-response/victim queues deeper than 2/4, `stall_lookup_on_table_busy` (never triggered), way-pick failure paths, mutants 13-16 above.  All are guarded by the
`bad` assertion or by structure (queue depth bounds are checked by clocked assertions in `axi_llc.sv`).

## 6. Geometry macros
`rtl/memsys/axi_llc/axi_llc_pkg.sv`: `AXI_LLC_SETS` (default 4096), `AXI_LLC_WAYS` (16), `AXI_LLC_MSHR` (8, only 8 supported: slot id is 3 bits).
Reference side: `TTG_LLC_KB` / `TTG_LLC_WAYS` env (sets = KB*1024/(64*ways)). Example 32 KiB/16 way: `VFLAGS="-DAXI_LLC_SETS=32 -DAXI_LLC_WAYS=16"`.
