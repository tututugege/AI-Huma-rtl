# ICache top (ICacheTop + icache_module + tag/valid/data tables + ITLB), default configuration. See docs/modules/icache.md.
# Boundary = what front_top.cpp S6/S12 (icache_comb_calc, called once per cycle, TWICE in a predecode-flush cycle) exchanges with the rest of the
# SoC.  Inputs are the values AT THE INSTANT icache_comb_calc runs (TTG_IC = second recording tap, refsim_ic tap patch, docs/analysis/icache-record-hook.md);
# the memory-side outputs are what the AXI / DCache probe / PTW ports hold AFTER the last call of the cycle (a predecode flush overrides the first call).
# `invalidate` = do_predecode_flush: the second icache_comb_calc call (invalidate_req); RTL folds it into the same cycle (docs/analysis/icache-boundary.md section 5).
# Not in the spec: reset (never 1 inside the recording window), perf_* outputs, icache_read_ready/_2 of the main call (perf only; the front-end uses the
# peek value `icache_ready`), slot-1 (dual request) signals (compiled out), csr_status.sstatus, perf/debug of icache_module.
# Relaxed (when): see the notes in docs/modules/icache.md section 4 (consumers checked).
module icache

# ---- front-end side inputs ----
in  refetch        1  @ TTG_IC.in_refetch
in  itlb_flush     1  @ TTG_IC.in_itlb_flush
in  fence_i        1  @ TTG_IC.in_fence_i
in  invalidate     1  @ TTG_FT.do_predecode_flush
in  req_valid      1  @ TTG_IC.in_req_valid
in  fetch_address  32 @ TTG_IC.in_fetch_address

# ---- CSR status as read by the ITLB ----
in  csr_status_satp       32 @ TTG_IC.csr_satp
in  csr_status_privilege  2  @ TTG_IC.csr_privilege
in  csr_status_mstatus_mxr  1 @ (TTG_IC.csr_mstatus >> 19) & 1
in  csr_status_mstatus_sum  1 @ (TTG_IC.csr_mstatus >> 18) & 1
in  csr_status_mstatus_mprv 1 @ (TTG_IC.csr_mstatus >> 17) & 1
in  csr_status_mstatus_mpp  2 @ (TTG_IC.csr_mstatus >> 11) & 3

# ---- AXI read master view (ExternalReadPortAdapter::comb_view) ----
in  mem_req_ready        1  @ TTG_IC.mem_req_ready
in  mem_req_accepted     1  @ TTG_IC.mem_req_accepted
in  mem_req_accepted_id  4  @ TTG_IC.mem_req_accepted_id
in  mem_resp_valid       1  @ TTG_IC.mem_resp_valid
in  mem_resp_id          4  @ TTG_IC.mem_resp_id
in  mem_resp_data        32 [16] @ TTG_IC.mem_resp_data[i0]

# ---- DCache coherent word probe response ----
in  dc_resp_valid  1  @ TTG_IC.dc_resp_valid
in  dc_resp_retry  1  @ TTG_IC.dc_resp_retry
in  dc_resp_miss   1  @ TTG_IC.dc_resp_miss
in  dc_resp_data   32 @ TTG_IC.dc_resp_data

# ---- ITLB's PTW walk-port view (values before the ITLB touched the adapter) ----
in  ptw_walk_req_ready       1  @ TTG_IC.ptw_req_ready
in  ptw_walk_resp_valid      1  @ TTG_IC.ptw_resp_valid
in  ptw_walk_resp_fault      1  @ TTG_IC.ptw_resp_fault
in  ptw_walk_resp_vpn        20 @ TTG_IC.ptw_resp_vaddr >> 12
in  ptw_walk_resp_leaf_ppn   20 @ (TTG_IC.ptw_resp_leaf_pte >> 10) & 0xFFFFF
in  ptw_walk_resp_leaf_perm  8  @ TTG_IC.ptw_resp_leaf_pte & 0xFF
in  ptw_walk_resp_leaf_level 1  @ TTG_IC.ptw_resp_leaf_level & 1

# ---- outputs: front-end side ----
out icache_ready    1  @ TTG_FT.icache_ready
out read_complete   1  @ TTG_FT.icache_out.icache_read_complete
out fetch_pc        32 when read_complete @ TTG_FT.icache_out.fetch_pc
out inst_valid      1  [8]  when read_complete @ TTG_FT.icache_out.inst_valid[i0]
out page_fault_inst 1  [8]  when read_complete @ TTG_FT.icache_out.page_fault_inst[i0]
out fetch_group     32 [8]  when read_complete @ TTG_FT.icache_out.fetch_group[i0]

# ---- outputs: AXI read request / response-ready, DCache probe request (after the LAST icache call of the cycle) ----
out mem_req_valid       1  @ TTG_IC.mem_req_valid
out mem_req_addr        32 when mem_req_valid @ TTG_IC.mem_req_addr
out mem_req_total_size  8  when mem_req_valid @ TTG_IC.mem_req_total_size
out mem_req_bypass      1  when mem_req_valid @ TTG_IC.mem_req_bypass
out mem_req_id          4  when mem_req_valid @ TTG_IC.mem_req_id
out mem_resp_ready      1  @ TTG_IC.mem_resp_ready
out dc_req_valid        1  @ TTG_IC.dc_req_valid
out dc_req_addr         32 when dc_req_valid @ TTG_IC.dc_req_addr

# ---- outputs: ITLB -> PTW (adapter comb_in_/seq_in_ after the first call) ----
out ptw_walk_req_valid     1  @ TTG_IC.ptw_req_valid
out ptw_walk_req_vpn       20 when ptw_walk_req_valid @ TTG_IC.ptw_req_vaddr >> 12
out ptw_walk_req_root_ppn  22 when ptw_walk_req_valid @ TTG_IC.ptw_req_satp & 0x3FFFFF
out ptw_walk_resp_consumed 1  @ TTG_IC.ptw_resp_consumed
out ptw_walk_flush         1  @ TTG_IC.ptw_flush
