# TlbMmu, DTLB instance (back-end). Ref: back-end/Lsu/TlbMmu.cpp  TlbMmu::translate_lsu_ports / flush / cancel_pending_walk / seq,
# kernel back-end/Lsu/include/TlbMmuKernel.h. Boundary = BackTop::comb_lsu_mmu(): lsu2mmu_io -> mmu2lsu_io, rob_bcast.fence/flush, dec_bcast.mispred,
# and the PtwWalkPort (dtlb_walk_port) seen from the TLB side.
# Not translated: last_retry_reason / trace_* / record_trace / dump_debug / DebugState (debug only), the local-walker path (walker.start; unused when a walk
#   port is connected), tlb_capacity / Kind-dependent top port count (compile-time parameters in the RTL).
# PTW inputs are recorded from ptw_block.comb_outputs().walk_clients[DTLB], i.e. the values the walk-port adapter held when TlbMmu first read it
#   (TlbMmu itself modifies the adapter through consume_resp/send_walk_req/flush_client, so reading the adapter after comb would show the modified value).
# PTW outputs are the adapter's comb_in_ (req_valid/req/resp_consumed) and seq_in_.flush, which only TlbMmu writes in this cycle (mirror struct of the adapter layout).
# Only the fields with consumers are kept (see docs/modules/tlb_mmu.md): PTW reads req.vaddr[31:12] and req.satp[21:0]; access_type is forced to 0 by the PTW.
# Qualifier outputs *_hit exist only because `when` must name an output (paddr is meaningful only for a HIT response).
module tlb_mmu

# ---- inputs: LSU requests ----
in  ldq_req_valid 1 [4] @ bt.lsu2mmu_io.ldq_req[i0].valid
in  ldq_req_vaddr 32 [4] @ bt.lsu2mmu_io.ldq_req[i0].vaddr
in  ldq_req_entry_idx 6 [4] @ bt.lsu2mmu_io.ldq_req[i0].entry_idx
in  ldq_req_wait_idx 6 [4] @ bt.lsu2mmu_io.ldq_req[i0].wait_idx
in  stq_req_valid 1 [4] @ bt.lsu2mmu_io.stq_req[i0].valid
in  stq_req_vaddr 32 [4] @ bt.lsu2mmu_io.stq_req[i0].vaddr
in  stq_req_entry_idx 6 [4] @ bt.lsu2mmu_io.stq_req[i0].entry_idx
in  stq_req_wait_idx 6 [4] @ bt.lsu2mmu_io.stq_req[i0].wait_idx

# ---- inputs: CSR status (as read by TlbMmu: bt.lsu2mmu_io.csr_status) ----
in  csr_status_satp 32 @ bt.lsu2mmu_io.csr_status.satp
in  csr_status_privilege 2 @ bt.lsu2mmu_io.csr_status.privilege
in  csr_status_mstatus_mxr 1 @ ((uint32_t)bt.lsu2mmu_io.csr_status.mstatus >> 19) & 1
in  csr_status_mstatus_sum 1 @ ((uint32_t)bt.lsu2mmu_io.csr_status.mstatus >> 18) & 1
in  csr_status_mstatus_mprv 1 @ ((uint32_t)bt.lsu2mmu_io.csr_status.mstatus >> 17) & 1
in  csr_status_mstatus_mpp 2 @ ((uint32_t)bt.lsu2mmu_io.csr_status.mstatus >> 11) & 3

# ---- inputs: control (BackTop::comb_lsu_mmu) ----
in  rob_bcast_fence 1 @ bt.rob_bcast.fence
in  rob_bcast_flush 1 @ bt.rob_bcast.flush
in  dec_bcast_mispred 1 @ bt.dec_bcast.mispred

# ---- inputs: PTW walk port, TLB side view (pre-modification values) ----
in  ptw_walk_req_ready 1 @ cpu.mem_subsystem.ptw_block.comb_outputs().walk_clients[(size_t)MemSubsystem::PtwClient::DTLB].req_ready
in  ptw_walk_resp_valid 1 @ cpu.mem_subsystem.ptw_block.comb_outputs().walk_clients[(size_t)MemSubsystem::PtwClient::DTLB].resp_valid
in  ptw_walk_resp_fault 1 @ cpu.mem_subsystem.ptw_block.comb_outputs().walk_clients[(size_t)MemSubsystem::PtwClient::DTLB].resp.fault
in  ptw_walk_resp_vpn 20 @ ((uint32_t)cpu.mem_subsystem.ptw_block.comb_outputs().walk_clients[(size_t)MemSubsystem::PtwClient::DTLB].resp.vaddr >> 12)
in  ptw_walk_resp_leaf_ppn 20 @ (((uint32_t)cpu.mem_subsystem.ptw_block.comb_outputs().walk_clients[(size_t)MemSubsystem::PtwClient::DTLB].resp.leaf_pte >> 10) & 0xFFFFF)
in  ptw_walk_resp_leaf_perm 8 @ ((uint32_t)cpu.mem_subsystem.ptw_block.comb_outputs().walk_clients[(size_t)MemSubsystem::PtwClient::DTLB].resp.leaf_pte & 0xFF)
in  ptw_walk_resp_leaf_level 1 @ ((uint32_t)cpu.mem_subsystem.ptw_block.comb_outputs().walk_clients[(size_t)MemSubsystem::PtwClient::DTLB].resp.leaf_level & 1)

# ---- outputs: LSU responses ----
out ldq_resp_valid 1 [4] @ bt.mmu2lsu_io.ldq_resp[i0].valid
out ldq_resp_result 2 [4] when ldq_resp_valid @ (uint32_t)bt.mmu2lsu_io.ldq_resp[i0].result
out ldq_resp_hit 1 [4] @ (bt.mmu2lsu_io.ldq_resp[i0].valid && bt.mmu2lsu_io.ldq_resp[i0].result == MMUResultType::HIT)
out ldq_resp_paddr 32 [4] when ldq_resp_hit @ bt.mmu2lsu_io.ldq_resp[i0].paddr
out ldq_resp_entry_idx 6 [4] when ldq_resp_valid @ bt.mmu2lsu_io.ldq_resp[i0].entry_idx
out ldq_resp_wait_idx 6 [4] when ldq_resp_valid @ bt.mmu2lsu_io.ldq_resp[i0].wait_idx
out stq_resp_valid 1 [4] @ bt.mmu2lsu_io.stq_resp[i0].valid
out stq_resp_result 2 [4] when stq_resp_valid @ (uint32_t)bt.mmu2lsu_io.stq_resp[i0].result
out stq_resp_hit 1 [4] @ (bt.mmu2lsu_io.stq_resp[i0].valid && bt.mmu2lsu_io.stq_resp[i0].result == MMUResultType::HIT)
out stq_resp_paddr 32 [4] when stq_resp_hit @ bt.mmu2lsu_io.stq_resp[i0].paddr
out stq_resp_entry_idx 6 [4] when stq_resp_valid @ bt.mmu2lsu_io.stq_resp[i0].entry_idx
out stq_resp_wait_idx 6 [4] when stq_resp_valid @ bt.mmu2lsu_io.stq_resp[i0].wait_idx

# ---- outputs: PTW walk port, TLB -> PTW ----
out ptw_walk_req_valid 1 @ [&]{ struct M{ virtual ~M(){} PtwWalkPortCombIn in; PtwWalkPortSeqIn sq; PtwWalkPortCombOut out; }; return reinterpret_cast<M*>(cpu.mem_subsystem.dtlb_walk_port)->in.req_valid; }()
out ptw_walk_req_vpn 20 when ptw_walk_req_valid @ ((uint32_t)[&]{ struct M{ virtual ~M(){} PtwWalkPortCombIn in; PtwWalkPortSeqIn sq; PtwWalkPortCombOut out; }; return reinterpret_cast<M*>(cpu.mem_subsystem.dtlb_walk_port)->in.req.vaddr; }() >> 12)
out ptw_walk_req_root_ppn 22 when ptw_walk_req_valid @ ((uint32_t)[&]{ struct M{ virtual ~M(){} PtwWalkPortCombIn in; PtwWalkPortSeqIn sq; PtwWalkPortCombOut out; }; return reinterpret_cast<M*>(cpu.mem_subsystem.dtlb_walk_port)->in.req.satp; }() & 0x3FFFFF)
out ptw_walk_resp_consumed 1 @ [&]{ struct M{ virtual ~M(){} PtwWalkPortCombIn in; PtwWalkPortSeqIn sq; PtwWalkPortCombOut out; }; return reinterpret_cast<M*>(cpu.mem_subsystem.dtlb_walk_port)->in.resp_consumed; }()
out ptw_walk_flush 1 @ [&]{ struct M{ virtual ~M(){} PtwWalkPortCombIn in; PtwWalkPortSeqIn sq; PtwWalkPortCombOut out; }; return reinterpret_cast<M*>(cpu.mem_subsystem.dtlb_walk_port)->sq.flush; }()
