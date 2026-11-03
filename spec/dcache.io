# DCache domain (RealDcache + MSHR + WriteBuffer + response latch/forward), default config. See docs/modules/dcache.md.
# One record = one FAST TICK (16 per CPU cycle). Inputs/outputs are the values recorded by the memsys tap (TTG_MS, docs/analysis/memsys-record-hook.md):
#   request actually presented to the DCache this tick (empty on ticks 1..15), MSHR/WB AXI inputs at dcache_domain_comb_outputs entry,
#   MSHR/WB AXI outputs after dcache_domain_comb_inputs, published response (tick 0 only).  Needs lockstep_ticks.sh (16 ticks per cycle).
# Not in the spec: perf/lsu_origin/replay(req) fields, MshrAxiIn.req_ready and WbAxiIn.req_ready (never read), LoadResp/StoreResp.bank_conflict (never read),
#   constant AXI fields (mshr req_total_size=63, wb req_total_size=63 / req_id=0 / req_wstrb=all ones / resp_ready=1: tie off at integration).
module dcache

# cpu_phase0: tick 0 of the CPU cycle (response published, pending latch cleared at the end of the tick)
in  cpu_phase0  1 @ TTG_MS.cur == 0

# ---- routed LSU request (tick 0 only; empty otherwise) ----
in  ld_req_valid 1 [4] @ TTG_MS.t[TTG_MS.cur].req.req_ports.load_ports[i0].valid
in  ld_req_addr 32 [4] @ TTG_MS.t[TTG_MS.cur].req.req_ports.load_ports[i0].addr
in  ld_req_id 32 [4] @ TTG_MS.t[TTG_MS.cur].req.req_ports.load_ports[i0].req_id
in  st_req_valid 1 [4] @ TTG_MS.t[TTG_MS.cur].req.req_ports.store_ports[i0].valid
in  st_req_addr 32 [4] @ TTG_MS.t[TTG_MS.cur].req.req_ports.store_ports[i0].addr
in  st_req_data 32 [4] @ TTG_MS.t[TTG_MS.cur].req.req_ports.store_ports[i0].data
in  st_req_strb 4 [4] @ TTG_MS.t[TTG_MS.cur].req.req_ports.store_ports[i0].strb & 0xF
in  st_req_id 32 [4] @ TTG_MS.t[TTG_MS.cur].req.req_ports.store_ports[i0].req_id
in  icache_req 3 @ TTG_MS.t[TTG_MS.cur].req.icache_req

# ---- AXI read master (MSHR) / write master (WriteBuffer) inputs ----
in  mshr_req_accepted 1 @ TTG_MS.t[TTG_MS.cur].mshr_in.req_accepted
in  mshr_req_accepted_id 8 @ TTG_MS.t[TTG_MS.cur].mshr_in.req_accepted_id
in  mshr_resp_valid 1 @ TTG_MS.t[TTG_MS.cur].mshr_in.resp_valid
in  mshr_resp_id 8 @ TTG_MS.t[TTG_MS.cur].mshr_in.resp_id
in  mshr_resp_data 32 [16] @ TTG_MS.t[TTG_MS.cur].mshr_in.resp_data[i0]
in  wb_req_accepted 1 @ TTG_MS.t[TTG_MS.cur].wb_in.req_accepted
in  wb_resp_valid 1 @ TTG_MS.t[TTG_MS.cur].wb_in.resp_valid

# ---- published response (valid only on tick 0; payload relaxed to valid slots, consumers: RealLsu.cpp:725-830, MemRouteBlock.cpp:30-90) ----
out ld_resp_valid 1 [4] @ TTG_MS.t[TTG_MS.cur].resp_pub.resp_ports.load_resps[i0].valid
out ld_resp_data 32 [4] when ld_resp_valid @ TTG_MS.t[TTG_MS.cur].resp_pub.resp_ports.load_resps[i0].data
out ld_resp_id 32 [4] when ld_resp_valid @ TTG_MS.t[TTG_MS.cur].resp_pub.resp_ports.load_resps[i0].req_id
out ld_resp_retry 1 [4] when ld_resp_valid @ TTG_MS.t[TTG_MS.cur].resp_pub.resp_ports.load_resps[i0].retry
out ld_resp_replay 2 [4] when ld_resp_valid @ (int)TTG_MS.t[TTG_MS.cur].resp_pub.resp_ports.load_resps[i0].replay
out st_resp_valid 1 [4] @ TTG_MS.t[TTG_MS.cur].resp_pub.resp_ports.store_resps[i0].valid
out st_resp_replay 2 [4] when st_resp_valid @ (int)TTG_MS.t[TTG_MS.cur].resp_pub.resp_ports.store_resps[i0].replay
out st_resp_id 32 [4] when st_resp_valid @ TTG_MS.t[TTG_MS.cur].resp_pub.resp_ports.store_resps[i0].req_id
out mshr_fill 1 @ TTG_MS.t[TTG_MS.cur].resp_pub.mshr_fill
out mshr_fill_addr 32 when mshr_fill @ TTG_MS.t[TTG_MS.cur].resp_pub.mshr_fill_addr

# ---- AXI outputs after the full tick ----
out mshr_req_valid 1 @ TTG_MS.t[TTG_MS.cur].mshr_out.req_valid
out mshr_req_addr 32 when mshr_req_valid @ TTG_MS.t[TTG_MS.cur].mshr_out.req_addr
out mshr_req_id 3 when mshr_req_valid @ TTG_MS.t[TTG_MS.cur].mshr_out.req_id
out mshr_resp_ready 1 @ TTG_MS.t[TTG_MS.cur].mshr_out.resp_ready
out wb_req_valid 1 @ TTG_MS.t[TTG_MS.cur].wb_out.req_valid
out wb_req_addr 32 when wb_req_valid @ TTG_MS.t[TTG_MS.cur].wb_out.req_addr
out wb_req_data 32 [16] when wb_req_valid @ TTG_MS.t[TTG_MS.cur].wb_out.req_wdata[i0]
