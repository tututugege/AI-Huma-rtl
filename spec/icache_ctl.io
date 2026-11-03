# icache_ctl: request slot + miss FSM + AXI transaction bookkeeping + DCache probe + refill + predecode-flush merge (icache_module.cpp ICache,
# icache.cpp glue, ICacheTop.cpp).  Sub-spec of spec/icache.io for bisecting: ITLB answer (ppn*) and array result (hit*, has_invalid) are inputs.
# Fetch-step outputs come from TTG_IC.step[0]; memory-side outputs are the values left on the ports after the LAST call of the cycle.
module icache_ctl
in  refetch        1  @ TTG_IC.in_refetch
in  itlb_flush     1  @ TTG_IC.in_itlb_flush
in  fence_i        1  @ TTG_IC.in_fence_i
in  invalidate     1  @ TTG_FT.do_predecode_flush
in  req_valid_in   1  @ TTG_IC.in_req_valid
in  pc             32 @ TTG_IC.in_fetch_address
in  ppn_valid      1  @ TTG_IC.step[0].m_ppn_valid
in  page_fault     1  @ TTG_IC.step[0].m_page_fault
in  ppn            20 @ TTG_IC.step[0].m_ppn
in  mem_req_ready        1  @ TTG_IC.mem_req_ready
in  mem_req_accepted     1  @ TTG_IC.mem_req_accepted
in  mem_req_accepted_id  4  @ TTG_IC.mem_req_accepted_id
in  mem_resp_valid       1  @ TTG_IC.mem_resp_valid
in  mem_resp_id          4  @ TTG_IC.mem_resp_id
in  mem_resp_data        512 @w TTG_IC.mem_resp_data
in  dc_resp_valid  1  @ TTG_IC.dc_resp_valid
in  dc_resp_retry  1  @ TTG_IC.dc_resp_retry
in  dc_resp_miss   1  @ TTG_IC.dc_resp_miss
in  dc_resp_data   32 @ TTG_IC.dc_resp_data
in  hit            1  @ TTG_IC.step[0].meta_hit_valid
in  hit_line       512 @w TTG_IC.step[0].data_line
in  has_invalid    1  @ TTG_IC.step[0].meta_has_invalid
in  first_invalid  3  @ TTG_IC.step[0].meta_first_invalid
out arr_rd_en      1  @ TTG_IC.step[0].rd_en
out arr_rd_index   6  when arr_rd_en @ TTG_IC.step[0].rd_index
out arr_cmp_valid  1  @ TTG_IC.step[0].meta_cmp_valid
out tw_we          1  @ TTG_IC.step[0].tw_we
out tw_index       6  when tw_we @ TTG_IC.step[0].tw_index
out tw_way         3  when tw_we @ TTG_IC.step[0].tw_way
out tw_tag         20 when tw_we @ TTG_IC.step[0].tw_tag
out tw_line        512 when tw_we @w TTG_IC.step[0].tw_data
out inv_all        1  @ TTG_IC.step[0].tw_inv
out mmu_req_valid  1  @ TTG_IC.itlb_translate_invoked
out mmu_req_vtag   20 when mmu_req_valid @ TTG_IC.step[0].o_mmu_req_vtag
out resp_valid     1  @ TTG_IC.step[0].o_resp_valid
out resp_pc        32 when resp_valid @ TTG_IC.step[0].o_resp_pc
out resp_page_fault 1 when resp_valid @ TTG_IC.step[0].o_page_fault
out resp_single_word 1 when resp_valid @ TTG_IC.step[0].o_single_word
out resp_line      512 when resp_valid @w TTG_IC.step[0].o_rd_data
out icache_ready   1  @ TTG_FT.icache_ready
out mem_req_valid       1  @ TTG_IC.mem_req_valid
out mem_req_addr        32 when mem_req_valid @ TTG_IC.mem_req_addr
out mem_req_total_size  8  when mem_req_valid @ TTG_IC.mem_req_total_size
out mem_req_bypass      1  when mem_req_valid @ TTG_IC.mem_req_bypass
out mem_req_id          4  when mem_req_valid @ TTG_IC.mem_req_id
out mem_resp_ready      1  @ TTG_IC.mem_resp_ready
out dc_req_valid        1  @ TTG_IC.dc_req_valid
out dc_req_addr         32 when dc_req_valid @ TTG_IC.dc_req_addr
