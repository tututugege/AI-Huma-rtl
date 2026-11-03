# MemPtwBlock (MemSubSystem/include/MemPtwBlock.h), the LIVE part only: the two page-table-walk clients (DTLB, ITLB via PtwWalkPort) sharing one walker,
# CPU-phase domain (tick 0 only).  Boundary = one record per CPU cycle from the memcpu tap (TTG_MC.pub).
# Inputs are the values comb_begin latches (client ports), comb_finish applies (grant / event / wakeup from MemRouteBlock) and seq applies (walk_client_flush).
# Outputs: the state-only values the TLBs read at the START of the cycle (p_view = comb_outputs() before comb_begin) and the walk read request the route block
# sees (issue_walk_read/walk_read_addr after comb_begin: same-cycle select -> issue combinational path).
# Dead / removed (docs/modules/ptw_walk.md section 4): mem clients (PtwMemPort path: 0 requests in 68 programs), PtwWalker/PtwCompactCoreKernel, RoutedEvent.replay path,
# walk_drop_resp_credit (write-only: DROPPED and IGNORED are the same observable behaviour), access_type, resp.vaddr[11:0], satp/PTE bits above ppn[19:0] (shifted out of a 32-bit address).
module ptw_walk

in  cpu_en                    1  @ 1
in  client_req_valid          1  [2] @ TTG_MC.pub.p_in.walk_clients[i0].req_valid
in  client_req_vpn            20 [2] @ (TTG_MC.pub.p_in.walk_clients[i0].req.vaddr >> 12) & 0xFFFFF
in  client_req_root_ppn       22 [2] @ TTG_MC.pub.p_in.walk_clients[i0].req.satp & 0x3FFFFF
in  client_resp_consumed      1  [2] @ TTG_MC.pub.p_in.walk_clients[i0].resp_consumed
in  client_flush              1  [2] @ TTG_MC.pub.p_flush[i0]
in  grant_valid               1  @ TTG_MC.pub.p_fb.grant_valid && TTG_MC.pub.p_fb.grant_owner == MemPtwBlock::GrantOwner::WALK
in  grant_req_id              4  @ TTG_MC.pub.p_fb.grant_req_id & 0xf
in  event_valid               1  @ TTG_MC.pub.p_fb.event_count != 0 && TTG_MC.pub.p_fb.events[0].valid && TTG_MC.pub.p_fb.events[0].owner == MemPtwBlock::RoutedEventOwner::WALK
in  event_data                32 @ TTG_MC.pub.p_fb.events[0].data
in  event_req_id              4  @ TTG_MC.pub.p_fb.events[0].req_id & 0xf
in  wakeup_walk               1  @ TTG_MC.pub.p_fb.wakeup_walk

out client_req_ready          1  [2] @ TTG_MC.pub.p_view.walk_clients[i0].req_ready
out client_resp_valid         1  [2] @ TTG_MC.pub.p_view.walk_clients[i0].resp_valid
out client_resp_fault         1  [2] when client_resp_valid @ TTG_MC.pub.p_view.walk_clients[i0].resp.fault
out client_resp_vpn           20 [2] when client_resp_valid @ (TTG_MC.pub.p_view.walk_clients[i0].resp.vaddr >> 12) & 0xFFFFF
out client_resp_leaf_ppn      20 [2] when client_resp_valid @ (TTG_MC.pub.p_view.walk_clients[i0].resp.leaf_pte >> 10) & 0xFFFFF
out client_resp_leaf_perm     8  [2] when client_resp_valid @ TTG_MC.pub.p_view.walk_clients[i0].resp.leaf_pte & 0xFF
out client_resp_leaf_level    1  [2] when client_resp_valid @ TTG_MC.pub.p_view.walk_clients[i0].resp.leaf_level & 1
out issue_walk_read           1  @ TTG_MC.pub.p_issue
out walk_read_addr            32 when issue_walk_read @ TTG_MC.pub.p_addr
