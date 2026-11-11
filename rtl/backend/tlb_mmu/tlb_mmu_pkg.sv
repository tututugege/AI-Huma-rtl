// Ref: back-end/Lsu/TlbMmu.cpp  class TlbMmu (types, check_perm, compose_paddr, entry_matches)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */  // constants package: not every constant is used by every module
package tlb_mmu_pkg;
  import ttg_cfg_pkg::*;

  localparam int ASID_W = 9;           // Sv32 satp[30:22]
  localparam int VPN_W = 20;           // vaddr[31:12]
  localparam int VPN_PART_W = 10;      // vpn1 / vpn0
  localparam int PPN_W = 20;           // ppn[19:0]: ppn[21:20] never reach the 32-bit physical address
  localparam int PERM_W = 8;           // PTE[7:0] = D A G U X W R V
  localparam int PERM_R = 1;
  localparam int PERM_W_BIT = 2;
  localparam int PERM_X = 3;
  localparam int PERM_U = 4;
  localparam int PERM_G = 5;
  localparam int PERM_A = 6;
  localparam int PERM_D = 7;

  // response codes towards the LSU (MMUResultType)
  localparam logic [1:0] RES_MISS = 2'd0;
  localparam logic [1:0] RES_HIT = 2'd1;
  localparam logic [1:0] RES_FAULT = 2'd2;

  localparam logic [1:0] ACC_FETCH = 2'd0;
  localparam logic [1:0] ACC_LOAD = 2'd1;
  localparam logic [1:0] ACC_STORE = 2'd2;

  // what identifies a page (match key)
  typedef struct packed {
    logic                  global_page;
    logic [ASID_W-1:0]     asid;
    logic                  level;      // 1: megapage (L1 leaf), 0: 4 KiB page
    logic [VPN_PART_W-1:0] vpn1;
    logic [VPN_PART_W-1:0] vpn0;       // don't care when level == 1
  } tlb_mmu_tag_t;

  // what a matched entry translates to
  typedef struct packed {
    logic              level;
    logic [PPN_W-1:0]  ppn;
    logic [PERM_W-1:0] perm;
  } tlb_mmu_xlat_t;

  // one TLB entry (the valid bit lives in the TLB array, not in the entry)
  typedef struct packed {
    tlb_mmu_tag_t  tag;
    tlb_mmu_xlat_t xlat;
  } tlb_mmu_entry_t;

  // the single in-flight page walk (WalkRegs)
  typedef struct packed {
    logic             active;
    logic             req_sent;
    logic [VPN_W-1:0] vpn;
    logic [1:0]       access_type;
    logic [XLEN_BITS-1:0]      satp;
    logic [1:0]       eff_priv;
    logic             mxr;
    logic             sum;
  } tlb_mmu_walk_t;

  // PTW walk response as seen by the TLB (PtwWalkResp, only the consumed fields)
  typedef struct packed {
    logic             fault;
    logic [VPN_W-1:0] vpn;
    logic             level;
    logic [PPN_W-1:0] ppn;
    logic [PERM_W-1:0] perm;
  } tlb_mmu_ptw_resp_t;

  // state handed from one lane to the next (top_comb shadow_*): the walk, the refill of this cycle, and whether the PTW
  // response is still unconsumed (the request slot needs no shadow: once a port has sent a request the walk is active
  // with req_sent set and the response is hidden, so no later port can start a second request)
  typedef struct packed {
    tlb_mmu_walk_t  walk;
    logic           refill_valid;
    tlb_mmu_entry_t refill;
    logic           resp_valid;
  } tlb_mmu_chain_t;

  // Ref: TlbMmu::check_perm
  function automatic logic perm_ok(input logic [PERM_W-1:0] perm, input logic [1:0] access_type,
                                   input logic [1:0] eff_priv, input logic sum, input logic mxr);
    logic r, w, x, u, a, d, fail;
    r = perm[PERM_R];
    w = perm[PERM_W_BIT];
    x = perm[PERM_X];
    u = perm[PERM_U];
    a = perm[PERM_A];
    d = perm[PERM_D];
    fail = (access_type == ACC_FETCH && !x)
         || (access_type == ACC_LOAD && !r && !(mxr && x))
         || (access_type == ACC_STORE && !w)
         || (eff_priv == 2'd0 && !u)
         || (eff_priv == 2'd1 && u && (access_type == ACC_FETCH || !sum))
         || !a
         || (access_type == ACC_STORE && !d);
    return !fail;
  endfunction

  // Ref: TlbMmu::entry_matches (without the valid bit)
  function automatic logic tag_match(input tlb_mmu_tag_t t, input logic [VPN_W-1:0] vpn, input logic [ASID_W-1:0] asid);
    return (t.global_page || t.asid == asid) && t.vpn1 == vpn[VPN_W-1:VPN_PART_W]
        && (t.level || t.vpn0 == vpn[VPN_PART_W-1:0]);
  endfunction

  // Ref: TlbMmu::compose_paddr (32-bit physical address; a megapage keeps vaddr[21:0])
  function automatic logic [31:0] compose_paddr(input logic [21:0] vaddr_low, input logic level,
                                                input logic [PPN_W-1:0] ppn);
    return level ? {ppn[PPN_W-1:VPN_PART_W], vaddr_low} : {ppn, vaddr_low[11:0]};
  endfunction

  // Ref: TlbMmu::build_translate_context (eff_priv): loads/stores honour MSTATUS.MPRV, fetches do not
  function automatic logic [1:0] effective_priv(input logic [1:0] access_type, input logic [1:0] privilege,
                                                input logic mprv, input logic [1:0] mpp);
    return (access_type != ACC_FETCH && mprv) ? mpp : privilege;
  endfunction

endpackage
`default_nettype wire
