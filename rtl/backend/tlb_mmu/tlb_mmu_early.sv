// Ref: back-end/Lsu/TlbMmu.cpp  TlbMmu::consume_completed_walk_refill
`default_nettype none

// A walk whose PTW response has arrived is retired before any request is looked at: judged with the permissions
// saved in the walk
// register (not the requesting port's), it becomes a refill of this cycle. The caller decides whether a faulting /
// permission-failing
// response is consumed too (cancel) or left for a requesting port to turn into a FAULT (translate).
module tlb_mmu_early import tlb_mmu_pkg::*; (
  input  tlb_mmu_walk_t       walk,
  input  logic                resp_valid,
  input  tlb_mmu_ptw_resp_t   resp,
  output logic                done,          // walk active, request sent, response for the walk's page is present
  output logic                refill_ok,     // done and the response is a usable translation
  output tlb_mmu_entry_t      refill
);

  logic perm_pass;

  always_comb begin
    done = walk.active && walk.req_sent && resp_valid && resp.vpn == walk.vpn;
    perm_pass = perm_ok(resp.perm, walk.access_type, walk.eff_priv, walk.sum, walk.mxr);
    refill_ok = done && !resp.fault && perm_pass;
    refill.tag.global_page = resp.perm[PERM_G];
    refill.tag.asid = walk.satp[30:22];
    refill.tag.level = resp.level;
    refill.tag.vpn1 = walk.vpn[VPN_W-1:VPN_PART_W];
    refill.tag.vpn0 = walk.vpn[VPN_PART_W-1:0];
    refill.xlat = '{level: resp.level, ppn: resp.ppn, perm: resp.perm};
  end

endmodule

`default_nettype wire
