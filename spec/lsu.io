# RealLsu (back-end/Lsu/RealLsu.cpp): LDQ, STQ, store-to-load forwarding, MMIO, TLB/DCache handshakes, flush/mispred kill.
# Boundary = the RealLsu::comb_* inputs/outputs; recorded after BackTop::comb() (every wire below is final-value == value read by the LSU stage,
# checked in docs/modules/lsu.md section 1).  The MMU sits between comb_tlb_out and comb_tlb_in_*; mmu2lsu is recorded as an input.
# Omitted on purpose (docs/modules/lsu.md section 4): perf/debug (tma.miss_mask, dbg, *.replay request flags, icache_req), csr_status (pure pass-through
#   to the MMU), dis2lsu.func3/stq_flag (overwritten/assert-only), exe2lsu op/br_mask/dest_en/ldq_idx of STA, dcache bank_conflict/retry,
#   lsu2exe op/flush_pipe (constants LOAD/STA/0 per port), stq_commit pointer (derived), diag_val of LDQ (== v_addr).
# Static port mapping (Exu.cpp): agu_req[0..3] are the LD ports (UOP_LOAD), agu_req[4..7] the STA ports.
module lsu

# ---- inputs ----
in  rob_commit_commit_entry_valid 1 [8] @ bt.rob_commit.commit_entry[i0].valid
in  rob_commit_commit_entry_uop_type 5 [8] @ bt.rob_commit.commit_entry[i0].uop.type
in  rob_commit_commit_entry_uop_amo_op 5 [8] @ (bt.rob_commit.commit_entry[i0].uop.func7 >> 2)
in  rob_commit_commit_entry_uop_stq_idx 6 [8] @ bt.rob_commit.commit_entry[i0].uop.stq_idx
in  rob_bcast_flush 1 @ bt.rob_bcast.flush
in  rob_bcast_head_valid 1 @ bt.rob_bcast.head_valid
in  rob_bcast_head_rob_idx 7 @ bt.rob_bcast.head_rob_idx
in  rob_bcast_head_incomplete_valid 1 @ bt.rob_bcast.head_incomplete_valid
in  rob_bcast_head_incomplete_rob_idx 7 @ bt.rob_bcast.head_incomplete_rob_idx
in  dec_bcast_mispred 1 @ bt.dec_bcast.mispred
in  dec_bcast_br_mask 64 @ bt.dec_bcast.br_mask
in  dec_bcast_clear_mask 64 @ bt.dec_bcast.clear_mask
in  dis2lsu_alloc_req 1 [8] @ bt.dis2lsu.alloc_req[i0]
in  dis2lsu_br_mask 64 [8] @ bt.dis2lsu.br_mask[i0]
in  dis2lsu_rob_idx 7 [8] @ bt.dis2lsu.rob_idx[i0]
in  dis2lsu_rob_flag 1 [8] @ bt.dis2lsu.rob_flag[i0]
in  dis2lsu_ldq_alloc_req 1 [8] @ bt.dis2lsu.ldq_alloc_req[i0]
in  dis2lsu_ldq_idx 6 [8] @ bt.dis2lsu.ldq_idx[i0]
in  dis2lsu_ldq_br_mask 64 [8] @ bt.dis2lsu.ldq_br_mask[i0]
in  dis2lsu_ldq_rob_idx 7 [8] @ bt.dis2lsu.ldq_rob_idx[i0]
in  dis2lsu_ldq_rob_flag 1 [8] @ bt.dis2lsu.ldq_rob_flag[i0]
in  exe2lsu_sdu_req_valid 1 [4] @ bt.exe2lsu.sdu_req[i0].valid
in  exe2lsu_sdu_req_uop_result 32 [4] @ bt.exe2lsu.sdu_req[i0].uop.result
in  exe2lsu_sdu_req_uop_rob_idx 7 [4] @ bt.exe2lsu.sdu_req[i0].uop.rob_idx
in  exe2lsu_sdu_req_uop_rob_flag 1 [4] @ bt.exe2lsu.sdu_req[i0].uop.rob_flag
in  exe2lsu_sdu_req_uop_stq_idx 6 [4] @ bt.exe2lsu.sdu_req[i0].uop.stq_idx
in  exe2lsu_ldu_req_valid 1 [4] @ bt.exe2lsu.agu_req[i0].valid
in  exe2lsu_ldu_req_uop_result 32 [4] @ bt.exe2lsu.agu_req[i0].uop.result
in  exe2lsu_ldu_req_uop_dest_preg 7 [4] @ bt.exe2lsu.agu_req[i0].uop.dest_preg
in  exe2lsu_ldu_req_uop_func3 3 [4] @ bt.exe2lsu.agu_req[i0].uop.func3
in  exe2lsu_ldu_req_uop_is_atomic 1 [4] @ bt.exe2lsu.agu_req[i0].uop.is_atomic
in  exe2lsu_ldu_req_uop_amo_op 5 [4] @ (bt.exe2lsu.agu_req[i0].uop.func7 >> 2)
in  exe2lsu_ldu_req_uop_rob_idx 7 [4] @ bt.exe2lsu.agu_req[i0].uop.rob_idx
in  exe2lsu_ldu_req_uop_rob_flag 1 [4] @ bt.exe2lsu.agu_req[i0].uop.rob_flag
in  exe2lsu_ldu_req_uop_stq_idx 6 [4] @ bt.exe2lsu.agu_req[i0].uop.stq_idx
in  exe2lsu_ldu_req_uop_stq_flag 1 [4] @ bt.exe2lsu.agu_req[i0].uop.stq_flag
in  exe2lsu_ldu_req_uop_ldq_idx 6 [4] @ bt.exe2lsu.agu_req[i0].uop.ldq_idx
in  exe2lsu_sta_req_valid 1 [4] @ bt.exe2lsu.agu_req[i0+4].valid
in  exe2lsu_sta_req_uop_result 32 [4] @ bt.exe2lsu.agu_req[i0+4].uop.result
in  exe2lsu_sta_req_uop_dest_preg 7 [4] @ bt.exe2lsu.agu_req[i0+4].uop.dest_preg
in  exe2lsu_sta_req_uop_func3 3 [4] @ bt.exe2lsu.agu_req[i0+4].uop.func3
in  exe2lsu_sta_req_uop_is_atomic 1 [4] @ bt.exe2lsu.agu_req[i0+4].uop.is_atomic
in  exe2lsu_sta_req_uop_amo_op 5 [4] @ (bt.exe2lsu.agu_req[i0+4].uop.func7 >> 2)
in  exe2lsu_sta_req_uop_rob_idx 7 [4] @ bt.exe2lsu.agu_req[i0+4].uop.rob_idx
in  exe2lsu_sta_req_uop_rob_flag 1 [4] @ bt.exe2lsu.agu_req[i0+4].uop.rob_flag
in  exe2lsu_sta_req_uop_stq_idx 6 [4] @ bt.exe2lsu.agu_req[i0+4].uop.stq_idx
in  peripheral_resp_is_mmio 1 @ bt.in.peripheral_resp.is_mmio
in  peripheral_resp_ready 1 @ bt.in.peripheral_resp.ready
in  peripheral_resp_mmio_rdata 32 @ bt.in.peripheral_resp.mmio_rdata
in  dcache2lsu_load_resps_valid 1 [4] @ bt.in.dcache2lsu.resp_ports.load_resps[i0].valid
in  dcache2lsu_load_resps_req_id 32 [4] @ bt.in.dcache2lsu.resp_ports.load_resps[i0].req_id
in  dcache2lsu_load_resps_data 32 [4] @ bt.in.dcache2lsu.resp_ports.load_resps[i0].data
in  dcache2lsu_load_resps_replay 2 [4] @ (uint32_t)bt.in.dcache2lsu.resp_ports.load_resps[i0].replay
in  dcache2lsu_store_resps_valid 1 [4] @ bt.in.dcache2lsu.resp_ports.store_resps[i0].valid
in  dcache2lsu_store_resps_req_id 32 [4] @ bt.in.dcache2lsu.resp_ports.store_resps[i0].req_id
in  dcache2lsu_store_resps_replay 2 [4] @ (uint32_t)bt.in.dcache2lsu.resp_ports.store_resps[i0].replay
in  dcache2lsu_mshr_fill 1 @ bt.in.dcache2lsu.mshr_fill
in  dcache2lsu_mshr_fill_line 26 @ (bt.in.dcache2lsu.mshr_fill_addr >> 6)
in  mmu2lsu_ldq_resp_valid 1 [4] @ bt.mmu2lsu_io.ldq_resp[i0].valid
in  mmu2lsu_ldq_resp_paddr 32 [4] @ bt.mmu2lsu_io.ldq_resp[i0].paddr
in  mmu2lsu_ldq_resp_result 2 [4] @ (uint32_t)bt.mmu2lsu_io.ldq_resp[i0].result
in  mmu2lsu_ldq_resp_entry_idx 6 [4] @ bt.mmu2lsu_io.ldq_resp[i0].entry_idx
in  mmu2lsu_ldq_resp_wait_idx 6 [4] @ bt.mmu2lsu_io.ldq_resp[i0].wait_idx
in  mmu2lsu_stq_resp_valid 1 [4] @ bt.mmu2lsu_io.stq_resp[i0].valid
in  mmu2lsu_stq_resp_paddr 32 [4] @ bt.mmu2lsu_io.stq_resp[i0].paddr
in  mmu2lsu_stq_resp_result 2 [4] @ (uint32_t)bt.mmu2lsu_io.stq_resp[i0].result
in  mmu2lsu_stq_resp_entry_idx 6 [4] @ bt.mmu2lsu_io.stq_resp[i0].entry_idx
in  mmu2lsu_stq_resp_wait_idx 6 [4] @ bt.mmu2lsu_io.stq_resp[i0].wait_idx

# ---- outputs ----
out lsu2dis_stq_tail 6 @ bt.lsu2dis.stq_tail
out lsu2dis_stq_tail_flag 1 @ bt.lsu2dis.stq_tail_flag
out lsu2dis_stq_free 7 @ bt.lsu2dis.stq_free
out lsu2dis_ldq_free 7 @ bt.lsu2dis.ldq_free
out lsu2dis_ldq_alloc_valid 1 [8] @ bt.lsu2dis.ldq_alloc_valid[i0]
out lsu2dis_ldq_alloc_idx 6 [8] when lsu2dis_ldq_alloc_valid @ bt.lsu2dis.ldq_alloc_idx[i0]
out lsu2rob_committed_store_pending 1 @ bt.lsu2rob.committed_store_pending
out lsu2exe_wb_req_valid 1 [4] @ bt.lsu2exe.wb_req[i0].valid
out lsu2exe_wb_req_uop_diag_val 32 [4] when lsu2exe_wb_req_valid @ bt.lsu2exe.wb_req[i0].uop.diag_val
out lsu2exe_wb_req_uop_result 32 [4] when lsu2exe_wb_req_valid @ bt.lsu2exe.wb_req[i0].uop.result
out lsu2exe_wb_req_uop_dest_preg 7 [4] when lsu2exe_wb_req_valid @ bt.lsu2exe.wb_req[i0].uop.dest_preg
out lsu2exe_wb_req_uop_br_mask 64 [4] when lsu2exe_wb_req_valid @ bt.lsu2exe.wb_req[i0].uop.br_mask
out lsu2exe_wb_req_uop_rob_idx 7 [4] when lsu2exe_wb_req_valid @ bt.lsu2exe.wb_req[i0].uop.rob_idx
out lsu2exe_wb_req_uop_dest_en 1 [4] when lsu2exe_wb_req_valid @ bt.lsu2exe.wb_req[i0].uop.dest_en
out lsu2exe_wb_req_uop_page_fault_load 1 [4] when lsu2exe_wb_req_valid @ bt.lsu2exe.wb_req[i0].uop.page_fault_load
out lsu2exe_wb_req_uop_page_fault_store 1 [4] when lsu2exe_wb_req_valid @ bt.lsu2exe.wb_req[i0].uop.page_fault_store
out lsu2exe_sta_wb_req_valid 1 [4] @ bt.lsu2exe.sta_wb_req[i0].valid
out lsu2exe_sta_wb_req_uop_diag_val 32 [4] when lsu2exe_sta_wb_req_valid @ bt.lsu2exe.sta_wb_req[i0].uop.diag_val
out lsu2exe_sta_wb_req_uop_result 32 [4] when lsu2exe_sta_wb_req_valid @ bt.lsu2exe.sta_wb_req[i0].uop.result
out lsu2exe_sta_wb_req_uop_br_mask 64 [4] when lsu2exe_sta_wb_req_valid @ bt.lsu2exe.sta_wb_req[i0].uop.br_mask
out lsu2exe_sta_wb_req_uop_rob_idx 7 [4] when lsu2exe_sta_wb_req_valid @ bt.lsu2exe.sta_wb_req[i0].uop.rob_idx
out lsu2exe_sta_wb_req_uop_page_fault_store 1 [4] when lsu2exe_sta_wb_req_valid @ bt.lsu2exe.sta_wb_req[i0].uop.page_fault_store
out peripheral_req_is_mmio 1 @ bt.out.peripheral_req.is_mmio
out peripheral_req_wen 1 @ bt.out.peripheral_req.wen
out peripheral_req_mmio_addr 32 when peripheral_req_is_mmio @ bt.out.peripheral_req.mmio_addr
out peripheral_req_mmio_wdata 32 when peripheral_req_wen @ bt.out.peripheral_req.mmio_wdata
out peripheral_req_mmio_fun3 3 when peripheral_req_is_mmio @ bt.out.peripheral_req.mmio_fun3
out lsu2dcache_load_ports_valid 1 [4] @ bt.out.lsu2dcache.req_ports.load_ports[i0].valid
out lsu2dcache_load_ports_addr 32 [4] when lsu2dcache_load_ports_valid @ bt.out.lsu2dcache.req_ports.load_ports[i0].addr
out lsu2dcache_load_ports_req_id 31 [4] when lsu2dcache_load_ports_valid @ (bt.out.lsu2dcache.req_ports.load_ports[i0].req_id & 0x7fffffffu)
out lsu2dcache_store_ports_valid 1 [4] @ bt.out.lsu2dcache.req_ports.store_ports[i0].valid
out lsu2dcache_store_ports_addr 32 [4] when lsu2dcache_store_ports_valid @ bt.out.lsu2dcache.req_ports.store_ports[i0].addr
out lsu2dcache_store_ports_data 32 [4] when lsu2dcache_store_ports_valid @ bt.out.lsu2dcache.req_ports.store_ports[i0].data
out lsu2dcache_store_ports_strb 5 [4] when lsu2dcache_store_ports_valid @ (bt.out.lsu2dcache.req_ports.store_ports[i0].strb & 0x1f)
out lsu2dcache_store_ports_req_id 6 [4] when lsu2dcache_store_ports_valid @ bt.out.lsu2dcache.req_ports.store_ports[i0].req_id
out lsu2mmu_ldq_req_valid 1 [4] @ bt.lsu2mmu_io.ldq_req[i0].valid
out lsu2mmu_ldq_req_vaddr 32 [4] when lsu2mmu_ldq_req_valid @ bt.lsu2mmu_io.ldq_req[i0].vaddr
out lsu2mmu_ldq_req_entry_idx 6 [4] when lsu2mmu_ldq_req_valid @ bt.lsu2mmu_io.ldq_req[i0].entry_idx
out lsu2mmu_ldq_req_wait_idx 6 [4] when lsu2mmu_ldq_req_valid @ bt.lsu2mmu_io.ldq_req[i0].wait_idx
out lsu2mmu_stq_req_valid 1 [4] @ bt.lsu2mmu_io.stq_req[i0].valid
out lsu2mmu_stq_req_vaddr 32 [4] when lsu2mmu_stq_req_valid @ bt.lsu2mmu_io.stq_req[i0].vaddr
out lsu2mmu_stq_req_entry_idx 6 [4] when lsu2mmu_stq_req_valid @ bt.lsu2mmu_io.stq_req[i0].entry_idx
out lsu2mmu_stq_req_wait_idx 6 [4] when lsu2mmu_stq_req_valid @ bt.lsu2mmu_io.stq_req[i0].wait_idx
