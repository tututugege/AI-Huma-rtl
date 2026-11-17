// Ref: back-end/Lsu/TlbMmu.cpp  TlbMmu::core_comb (one port of top_comb)
`default_nettype none

// One translation port, evaluated in parallel with the others. The port-to-port dependence of the reference (each
// port sees the walk / refill / PTW response left by the lower-numbered ports) is resolved in tlb_mmu_core by two
// find-first picks; this module only computes what the port can know on its own, for both refill views it may see:
//   view 0: the refill of the cycle start (early-retired walk)
//   view 1: the refill made by the port that retires the in-flight walk this cycle (PTW response payload)
// and then forms its result from the core's picks.
//   bare mode            -> HIT, paddr = vaddr
//   refill / table hit   -> permission check -> HIT or FAULT
//   miss                 -> MISS, or HIT/FAULT if this port retires the in-flight walk
module tlb_mmu_lane import tlb_mmu_pkg::*; import ttg_cfg_pkg::*; (
  input  logic                valid,
  input  logic [1:0]          access_type,   // ACC_LOAD / ACC_STORE (a shared AGU port serves both) / ACC_FETCH
  input  logic [XLEN_BITS-1:0] vaddr,
  // translation context (shared by all ports of the cycle)
  input  logic [XLEN_BITS-1:0] satp,
  input  logic [1:0]          privilege,
  input  logic                mxr,
  input  logic                sum,
  input  logic                mprv,
  input  logic [1:0]          mpp,
  // table lookup of this port
  input  logic                table_hit,
  input  tlb_mmu_xlat_t       table_xlat,
  // the two refill views
  input  logic                refill0_valid,
  input  tlb_mmu_entry_t      refill0,
  input  tlb_mmu_entry_t      refill1,
  // walk register at the cycle start (page and satp) and the PTW response payload
  input  logic [VPN_W-1:0]    walk_vpn,
  input  logic [XLEN_BITS-1:0] walk_satp,
  input  logic                ptw_resp_fault,
  input  logic [LVL_W-1:0]    ptw_resp_level,
  input  logic [PPN_W-1:0]    ptw_resp_ppn,
  input  logic [PERM_W-1:0]   ptw_resp_perm,
  // ---- port-local facts (to the core) ----
  output logic                miss0,         // needs the walk, seeing refill view 0
  output logic                miss1,         // needs the walk, seeing refill view 1
  output logic                walk_same,     // the in-flight walk is for this port's page (same vpn and satp)
  output logic                resp_perm_ok,  // the PTW response passes this port's permission check
  output tlb_mmu_walk_t       walk_new,      // walk register this port would start
  // ---- picks (from the core) ----
  input  logic                use_refill1,   // a lower port retired the walk with a refill: see view 1
  input  logic                retire,        // this port consumes the response of its walk
  output logic [1:0]          result,
  output logic [31:0]         paddr
);

  logic [1:0]        eff_priv;
  logic              bare, noncanon, live;
  logic [VPN_W-1:0]  vpn;
  logic [ASID_W-1:0] asid;
  logic              rm0, rm1;

  always_comb begin
    eff_priv = effective_priv(access_type, privilege, mprv, mpp);
    bare = eff_priv == 2'd3 || !satp_on(satp);
    vpn = vaddr[12 +: VPN_W];
    asid = satp_asid(satp);
    noncanon = !va_canonical(vaddr);
    live = valid && !bare && !noncanon;
    rm0 = refill0_valid && tag_match(refill0.tag, vpn, asid);
    rm1 = tag_match(refill1.tag, vpn, asid);
    miss0 = live && !rm0 && !table_hit;
    miss1 = live && !rm1 && !table_hit;
    walk_same = walk_vpn == vpn && walk_satp == satp;
    resp_perm_ok = perm_ok(ptw_resp_perm, access_type, eff_priv, sum, mxr);
    walk_new = '{active: 1'b1, req_sent: 1'b0, vpn: vpn, access_type: access_type, satp: satp, eff_priv: eff_priv,
                 mxr: mxr, sum: sum};
  end

  // Ref: TlbMmu::core_comb (port result: invalid / bare / hit / walk), formed for each view before the picks arrive
  function automatic void port_result(input logic refill_match, input tlb_mmu_xlat_t refill_xlat,
                                      output logic [1:0] r, output logic [31:0] pa);
    tlb_mmu_xlat_t x;
    x = refill_match ? refill_xlat : table_xlat;
    r = RES_MISS;
    pa = '0;
    if (valid && bare) begin
      r = RES_HIT;
      // untranslated: above the 32-bit physical space an address maps to one outside RAM (as in the model)
      pa = (RV64 && (64'(vaddr) >> 32) != 64'd0) ? 32'h7fffffff : vaddr[31:0];
    end else if (valid && noncanon) begin
      r = RES_FAULT;   // Sv39: a non-canonical address is a page fault
    end else if (valid && (refill_match || table_hit)) begin
      r = perm_ok(x.perm, access_type, eff_priv, sum, mxr) ? RES_HIT : RES_FAULT;
      pa = compose_paddr(vaddr[VLOW_W-1:0], x.level, x.ppn);
    end
  endfunction

  logic [1:0]  result0, result1, result_ret;
  logic [31:0] paddr0, paddr1, paddr_ret;
  always_comb begin
    port_result(rm0, refill0.xlat, result0, paddr0);
    port_result(rm1, refill1.xlat, result1, paddr1);
    // retiring port: it missed (view 0), so the PTW response decides
    if (ptw_resp_fault || !resp_perm_ok) begin
      result_ret = RES_FAULT;
      paddr_ret = '0;
    end else begin
      result_ret = RES_HIT;
      paddr_ret = compose_paddr(vaddr[VLOW_W-1:0], ptw_resp_level, ptw_resp_ppn);
    end
    // the picks only steer the last mux
    if (use_refill1) begin
      result = result1;
      paddr = paddr1;
    end else if (retire) begin
      result = result_ret;
      paddr = paddr_ret;
    end else begin
      result = result0;
      paddr = paddr0;
    end
  end

endmodule

`default_nettype wire
