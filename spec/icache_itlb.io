# icache_itlb: the I-cache's ITLB (TlbMmu Kind::ITLB = tlb_mmu_core FETCH) as the I-cache drives it.  Sub-spec of spec/icache.io for bisecting.
# mmu_req_valid = translate_valid of comb_mmu_view (= !refetch && pass-1 mmu_req_valid); mmu_req_vtag = the vtag the I-cache asked for.
# ppn_valid / page_fault / ppn = ICacheMmuRespView applied to the final comb pass (icache_hw.io.in.ppn*).  PTW fields as in spec/icache.io.
module icache_itlb
in  itlb_flush      1  @ TTG_IC.in_itlb_flush
in  refetch         1  @ TTG_IC.in_refetch
in  mmu_req_valid   1  @ TTG_IC.itlb_translate_invoked
in  mmu_req_vtag    20 @ TTG_IC.step[0].o_mmu_req_vtag
in  csr_satp        32 @ TTG_IC.csr_satp
in  csr_privilege   2  @ TTG_IC.csr_privilege
in  csr_mxr         1  @ (TTG_IC.csr_mstatus >> 19) & 1
in  csr_sum         1  @ (TTG_IC.csr_mstatus >> 18) & 1
in  csr_mprv        1  @ (TTG_IC.csr_mstatus >> 17) & 1
in  csr_mpp         2  @ (TTG_IC.csr_mstatus >> 11) & 3
in  ptw_req_ready        1  @ TTG_IC.ptw_req_ready
in  ptw_resp_valid       1  @ TTG_IC.ptw_resp_valid
in  ptw_resp_fault       1  @ TTG_IC.ptw_resp_fault
in  ptw_resp_vpn         20 @ TTG_IC.ptw_resp_vaddr >> 12
in  ptw_resp_leaf_level  1  @ TTG_IC.ptw_resp_leaf_level & 1
in  ptw_resp_leaf_ppn    20 @ (TTG_IC.ptw_resp_leaf_pte >> 10) & 0xFFFFF
in  ptw_resp_leaf_perm   8  @ TTG_IC.ptw_resp_leaf_pte & 0xFF
out ppn_valid    1  @ TTG_IC.step[0].m_ppn_valid
out page_fault   1  @ TTG_IC.step[0].m_page_fault
out ppn          20 @ TTG_IC.step[0].m_ppn
out ptw_req_valid     1  @ TTG_IC.ptw_req_valid
out ptw_req_vpn       20 when ptw_req_valid @ TTG_IC.ptw_req_vaddr >> 12
out ptw_req_root_ppn  22 when ptw_req_valid @ TTG_IC.ptw_req_satp & 0x3FFFFF
out ptw_resp_consumed 1  @ TTG_IC.ptw_resp_consumed
# the stale flush of the reference init call (cycle 1) is added by the top level (icache.sv first_cycle_q), not by the ITLB
out ptw_flush         1  @ TTG_IC.ptw_flush && TTG_FT.count > 2
