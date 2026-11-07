# core_top: front end + back end (no memory subsystem).  Boundary = what the core exchanges with the outside world:
#   inputs  : icache AXI read master / DCache probe / ITLB walk client (TTG_IC, values as the icache sees them), the LSU's
#             DCache / MMIO responses, DTLB walk client, interrupt injection (the same expressions as spec/back_top.io)
#   outputs : the same requests (icache side after the last icache call of the cycle, LSU side after back.comb) and the
#             retirement stream (rob_commit / rob_bcast / redirect / next-pc) so that a wrong front end shows up as soon as it
#             changes WHAT retires (the back end's inputs from the front end are no longer boundary signals).
# Everything inside (front_top <-> back_top: back2front register, no-taken cut, hold register, update bundle) is RTL-only.
module core_top

# ===== inputs
in  mem_req_ready        1  @ TTG_IC.mem_req_ready
in  mem_req_accepted     1  @ TTG_IC.mem_req_accepted
in  mem_req_accepted_id  4  @ TTG_IC.mem_req_accepted_id
in  mem_resp_valid       1  @ TTG_IC.mem_resp_valid
in  mem_resp_id          4  @ TTG_IC.mem_resp_id
in  mem_resp_data        32 [16] @ TTG_IC.mem_resp_data[i0]
in  dc_resp_valid  1  @ TTG_IC.dc_resp_valid
in  dc_resp_retry  1  @ TTG_IC.dc_resp_retry
in  dc_resp_miss   1  @ TTG_IC.dc_resp_miss
in  dc_resp_data   32 @ TTG_IC.dc_resp_data
in  itlb_walk_req_ready       1  @ TTG_IC.ptw_req_ready
in  itlb_walk_resp_valid      1  @ TTG_IC.ptw_resp_valid
in  itlb_walk_resp_fault      1  @ TTG_IC.ptw_resp_fault
in  itlb_walk_resp_vpn        20 @ TTG_IC.ptw_resp_vaddr >> 12
in  itlb_walk_resp_leaf_ppn   20 @ (TTG_IC.ptw_resp_leaf_pte >> 10) & 0xFFFFF
in  itlb_walk_resp_leaf_perm  8  @ TTG_IC.ptw_resp_leaf_pte & 0xFF
in  itlb_walk_resp_leaf_level 1  @ TTG_IC.ptw_resp_leaf_level & 1
in  dcache2lsu_load_resps_data 32 [4] @ bt.in.dcache2lsu.resp_ports.load_resps[i0].data
in  dcache2lsu_load_resps_replay 2 [4] @ (uint32_t)bt.in.dcache2lsu.resp_ports.load_resps[i0].replay
in  dcache2lsu_load_resps_req_id 32 [4] @ bt.in.dcache2lsu.resp_ports.load_resps[i0].req_id
in  dcache2lsu_load_resps_valid 1 [4] @ bt.in.dcache2lsu.resp_ports.load_resps[i0].valid
in  dcache2lsu_load_retry_busy 1 [4] @ bt.in.dcache2lsu.load_retry_busy[i0]
in  dcache2lsu_store_retry_busy 1 [4] @ bt.in.dcache2lsu.store_retry_busy[i0]
in  dcache2lsu_mshr_fill 1 @ bt.in.dcache2lsu.mshr_fill
in  dcache2lsu_mshr_fill_line 26 @ (bt.in.dcache2lsu.mshr_fill_addr >> 6)
in  dcache2lsu_store_resps_replay 2 [4] @ (uint32_t)bt.in.dcache2lsu.resp_ports.store_resps[i0].replay
in  dcache2lsu_store_resps_req_id 32 [4] @ bt.in.dcache2lsu.resp_ports.store_resps[i0].req_id
in  dcache2lsu_store_resps_valid 1 [4] @ bt.in.dcache2lsu.resp_ports.store_resps[i0].valid
in  peripheral_resp_is_mmio 1 @ bt.in.peripheral_resp.is_mmio
in  peripheral_resp_mmio_rdata 32 @ bt.in.peripheral_resp.mmio_rdata
in  peripheral_resp_ready 1 @ bt.in.peripheral_resp.ready
in  dtlb_walk_req_ready 1 @ cpu.mem_subsystem.ptw_block.comb_outputs().walk_clients[(size_t)MemSubsystem::PtwClient::DTLB].req_ready
in  dtlb_walk_resp_fault 1 @ cpu.mem_subsystem.ptw_block.comb_outputs().walk_clients[(size_t)MemSubsystem::PtwClient::DTLB].resp.fault
in  dtlb_walk_resp_leaf_level 1 @ ((uint32_t)cpu.mem_subsystem.ptw_block.comb_outputs().walk_clients[(size_t)MemSubsystem::PtwClient::DTLB].resp.leaf_level & 1)
in  dtlb_walk_resp_leaf_perm 8 @ ((uint32_t)cpu.mem_subsystem.ptw_block.comb_outputs().walk_clients[(size_t)MemSubsystem::PtwClient::DTLB].resp.leaf_pte & 0xFF)
in  dtlb_walk_resp_leaf_ppn 20 @ (((uint32_t)cpu.mem_subsystem.ptw_block.comb_outputs().walk_clients[(size_t)MemSubsystem::PtwClient::DTLB].resp.leaf_pte >> 10) & 0xFFFFF)
in  dtlb_walk_resp_valid 1 @ cpu.mem_subsystem.ptw_block.comb_outputs().walk_clients[(size_t)MemSubsystem::PtwClient::DTLB].resp_valid
in  dtlb_walk_resp_vpn 20 @ ((uint32_t)cpu.mem_subsystem.ptw_block.comb_outputs().walk_clients[(size_t)MemSubsystem::PtwClient::DTLB].resp.vaddr >> 12)
in  interrupt_inject_external_irq_pending 1 @ bt.csr_interrupt_inject_io.external_irq_pending
in  interrupt_inject_external_irq_pending_valid 1 @ bt.csr_interrupt_inject_io.external_irq_pending_valid
in  interrupt_inject_supervisor_external_irq_pending 1 @ bt.csr_interrupt_inject_io.supervisor_external_irq_pending
in  interrupt_inject_supervisor_external_irq_pending_valid 1 @ bt.csr_interrupt_inject_io.supervisor_external_irq_pending_valid
in  interrupt_inject_timer_irq_pending 1 @ bt.csr_interrupt_inject_io.timer_irq_pending
in  interrupt_inject_timer_irq_pending_valid 1 @ bt.csr_interrupt_inject_io.timer_irq_pending_valid

# ===== outputs
out mem_req_valid       1  @ TTG_IC.mem_req_valid
out mem_req_addr        32 when mem_req_valid @ TTG_IC.mem_req_addr
out mem_req_total_size  8  when mem_req_valid @ TTG_IC.mem_req_total_size
out mem_req_bypass      1  when mem_req_valid @ TTG_IC.mem_req_bypass
out mem_req_id          4  when mem_req_valid @ TTG_IC.mem_req_id
out mem_resp_ready      1  @ TTG_IC.mem_resp_ready
out dc_req_valid        1  @ TTG_IC.dc_req_valid
out dc_req_addr         32 when dc_req_valid @ TTG_IC.dc_req_addr
out itlb_walk_req_valid     1  @ TTG_IC.ptw_req_valid
out itlb_walk_req_vpn       20 when itlb_walk_req_valid @ TTG_IC.ptw_req_vaddr >> 12
out itlb_walk_req_root_ppn  22 when itlb_walk_req_valid @ TTG_IC.ptw_req_satp & 0x3FFFFF
out itlb_walk_resp_consumed 1  @ TTG_IC.ptw_resp_consumed
out itlb_walk_flush         1  @ TTG_IC.ptw_flush
out dtlb_walk_flush 1 @ [&]{ struct M{ virtual ~M(){} PtwWalkPortCombIn in; PtwWalkPortSeqIn sq; PtwWalkPortCombOut out; }; return reinterpret_cast<M*>(cpu.mem_subsystem.dtlb_walk_port)->sq.flush; }()
out dtlb_walk_req_root_ppn 22 when dtlb_walk_req_valid @ ((uint32_t)[&]{ struct M{ virtual ~M(){} PtwWalkPortCombIn in; PtwWalkPortSeqIn sq; PtwWalkPortCombOut out; }; return reinterpret_cast<M*>(cpu.mem_subsystem.dtlb_walk_port)->in.req.satp; }() & 0x3FFFFF)
out dtlb_walk_req_valid 1 @ [&]{ struct M{ virtual ~M(){} PtwWalkPortCombIn in; PtwWalkPortSeqIn sq; PtwWalkPortCombOut out; }; return reinterpret_cast<M*>(cpu.mem_subsystem.dtlb_walk_port)->in.req_valid; }()
out dtlb_walk_req_vpn 20 when dtlb_walk_req_valid @ ((uint32_t)[&]{ struct M{ virtual ~M(){} PtwWalkPortCombIn in; PtwWalkPortSeqIn sq; PtwWalkPortCombOut out; }; return reinterpret_cast<M*>(cpu.mem_subsystem.dtlb_walk_port)->in.req.vaddr; }() >> 12)
out dtlb_walk_resp_consumed 1 @ [&]{ struct M{ virtual ~M(){} PtwWalkPortCombIn in; PtwWalkPortSeqIn sq; PtwWalkPortCombOut out; }; return reinterpret_cast<M*>(cpu.mem_subsystem.dtlb_walk_port)->in.resp_consumed; }()
out lsu2dcache_load_ports_addr 32 [4] when lsu2dcache_load_ports_valid @ bt.out.lsu2dcache.req_ports.load_ports[i0].addr
out lsu2dcache_load_ports_req_id 31 [4] when lsu2dcache_load_ports_valid @ (bt.out.lsu2dcache.req_ports.load_ports[i0].req_id & 0x7fffffffu)
out lsu2dcache_load_ports_valid 1 [4] @ bt.out.lsu2dcache.req_ports.load_ports[i0].valid
out lsu2dcache_store_ports_addr 32 [4] when lsu2dcache_store_ports_valid @ bt.out.lsu2dcache.req_ports.store_ports[i0].addr
out lsu2dcache_store_ports_data 32 [4] when lsu2dcache_store_ports_valid @ bt.out.lsu2dcache.req_ports.store_ports[i0].data
out lsu2dcache_store_ports_req_id 6 [4] when lsu2dcache_store_ports_valid @ bt.out.lsu2dcache.req_ports.store_ports[i0].req_id
out lsu2dcache_store_ports_strb 5 [4] when lsu2dcache_store_ports_valid @ (bt.out.lsu2dcache.req_ports.store_ports[i0].strb & 0x1f)
out lsu2dcache_store_ports_valid 1 [4] @ bt.out.lsu2dcache.req_ports.store_ports[i0].valid
out peripheral_req_is_mmio 1 @ bt.out.peripheral_req.is_mmio
out peripheral_req_mmio_addr 32 when peripheral_req_is_mmio @ bt.out.peripheral_req.mmio_addr
out peripheral_req_mmio_fun3 3 when peripheral_req_is_mmio @ bt.out.peripheral_req.mmio_fun3
out peripheral_req_mmio_wdata 32 when peripheral_req_wen @ bt.out.peripheral_req.mmio_wdata
out peripheral_req_wen 1 @ bt.out.peripheral_req.wen
out rob_bcast_exception 1 @ bt.rob_bcast.exception
out rob_bcast_fence 1 @ bt.rob_bcast.fence
out rob_bcast_fence_i 1 @ bt.rob_bcast.fence_i
out rob_bcast_flush 1 @ bt.rob_bcast.flush
out rob_bcast_mret 1 @ bt.rob_bcast.mret
out rob_bcast_pc 32 when rob_bcast_flush @ bt.rob_bcast.pc
out rob_bcast_sret 1 @ bt.rob_bcast.sret
out rob_commit_commit_entry_uop_br_taken 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.br_taken
out rob_commit_commit_entry_uop_dest_areg 6 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.dest_areg
out rob_commit_commit_entry_uop_dest_en 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.dest_en
out rob_commit_commit_entry_uop_page_fault_inst 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.page_fault_inst
out rob_commit_commit_entry_uop_page_fault_load 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.page_fault_load
out rob_commit_commit_entry_uop_page_fault_store 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.page_fault_store
out rob_commit_commit_entry_uop_rob_flag 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.rob_flag
out rob_commit_commit_entry_uop_rob_idx 7 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.rob_idx
out rob_commit_commit_entry_uop_stq_flag 1 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.stq_flag
out rob_commit_commit_entry_uop_stq_idx 6 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.stq_idx
out rob_commit_commit_entry_uop_type 5 [8] when rob_commit_commit_entry_valid @ bt.rob_commit.commit_entry[i0].uop.type
out rob_commit_commit_entry_valid 1 [8] @ bt.rob_commit.commit_entry[i0].valid
out out_commit_entry_uop_diag_val 32 [8] when rob_commit_commit_entry_valid @ bt.out.commit_entry[i0].uop.diag_val
out out_mispred 1 @ bt.out.mispred
out out_redirect_pc 32 when out_mispred @ bt.out.redirect_pc
out ftq_commit_info_resp_pc 32 [8] when rob_commit_commit_entry_valid @ bt.ftq_commit_info.resp[i0].pc
