# front_top: the whole front end (BPU, ICache+ITLB, 4 queues, predecode, checker, front_ctrl) = FrontTop::comb_bpu() /
# front_comb_calc.  Boundary = front.in / front.out of front_top.cpp plus the memory-side ports of the icache.
# Inputs: the REGISTERED back2front values the front end sees (front.in: refetch, refetch_address, itlb_flush, fence_i,
# FIFO_read_enable, csr_status, the commit-update bundle of the BPU), and the memory side as the icache sees it (TTG_IC).
# Outputs: front.out (what front_comb_before_back copies into back.in, BEFORE the back end's no-taken truncation and the
# 8 -> 16 lane widening, which are SimCpu glue), plus the icache's memory-side requests.
# Not in the spec: front.in.reset (1 only inside init(); rst_n), front.out.commit_stall (BPU update_queue_full, constant 0),
# the SC-L / loop predictor metadata of front.out (constant 0 with ENABLE_TAGE_SC_L=0, ENABLE_TAGE_LOOP_PRED=0), perf/debug.
# Relaxed (when): front.out payload only when FIFO_valid (when it is invalid the C++ shows a zeroed / stale entry; the back end
# copies the payload into back.in but PreIduQueue reads it only inside its incoming_valid_num > 0 branch and for lanes with
# valid = FIFO_valid & inst_valid[i] & no-taken, a subset of what is compared here).  The memory-side request fields only when the request is valid.
module front_top

# ---- back end -> front end ----
in  be_refetch          1  @ cpu.front.in.refetch
in  be_refetch_address  32 @ cpu.front.in.refetch_address
in  itlb_flush          1  @ TTG_IC.in_itlb_flush
in  fence_i             1  @ TTG_IC.in_fence_i
in  fifo_read_enable    1  @ cpu.front.in.FIFO_read_enable
in  csr_status_satp       32 @ TTG_IC.csr_satp
in  csr_status_privilege  2  @ TTG_IC.csr_privilege
in  csr_status_mstatus_mxr  1 @ (TTG_IC.csr_mstatus >> 19) & 1
in  csr_status_mstatus_sum  1 @ (TTG_IC.csr_mstatus >> 18) & 1
in  csr_status_mstatus_mprv 1 @ (TTG_IC.csr_mstatus >> 17) & 1
in  csr_status_mstatus_mpp  2 @ (TTG_IC.csr_mstatus >> 11) & 3
in  upd_valid  1  [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_upd_valid[i0]
in  base_pc    32 [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_update_base_pc[i0]
in  actual_dir 1  [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_actual_dir[i0]
in  br_type    3  [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_actual_br_type[i0]
in  target     32 [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_actual_targets[i0]
in  pred_dir   1  [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_pred_dir[i0]
in  alt_pred   1  [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_alt_pred[i0]
in  pcpn       3  [8]    @ cpu.front.update_req_->bpu_seq_txn.inp.in_pcpn[i0]
in  tags       8  [8][4] @ cpu.front.update_req_->bpu_seq_txn.inp.in_tage_tags[i0][i1]
in  idxs       10 [8][4] @ cpu.front.update_req_->bpu_seq_txn.inp.in_tage_idxs[i0][i1]

# ---- memory side inputs (icache view, TTG_IC) ----
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
in  ptw_walk_req_ready       1  @ TTG_IC.ptw_req_ready
in  ptw_walk_resp_valid      1  @ TTG_IC.ptw_resp_valid
in  ptw_walk_resp_fault      1  @ TTG_IC.ptw_resp_fault
in  ptw_walk_resp_vpn        20 @ TTG_IC.ptw_resp_vaddr >> 12
in  ptw_walk_resp_leaf_ppn   20 @ (TTG_IC.ptw_resp_leaf_pte >> 10) & 0xFFFFF
in  ptw_walk_resp_leaf_perm  8  @ TTG_IC.ptw_resp_leaf_pte & 0xFF
in  ptw_walk_resp_leaf_level 1  @ TTG_IC.ptw_resp_leaf_level & 1

# ---- front end -> back end (front.out) ----
out out_valid            1 @ cpu.front.out.FIFO_valid
out out_lane_valid       1  [8] @ cpu.front.out.FIFO_valid && cpu.front.out.inst_valid[i0]
out out_instructions     32 [8] when out_valid @ cpu.front.out.instructions[i0]
out out_page_fault_inst  1  [8] when out_valid @ cpu.front.out.page_fault_inst[i0]
out out_predict_dir      1  [8] when out_valid @ cpu.front.out.predict_dir[i0]
out out_pc               32 [8] when out_valid @ cpu.front.out.pc[i0]
out out_alt_pred         1  [8] when out_valid @ cpu.front.out.alt_pred[i0]
out out_altpcpn          3  [8] when out_valid @ cpu.front.out.altpcpn[i0]
out out_pcpn             3  [8] when out_valid @ cpu.front.out.pcpn[i0]
out out_tage_idx         10 [8][4] when out_valid @ cpu.front.out.tage_idx[i0][i1]
out out_tage_tag         8  [8][4] when out_valid @ cpu.front.out.tage_tag[i0][i1]
out out_predict_next_fetch_address 32 when out_valid @ cpu.front.out.predict_next_fetch_address

# ---- memory side outputs (after the last icache call of the cycle) ----
out mem_req_valid       1  @ TTG_IC.mem_req_valid
out mem_req_addr        32 when mem_req_valid @ TTG_IC.mem_req_addr
out mem_req_total_size  8  when mem_req_valid @ TTG_IC.mem_req_total_size
out mem_req_bypass      1  when mem_req_valid @ TTG_IC.mem_req_bypass
out mem_req_id          4  when mem_req_valid @ TTG_IC.mem_req_id
out mem_resp_ready      1  @ TTG_IC.mem_resp_ready
out dc_req_valid        1  @ TTG_IC.dc_req_valid
out dc_req_addr         32 when dc_req_valid @ TTG_IC.dc_req_addr
out ptw_walk_req_valid     1  @ TTG_IC.ptw_req_valid
out ptw_walk_req_vpn       20 when ptw_walk_req_valid @ TTG_IC.ptw_req_vaddr >> 12
out ptw_walk_req_root_ppn  22 when ptw_walk_req_valid @ TTG_IC.ptw_req_satp & 0x3FFFFF
out ptw_walk_resp_consumed 1  @ TTG_IC.ptw_resp_consumed
out ptw_walk_flush         1  @ TTG_IC.ptw_flush
