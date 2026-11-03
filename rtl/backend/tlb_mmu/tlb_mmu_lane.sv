// Ref: back-end/Lsu/TlbMmu.cpp  TlbMmu::core_comb (one port of top_comb)
`default_nettype none

// One translation port. It sees the state left by the lower-numbered ports (the walk, this cycle's refill, whether
// the PTW request slot
// and the PTW response are still available) and hands the updated state to the next one.
//   bare mode            -> HIT, paddr = vaddr
//   refill / table hit   -> permission check -> HIT or FAULT
//   miss                 -> walk state machine: start / wait / request / consume the response
module tlb_mmu_lane import tlb_mmu_pkg::*; #(
  parameter logic [1:0] ACCESS_TYPE = ACC_LOAD
) (
  input  logic                valid,
  input  logic [31:0]         vaddr,
  // translation context (shared by all ports of the cycle)
  input  logic [31:0]         satp,
  input  logic [1:0]          privilege,
  input  logic                mxr,
  input  logic                sum,
  input  logic                mprv,
  input  logic [1:0]          mpp,
  // table lookup of this port
  input  logic                table_hit,
  input  tlb_mmu_xlat_t       table_xlat,
  // PTW response payload (valid bit travels in chain_in)
  input  logic                ptw_req_ready,
  input  tlb_mmu_ptw_resp_t   ptw_resp,
  input  tlb_mmu_chain_t      chain_in,
  output tlb_mmu_chain_t      chain_out,
  output logic                req_issued,    // this port sent the PTW walk request
  output logic                resp_consumed, // this port consumed the PTW walk response
  output logic [1:0]          result,
  output logic [31:0]         paddr
);

  logic [1:0]       eff_priv;
  logic             bare;
  logic [VPN_W-1:0] vpn;
  logic [ASID_W-1:0] asid;
  // hit path
  logic             refill_match, hit;
  tlb_mmu_xlat_t    hit_xlat;
  logic             hit_perm_ok;
  // walk path
  tlb_mmu_walk_t    walk_cur;
  logic             other_walk;
  logic             resp_for_walk;
  logic             resp_perm_ok;
  tlb_mmu_entry_t   new_refill;
  tlb_mmu_xlat_t    new_xlat;

  always_comb begin
    eff_priv = effective_priv(ACCESS_TYPE, privilege, mprv, mpp);
    bare = eff_priv == 2'd3 || !satp[31];
    vpn = vaddr[31:12];
    asid = satp[30:22];
    refill_match = chain_in.refill_valid && tag_match(chain_in.refill.tag, vpn, asid);
    hit = refill_match || table_hit;
    hit_xlat = refill_match ? chain_in.refill.xlat : table_xlat;
    hit_perm_ok = perm_ok(hit_xlat.perm, ACCESS_TYPE, eff_priv, sum, mxr);
  end

  // a port that misses either starts the walk (register idle) or must belong to the walk already in flight
  always_comb begin
    walk_cur = chain_in.walk;
    if (!chain_in.walk.active) begin
      walk_cur = '{active: 1'b1, req_sent: 1'b0, vpn: vpn, access_type: ACCESS_TYPE, satp: satp, eff_priv: eff_priv,
                   mxr: mxr, sum: sum};
    end
    other_walk = chain_in.walk.active && (chain_in.walk.vpn != vpn || chain_in.walk.satp != satp);
    resp_for_walk = ptw_resp.vpn == vpn;
    resp_perm_ok = perm_ok(ptw_resp.perm, ACCESS_TYPE, eff_priv, sum, mxr);
    new_xlat = '{level: ptw_resp.level, ppn: ptw_resp.ppn, perm: ptw_resp.perm};
    new_refill.tag = '{global_page: ptw_resp.perm[PERM_G], asid: asid, level: ptw_resp.level,
                       vpn1: vpn[VPN_W-1:VPN_PART_W], vpn0: vpn[VPN_PART_W-1:0]};
    new_refill.xlat = new_xlat;
  end

  // walk state machine step of a port that missed (Ref: TlbMmu::core_comb after the lookup)
  tlb_mmu_chain_t walk_chain;
  logic           walk_req_issued, walk_resp_consumed;
  logic [1:0]     walk_result;
  logic [31:0]    walk_paddr;

  always_comb begin
    walk_chain = chain_in;
    walk_req_issued = 1'b0;
    walk_resp_consumed = 1'b0;
    walk_result = RES_MISS;
    walk_paddr = '0;
    if (!other_walk) begin
      walk_chain.walk = walk_cur;
      if (!walk_cur.req_sent) begin
        if (ptw_req_ready) begin
          walk_req_issued = 1'b1;
          walk_chain.walk.req_sent = 1'b1;
          walk_chain.resp_valid = 1'b0;
        end
      end else if (chain_in.resp_valid) begin
        walk_resp_consumed = 1'b1;
        walk_chain.resp_valid = 1'b0;
        if (resp_for_walk) begin
          walk_chain.walk = '0;
          if (ptw_resp.fault || !resp_perm_ok) begin
            walk_result = RES_FAULT;
          end else begin
            walk_result = RES_HIT;
            walk_paddr = compose_paddr(vaddr[21:0], new_xlat.level, new_xlat.ppn);
            walk_chain.refill_valid = 1'b1;
            walk_chain.refill = new_refill;
          end
        end
      end
    end
  end

  // Ref: TlbMmu::core_comb (port result: invalid / bare / hit / walk)
  always_comb begin
    chain_out = chain_in;
    req_issued = 1'b0;
    resp_consumed = 1'b0;
    result = RES_MISS;
    paddr = '0;
    if (valid && bare) begin
      result = RES_HIT;
      paddr = vaddr;
    end else if (valid && hit) begin
      result = hit_perm_ok ? RES_HIT : RES_FAULT;
      paddr = compose_paddr(vaddr[21:0], hit_xlat.level, hit_xlat.ppn);
    end else if (valid) begin
      chain_out = walk_chain;
      req_issued = walk_req_issued;
      resp_consumed = walk_resp_consumed;
      result = walk_result;
      paddr = walk_paddr;
    end
  end

endmodule

`default_nettype wire
