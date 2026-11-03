# MemRouteBlock (MemSubSystem/MemRouteBlock.cpp), CPU-phase domain (tick 0 only).  Sits between the LSU / ICache / PTW and the DCache load port 3.
# Boundary = one record per CPU cycle, taken from the memcpu tap (TTG_MC.pub, docs/analysis/memcpu-record-hook.md); the record merges the two
# C++ calls of the cycle: comb_response (mem_subsystem.comb_outputs, BEFORE back.comb) and comb_request (comb_inputs, AFTER back.comb).
# Pass-through is part of the block (the C++ memcpy's the DCache response to the LSU and the LSU request to the DCache); only the fields with a
# consumer are kept (docs/modules/mem_route.md section 4).
# Dead in the default configuration and therefore NOT in the spec: PTW_DTLB / PTW_ITLB owners (ptw mem clients never request: 0 events in 68 programs),
# ptw_events.replay (constant 0), ptw_events.req_addr, per-port replay/bank_conflict flags on the LSU request side, LoadResp.retry for ports 0..2.
# Request/response ids: the route block owns the ids with bit 31 set; only the low 4 bits of its counter are kept (docs/modules/mem_route.md 4.3).
module mem_route

in  cpu_en                  1  @ 1

# ---- DCache response, published at tick 0 (route.in.dcache_resp = dcache_resp_route_) ----
in  dcache_resp_load_valid   1  [4] @ TTG_MC.pub.r_resp_in.resp_ports.load_resps[i0].valid
in  dcache_resp_load_req_id  32 [4] @ TTG_MC.pub.r_resp_in.resp_ports.load_resps[i0].req_id
in  dcache_resp_load_data    32 [4] @ TTG_MC.pub.r_resp_in.resp_ports.load_resps[i0].data
in  dcache_resp_load_replay  2  [4] @ (uint32_t)TTG_MC.pub.r_resp_in.resp_ports.load_resps[i0].replay
in  dcache_resp_load3_retry  1  @ TTG_MC.pub.r_resp_in.resp_ports.load_resps[3].retry
in  dcache_resp_store_valid  1  [4] @ TTG_MC.pub.r_resp_in.resp_ports.store_resps[i0].valid
in  dcache_resp_store_req_id 32 [4] @ TTG_MC.pub.r_resp_in.resp_ports.store_resps[i0].req_id
in  dcache_resp_store_replay 2  [4] @ (uint32_t)TTG_MC.pub.r_resp_in.resp_ports.store_resps[i0].replay
in  dcache_resp_mshr_fill    1  @ TTG_MC.pub.r_resp_in.mshr_fill
in  dcache_resp_mshr_fill_line 26 @ TTG_MC.pub.r_resp_in.mshr_fill_addr >> 6

# ---- LSU requests (route.in.lsu_req) ----
in  lsu_req_load_valid   1  [4] @ TTG_MC.pub.r_lsu_req.load_ports[i0].valid
in  lsu_req_load_addr    32 [4] @ TTG_MC.pub.r_lsu_req.load_ports[i0].addr
in  lsu_req_load_req_id  31 [4] @ TTG_MC.pub.r_lsu_req.load_ports[i0].req_id & 0x7fffffffu
in  lsu_req_store_valid  1  [4] @ TTG_MC.pub.r_lsu_req.store_ports[i0].valid
in  lsu_req_store_addr   32 [4] @ TTG_MC.pub.r_lsu_req.store_ports[i0].addr
in  lsu_req_store_data   32 [4] @ TTG_MC.pub.r_lsu_req.store_ports[i0].data
in  lsu_req_store_strb   5  [4] @ TTG_MC.pub.r_lsu_req.store_ports[i0].strb & 0x1f
in  lsu_req_store_req_id 6  [4] @ TTG_MC.pub.r_lsu_req.store_ports[i0].req_id

# ---- ICache and PTW (walk client) requests ----
in  icache_req_valid     1  @ TTG_MC.pub.r_icache_req.req_valid
in  icache_req_addr      32 @ TTG_MC.pub.r_icache_req.req_addr
in  ptw_walk_req_valid   1  @ TTG_MC.pub.r_walk_req.valid
in  ptw_walk_req_addr    32 @ TTG_MC.pub.r_walk_req.addr

# ---- response side outputs (comb_response) ----
out lsu_resp_load_valid   1  [4] @ TTG_MC.pub.r_lsu_resp.resp_ports.load_resps[i0].valid
out lsu_resp_load_req_id  32 [4] when lsu_resp_load_valid @ TTG_MC.pub.r_lsu_resp.resp_ports.load_resps[i0].req_id
out lsu_resp_load_data    32 [4] when lsu_resp_load_valid @ TTG_MC.pub.r_lsu_resp.resp_ports.load_resps[i0].data
out lsu_resp_load_replay  2  [4] when lsu_resp_load_valid @ (uint32_t)TTG_MC.pub.r_lsu_resp.resp_ports.load_resps[i0].replay
out lsu_resp_store_valid  1  [4] @ TTG_MC.pub.r_lsu_resp.resp_ports.store_resps[i0].valid
out lsu_resp_store_req_id 32 [4] when lsu_resp_store_valid @ TTG_MC.pub.r_lsu_resp.resp_ports.store_resps[i0].req_id
out lsu_resp_store_replay 2  [4] when lsu_resp_store_valid @ (uint32_t)TTG_MC.pub.r_lsu_resp.resp_ports.store_resps[i0].replay
out lsu_resp_mshr_fill    1  @ TTG_MC.pub.r_lsu_resp.mshr_fill
out lsu_resp_mshr_fill_line 26 when lsu_resp_mshr_fill @ TTG_MC.pub.r_lsu_resp.mshr_fill_addr >> 6
out icache_resp_valid     1  @ TTG_MC.pub.r_icache_resp.resp_valid
out icache_resp_retry     1  @ TTG_MC.pub.r_icache_resp.resp_retry
out icache_resp_miss      1  @ TTG_MC.pub.r_icache_resp.resp_miss
out icache_resp_data      32 @ TTG_MC.pub.r_icache_resp.resp_data
out ptw_event_valid       1  @ TTG_MC.pub.r_events.valid
out ptw_event_data        32 when ptw_event_valid @ TTG_MC.pub.r_events.data
out ptw_event_req_id      4  when ptw_event_valid @ TTG_MC.pub.r_events.req_id & 0xf
out ptw_wakeup_walk       1  @ TTG_MC.pub.r_wakeup.walk

# ---- request side outputs (comb_request) ----
out dcache_req_load_valid   1  [4] @ TTG_MC.pub.r_dcache_req.req_ports.load_ports[i0].valid
out dcache_req_load_addr    32 [4] when dcache_req_load_valid @ TTG_MC.pub.r_dcache_req.req_ports.load_ports[i0].addr
out dcache_req_load_req_id  32 [4] when dcache_req_load_valid @ ((TTG_MC.pub.r_dcache_req.req_ports.load_ports[i0].req_id >> 31) ? (TTG_MC.pub.r_dcache_req.req_ports.load_ports[i0].req_id & 0x8000000fu) : TTG_MC.pub.r_dcache_req.req_ports.load_ports[i0].req_id)
out dcache_req_store_valid  1  [4] @ TTG_MC.pub.r_dcache_req.req_ports.store_ports[i0].valid
out dcache_req_store_addr   32 [4] when dcache_req_store_valid @ TTG_MC.pub.r_dcache_req.req_ports.store_ports[i0].addr
out dcache_req_store_data   32 [4] when dcache_req_store_valid @ TTG_MC.pub.r_dcache_req.req_ports.store_ports[i0].data
out dcache_req_store_strb   5  [4] when dcache_req_store_valid @ TTG_MC.pub.r_dcache_req.req_ports.store_ports[i0].strb & 0x1f
out dcache_req_store_req_id 6  [4] when dcache_req_store_valid @ TTG_MC.pub.r_dcache_req.req_ports.store_ports[i0].req_id
out dcache_req_icache_probe 1  @ TTG_MC.pub.r_dcache_req.icache_req == 3
out ptw_grant_valid         1  @ TTG_MC.pub.r_grant.valid
out ptw_grant_req_id        4  when ptw_grant_valid @ TTG_MC.pub.r_grant.req_id & 0xf
