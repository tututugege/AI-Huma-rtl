# axi_llc — AXI last-level cache (AXI_LLC.cpp + MemSubsystem.cpp AxiLlcTableRuntime)

Ref: `axi-interconnect-kit/axi_interconnect/AXI_LLC.cpp` (`AXI_LLC::comb/seq`), tables: `MemSubSystem/MemSubsystem.cpp:44-247`.
Boundary / spec: `spec/axi_llc.io` (one record per tick, 16 per CPU cycle, `scripts/lockstep_ticks_axi.sh axi_llc`).
Default geometry 4 MiB / 16 way / 64 B line / 4096 sets / 8 MSHR; geometry macros `AXI_LLC_SETS`, `AXI_LLC_WAYS`, `AXI_LLC_MSHR` (see section 6).

## 1. Boundary and what "one tick" means
The C++ calls `llc.comb()` twice per tick (comb_outputs: ext_in with `read_resp.ready=0`; comb_inputs: final). Each call starts from
`reg_write = regs`, so only the **final** call defines the next state. Measured over 23.8 M ticks (68 programs, incl. CPU cycle 1 after the tap was armed before the first cycle): ext_out of both calls is
identical in every tick (an earlier tap version that armed itself only at the end of cycle 1 showed a spurious 16-tick difference per program). The RTL implements the final
call only: inputs `llc_in2` (ext_in) -> outputs `llc_out2`; `ext_out.mem.read_resp_ready/write_resp_ready` are constant 1 and are not ports.
Outputs `up_rd_resp_*`, `up_wr_resp_*` are plain functions of the registers; `up_*_req_ready` and `mem_*_req_*` come out of the unit chain of section 3.
`hz_*` = registers the interconnect reads directly for its hazard / id-conflict checks (state before the tick's seq).

## 2. Dead / constant paths (evidence: gcov over 68 programs x {4 MiB, 32 KiB/16w, 8 KiB/4w, 16 KiB/2w}, stat plugin)
Not implemented (assertions in the RTL flag them if they ever occur): prefetch (config off), invalidate_all/line (never requested), direct_mapped /
mode2 (mode=1), noalloc, MMIO, epoch/stale refill (epoch never changes), read-resp-queue pop-on-idle (C++ 1358), the `try_commit` loop at C++ 1604,
perf, debug, `dirty_line_count`, `mem_issue_cycle`, a memory write response without a write-back or a bypass write in flight, a memory read response
for an unused MSHR slot.  The 68 programs never use the following, but they ARE implemented since the stretch step and verified with random traffic
(section 5.2): **bypass writes** (peripheral write master: `b_wr_valid_m1` is 0 in all programs), **partial-line / partial-strobe writes** (DCache writes
are always 64 B full strobe in the programs: `mshr_is_write` = 0) and the **MSHR-owned victim write response** (`victim_wb_mshr_slot` is always INVALID
when the response arrives in the programs).  Depths: read_resp_q (C++ 32) max 1 in the programs, 3 in random traffic -> RQD 4; write_q observed 0 at tick end -> 2;
read_victim_wb_q max 2 (programs) / 7 (random traffic) -> 8.

## 3. Units and the tick flow
There is no global state record.  Each hardware unit owns its registers (`_q` registers, `_d` next-state wires, storage arrays written under
an enable) and talks to the others through narrow typed signals.  `axi_llc.sv` only adapts the spec ports (unpacked arrays) to packed vectors;
`axi_llc_core.sv` instantiates the units and is pure wiring plus the table-write select and the hazard lists.

| unit (file) | instances | state | role |
| --- | --- | --- | --- |
| `axi_llc_rq` | 4 (one per read master) | 3-entry shift FIFO (response register = entry 0), fresh flag | read responses leave; up to 3 producers per tick, accepted in priority order (0 lookup hit, 1 bypass memory response, 2 MSHR completion) |
| `axi_llc_wport` | 2 (one per write master) | request queue (2 entries, valid bits + pointers, passthrough when empty), write context (`valid lpend cpend vwait cdone`, bypass / `mem_issued` / `mem_done`, id/size/addr/data/strb, way/victim addr/merged line), response register with code | write request -> context -> lookup -> optional wait (victim write-back, or refill of a partial-line miss) -> table write -> response; bypass write: memory write -> response |
| `axi_llc_wsched` | 1 | `rr_write` | accept one write per tick, launch pick, bypass write issue pick, victim hazard of the queue fronts |
| `axi_llc_memwr` | 1 | none | memory write request mux: victim write-back (full line, id 0) or the picked bypass write (own addr / strobe / size / id) |
| `axi_llc_victim` | 1 | write-back slot (`valid issued forw wm owner addr data`), read-victim queue (8 entries, valid bits, head/tail, addr/data memory) | one write-back at a time towards memory; parks dirty victims |
| `axi_llc_mshr` + `axi_llc_mshr_ent` | 1 + 8 | per entry `valid bypass is_write issued rvalid rcomm vdirty vdone`, addr/way/size/master/id, victim snapshot, refill data | miss table, free / issue / refill picks, memory read response, owner of an answered write-back |
| `axi_llc_lookup` | 1 | `valid issued is_write bypass`, addr/size/master/id | the single lookup in flight |
| `axi_llc_resolve` | 1 | none (combinational) | stage 3: hit/miss (bypass / full / partial write, read), way pick, which unit gets which request |
| `axi_llc_refill` | 1 | none | stage 4c: park victim, refill write (write entry: merged, dirty), answer / free, mark the write context done |
| `axi_llc_rdacc` | 1 | `rr_read` | read accept (conflict checks) and table-read issue |
| `axi_llc_tables` | 1 | data / tag / dirty / valid / repl arrays, 3-stage read index | the SRAM tables (section 4) |
| `axi_llc_waypick`, `axi_llc_merge`, `axi_llc_rrpick`, `axi_llc_linecam` | | none | way selection with reservations, write merge, rotating-priority arbiter (all `for off in 0..N-1` scans), line-address CAM (all `find_*`/`*_pending` scans) |

One tick, in the order the C++ evaluates it.  Every decision only sees what the earlier steps of the same tick produced; that dependency is
expressed as dataflow between the units (no unit has a whole-state input).  Which version of a register each reader looks at:

| step (C++) | decision | reads |
| --- | --- | --- |
| 1 `drive_read_responses` | pop of the response register | `rq` regs, `up_rd_resp_ready` |
| 2 `drive_write_path` | write-back response -> context commit + table write; load next victim; issue; accept a write; queue front -> context | victim regs, **start-of-tick** hazard lists (accept), lists after the response / commit (fill); `rr_write` |
| 3 `try_complete_lookup` | `axi_llc_resolve` | **old** lookup regs, old MSHR / write-context state (way reservation, free entry, line in flight), the table row, `busy2` (table written by step 2), `victim busy` after step 2, response queue room |
| 4 `drive_mem_read_path` | (a) memory response (b) memory read issue (c) refill | old MSHR (picks), MSHR fields **after** step 3 (victim snapshot), victim slot after step 3, response queue room, `busy3` (table written by step 2 or 3) |
| 5 launch / accept / issue | write launch, read accept, table read issue | **end-of-tick** (`_d`) lists of every unit |

The C++ launches a write lookup twice (steps 2 and 5); the RTL has one launch point (after step 3): the candidate set and the "engine free"
condition of the two calls are identical, step 2 only differs by being skipped while the victim slot is busy, and the later call then does the
launch.  Fills of the two write contexts are independent of each other, so their C++ order is not reproduced.

Hazard lists (`axi_llc_core`): victim holders = write-back slot, queue entries, write contexts waiting for their victim, MSHRs whose refill data
arrived and whose dirty snapshot is not yet written (`vl_*`, three versions: start of tick for the write accept, after step 2 for the fill, end of
tick for read accept / table read issue); MSHR lines (`ml_*`, start and end of tick); pending writes (`wl_d`: queue entries and contexts not yet
updated in the table).  Every list is compared with `axi_llc_linecam`.

### Simplifications against the C++ (all unobservable at the boundary)
* `vmdone` of a write context is set and consumed in the same tick (the first table write of a tick is the victim commit, so it is never busy): dropped.
  `cpend` (the C++ `cache_pending`) and `vwait` (pending AND `victim_dirty`) are separate since partial-line write misses wait for a refill, not a victim.
* Read-victim queue entries have no owner field and no duplicate check: a snapshot that is already parked is never parked again (`park_needed`).
  Queue entries are valid exactly in the head/count window, so the per-entry valid flag is the window.
* `vaddr != 0` guards of the C++ (address 0 = "no victim"): not reproduced; DDR starts at 0x80000000, no dirty line at address 0 exists.
* The merged line of a full-line write miss is the write data itself (the C++ merges into a zero line).
* Read-response FIFO: the C++ keeps a response register and a 32-deep queue; one FIFO of RQD+1 = 5 entries is the same observable behaviour
  (max depth seen 3; an assertion fires at more than RQD = 4 entries).
* Reset: control bits and pointers only.  Payload registers and the table arrays are not reset (all their readers are qualified by a valid bit /
  `when` in the spec); the valid array powers up as 0 as before.
* Call structure: the C++ evaluates `comb()` twice and runs `try_launch_pending_write_lookup` twice; the RTL evaluates the function of one tick once.

### Behaviour added by the stretch step (C++ line numbers)
* Bypass write (peripheral write master, `bypass=1`): queued and filled like any write; its lookup is launched too but only updates a cached copy of the line
  on a hit (merge, table write with the OLD dirty bit, no victim-snapshot update); a miss does nothing (2302-2312).  The write itself goes to memory
  (1677-1693: oldest unissued context from the start-of-tick `rr_write`, only while the write path is not blocked by a victim write-back; byte address,
  strobe, size and id of the context) and completes with the memory write response, whose code becomes `up_wr_resp_resp` (1614-1620).  While a bypass write is
  outstanding no victim is loaded from the queue or issued (1625-1650).  The response goes to the lowest-index outstanding context (`find_bypass_write_mem_owner`).
* Partial-line write miss (2343-2405 + 2929-2970): way pick, then an MSHR with `is_write` is allocated (retry if the line is already in an MSHR or none is free);
  the context waits (`cpend`, no `vwait`).  When the refill data arrives the dirty victim is parked as for reads, then ONE tick writes the refill line with the write
  data merged (dirty), frees the MSHR and marks the context done: no read response, no `refill_committed`, the owner slot of the write-back is NOT released.
* MSHR-owned victim response (1547-1584): the response of a write-back parked with an owner slot does not pop the queue; the entry named by the slot (if it still
  holds that victim) or else the first entry with that victim and `vdone`=0 gets `vdone`=1 (so `vdone` is real state again; a write hit clears it).
* Quirk reproduced: the context is cleared by its response BEFORE stage 3 runs in the same tick, so a late bypass lookup merges with strobe 0 (writes nothing but still
  rewrites the line with the old dirty bit); a lookup result may also set `cache_done` on a freshly refilled context (the fill resets the flags first).

## 4. Tables (`axi_llc_tables.sv`)
data[sets][ways] x 64 B, meta[sets][ways] = {tag, dirty}, valid[sets] x ways bits, repl[sets] next-way. Writes at the end of the tick; one op per tick
(`table_busy` guards guarantee it). Read: S7 issues at tick t; three registered stages carry the set index; at tick t+3 the row is read
**asynchronously** (sees all writes of ticks <= t+2, none of t+3) and a `lookup_in valid` pulse is raised. Same-set writes inside the window occur
with small LLCs (stat: 27 ticks over 3 programs at 32 KiB) and are modelled automatically by this structure.

## 5. Verification (all with `scripts/lockstep_ticks_axi.sh axi_llc`, module-level, every tick compared, spec/axi_llc.io)
Reference tree: `baseline-sim` copy patched with `memsys-record-hook.patch` + `axi-record-hook.patch` (`docs/analysis/axi-record-hook.md`); the axi patch
applied cleanly to the shared `refsim_tap` copy.  `--assert` is on in every run (the clocked assertions of `axi_llc_core`, `axi_llc_rq`, `axi_llc_victim`
flag any C++ path of section 2 that the RTL does not implement and the queue-depth bounds).  `bash scripts/lint.sh rtl/memsys/axi_llc` is clean
(svlint S1-S12 + `verilator -Wall`).

Rewrite (hardware-style units, this note), then the stretch step (bypass writes, partial-line write miss, owner answer), run on the final RTL:
| check | result |
| --- | --- |
| `scripts/progs_smoke.txt` (62 programs, 4 MiB / 16 way default geometry, cap 60000 CPU cycles, `tests/axi_llc/run_all.sh`) | 62 / 62 PASS |
| dcache-conflict-writeback, dcache-mshr-pressure, memory-stress-small, bubble-sort, quick-sort, crc32 at 32 KiB/16w, 8 KiB/4w, 16 KiB/2w (cap 150000) | 6 / 6 PASS in each of the 3 geometries |
| `rand_run.sh axi_llc <seed> 30000`, `RAND_PWR=1 RAND_PARTIAL=1`, seeds 1-8 x {32 KiB/16w, 8 KiB/4w, 16 KiB/2w} | 24 / 24 PASS (all 480000 ticks compared) |
| `rand_run.sh axi_subsys <seed> 30000`, `RAND_PWR=1 RAND_PARTIAL=1`, same seeds and geometries | 24 / 24 PASS |
| `rand_run.sh axi_llc`, `RAND_PWR=0 RAND_PARTIAL=0` (the former gate), seeds 1-8 x the 3 geometries | 24 / 24 PASS |
| `rand_run.sh axi_subsys`, `RAND_PWR=0 RAND_PARTIAL=0`, seeds 1-4 x the 3 geometries | 12 / 12 PASS |
| whole SoC closed loop (`bash tb/soc/build.sh`, `JOBS=3 bash scripts/soc_smoke.sh 3000`, `MINC=3001 ... 250000`) | 50 / 50 and 15 / 15 PASS |
| mutants (`tests/axi_llc/mut_llc.py`, rewritten patterns), 7 run on dcache-conflict-writeback + memory-stress-small, 32 KiB/16w (before the stretch step) | 1, 2, 5, 6, 7, 12 killed; the first formulation of 7 (pop ignores `fresh`) survived on those 2 programs and was replaced by "fresh never set" (killed at tick 148) |

Not re-run on the final RTL: the 68-program 4 MiB run with cap 300000, the 12-program x 3-geometry run of the previous table, mutants 3, 4, 8, 9, 10, 13-16 and
all mutants after the stretch step.  Bugs found by random traffic that the programs did not show: (1) the end-of-tick hazard list used the old victim address of a
write context that becomes pending in the same tick; (2) the response queue depth RQD=2 was exceeded by writes/bypass traffic (now 4); (3) a bypass write whose
memory response arrives in the tick its lookup resolves must see the context already cleared (strobe 0).

Results of the pre-rewrite RTL (C++-shaped, one 25 kbit state record), kept for the record; they are NOT evidence for the rewrite:
* 4 MiB 68 programs 68/68, 32 KiB/16w, 8 KiB/4w, 16 KiB/2w 12 programs each 12/12 (dcache-conflict-writeback, dcache-mshr-pressure, memory-stress-small,
  memory-stress, bubble-sort, quick-sort, matrix-mul, crc32, shuixianhua, vm_pagefault_test, coremark, dhrystone); random traffic 12/12; 13 of 16 mutants
  killed (survivors: 11 equivalent, 13/14 need partial / bypass writes, 9 on programs).
* Measured maxima (stat plugin): read_resp_q count 1, read_victim_wb_q 2 (programs) / 7 (random traffic, hence VQD=8), write_q 0 at tick end, r_pending 8,
  MSHR in use 8, lookup delivery latency always 3.
Mutants (selector `TTG_MUT=K`, one build; ids as in `mut_llc.py`; 11 was an equivalent mutant of the old structure and no longer exists):
1 replacement pointer, 2 write hit dirty, 3 refill dirty, 4 read-miss victim dirtiness, 5 victim slot in the write accept, 6 queue reload sees the
popped queue (duplicate-issue quirk), 7 fresh flag, 8 table latency 2, 9 invalid-way preference, 10 reservation keeps committed refills,
12 write-hit victim update ignores the way, 13 merge ignores the strobe, 14 write round robin, 15 per-master MSHR limit, 16 read hit word offset.

### Quirks of the C++ reproduced on purpose (C++ line numbers)
* 1526-1537 vs 1626-1640: after a write response pops the read-victim queue head, the "load next victim" step reads the old count/head again and re-issues the same victim (mutant 6).
* 1643-1675: while a victim write-back is active (valid), stage 2 returns early: no write is accepted, no context filled, no write lookup launched.
* 1102/1724 vs 1807: write master pick and context fill use the old `rr_write`, the lookup launch the updated one.
* 1561: `victim_writeback_done` (`vdone`) is set only by the owner-slot answer of a write-back (never reached in the tests: the owner is freed first), so `victim_line_pending` / the commit rely on `refill_valid` and the global slot.
* 2622, 968: a bypass MSHR keeps the unaligned byte address as its line address; `find_mshr_by_line_addr` ignores bypass entries but bypass lookups are compared against them.
* 2739-2755: bypass entries allocated in this very tick can issue their memory read in the same tick (reads reg_write.mshr).
* 2908-3016: a refill takes two ticks (table write + `refill_committed`, then response + MSHR free); a dirty victim is parked (global slot / queue) before the table write.
* 1088-1090: non-DCache masters may not have two MSHRs.
* 2079-2105: a write hit on the way an in-flight refill is going to replace updates that MSHR's victim snapshot.
* comb() #1 vs #2: identical ext_out in every tick (see section 1); nothing to reproduce.

## 5.2 Random-traffic verification
`tests/axi_llc/rand_axi.cpp` drives the reference AXI_Interconnect + LLC + sim_ddr with random DCache reads/writes, ICache reads (line and 4-byte
bypass), peripheral bypass reads and peripheral (bypass) writes (`rand_run.sh axi_subsys|axi_llc <seed> <cycles>`, `rand_all.sh`).  `RAND_PWR=0` switches the
peripheral write master off, `RAND_PARTIAL=0` forces full strobes; with `RAND_PARTIAL=1` DCache writes (25 %) use sizes 63..0 at aligned offsets and all
writes use lane subsets / runs / single lanes (peripheral writes also at line offset 0).  The generator runs against a reference compiled WITHOUT `-DNDEBUG`
(the reference's AXI sources contain no `assert` macros, only `static_assert` and two explicit abort paths: meta-tag overflow, consumed-read check): seeds 1-2 at 8 KiB/4w
completed all 30000 cycles without any abort.
Coverage (event counts over seeds 1-8 x {32 KiB/16w, 8 KiB/4w, 16 KiB/2w} x 30000 cycles, `RAND_PWR=1 RAND_PARTIAL=1`, `tests/axi_llc/cover_run.sh`, ticks on which the event
held, summed over the 24 runs):
| path | ticks |
| --- | --- |
| bypass write issued to memory / answered by the memory response | 70408 / 70408 |
| bypass write lookup: hit / miss | 15476 / 43746 |
| bypass lookup resolved after its context was already cleared by the response (strobe 0 quirk) | 17908 |
| partial-strobe write hit (non-bypass) | 17835 |
| partial-line write miss: MSHR allocated / with dirty victim / retried (line in MSHR or no free MSHR) | 55999 / 17164 / 9991 |
| write refill completed (merge + table write + free) / with victim parked | 55992 / 17164 |
| MSHR-owned victim answer arrived / owner entry already freed / owner entry found | 14873 / 14873 / **0** |
The "owner entry found" branch (set `vdone` on a still-allocated entry) is implemented from the C++ but never reached: write entries are freed in the refill tick
and read entries within two ticks, long before the memory answers.  It is unverified.  The generator does not drive writes racing a refill of the same line
specially, but the 4 sets x 40 tags footprint produces them (the partial-miss retry count above is that race).

## 5.1 Open issues / not verified
Not implemented (the `bad` assertion fires if the reference takes the path): the items of section 2 first sentence, plus the owner-answer branch "entry found" is
implemented but has zero coverage.  Not verified: read-response / victim queues deeper than 4 / 8, `stall_lookup_on_table_busy` (never triggered), way-pick
failure paths, mutants 3, 4, 8-10, 13-16 on the rewritten RTL, the corner where a late lookup of a bypass write meets a context refilled in the same tick (the RTL models it,
no run reached it with a distinguishable effect).

## 6. Geometry macros
`rtl/memsys/axi_llc/axi_llc_pkg.sv`: `AXI_LLC_SETS` (default 4096), `AXI_LLC_WAYS` (16), `AXI_LLC_MSHR` (8, only 8 supported: slot id is 3 bits).
Reference side: `TTG_LLC_KB` / `TTG_LLC_WAYS` env (sets = KB*1024/(64*ways)). Example 32 KiB/16 way: `VFLAGS="-DAXI_LLC_SETS=32 -DAXI_LLC_WAYS=16"`.
