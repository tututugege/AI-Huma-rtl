// Ref: back-end/Lsu/TlbMmu.cpp  class TlbMmu (types, check_perm, compose_paddr, entry_matches)
`default_nettype none
package tlb_mmu_pkg;
  import ttg_cfg_pkg::*;
  /* verilator lint_off UNUSEDPARAM */  // constants: not every constant is used by every module

  // Sv39: 3 levels of 9-bit VPNs, 16-bit ASID satp[59:44].
  // Physical address is 32 bits in both: only ppn[19:0] of a PTE reaches it.
  localparam bit RV64 = (XLEN_BITS == 64);
  localparam int ASID_W = RV64 ? 16 : 9;
  localparam int LEVELS = RV64 ? 3 : 2;
  localparam int VPN_PART_W = RV64 ? 9 : 10;   // one VPN field
  localparam int VPN_W = LEVELS * VPN_PART_W;  // vaddr[12 +: VPN_W]
  localparam int LVL_W = RV64 ? 2 : 1;         // leaf level: 0 = 4 KiB, 1 = 2/4 MiB, 2 = 1 GiB (Sv39)
  localparam int VLOW_W = 12 + VPN_PART_W * (LEVELS - 1);   // vaddr bits a leaf of the top level keeps (22 / 30)
  localparam int PPN_W = 20;
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
  /* verilator lint_on UNUSEDPARAM */

  // what identifies a page (match key)
  typedef struct packed {
    logic                  global_page;
    logic [ASID_W-1:0]     asid;
    logic [LVL_W-1:0]      level;      // leaf level of the page
    logic [VPN_W-1:0]      vpn;        // the VPN fields below `level` are don't care
  } tlb_mmu_tag_t;

  // what a matched entry translates to
  typedef struct packed {
    logic [LVL_W-1:0]  level;
    logic [PPN_W-1:0]  ppn;
    logic [PPN_W-1:0]  ppn_p1;
    logic [PPN_W-1:0]  ppn_m1;
    logic [PERM_W-1:0] perm;
  } tlb_mmu_xlat_t;

  // Build xlat payload at refill time with precomputed ppn +/- 1 at the leaf's page granularity
  function automatic tlb_mmu_xlat_t mk_xlat(input logic [LVL_W-1:0] level,
                                            input logic [PPN_W-1:0] ppn,
                                            input logic [PERM_W-1:0] perm);
    tlb_mmu_xlat_t x;
    x.level  = level;
    x.ppn    = ppn;
    x.perm   = perm;
    x.ppn_p1 = ppn + PPN_W'(1);
    x.ppn_m1 = ppn - PPN_W'(1);
    if (RV64) begin
      if (level == LVL_W'(1)) begin
        x.ppn_p1 = {ppn[19:9] + 11'd1, 9'd0};
        x.ppn_m1 = {ppn[19:9] - 11'd1, 9'd0};
      end else if (level == LVL_W'(2)) begin
        x.ppn_p1 = {ppn[19:18] + 2'd1, 18'd0};
        x.ppn_m1 = {ppn[19:18] - 2'd1, 18'd0};
      end
    end else begin
      if (level == LVL_W'(1)) begin
        x.ppn_p1 = {ppn[19:10] + 10'd1, 10'd0};
        x.ppn_m1 = {ppn[19:10] - 10'd1, 10'd0};
      end
    end
    return x;
  endfunction

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
    logic [LVL_W-1:0] level;
    logic [PPN_W-1:0] ppn;
    logic [PERM_W-1:0] perm;
  } tlb_mmu_ptw_resp_t;

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
  // every VPN field at or above the leaf's level must match (a superpage ignores the lower ones)
  function automatic logic tag_match(input tlb_mmu_tag_t t, input logic [VPN_W-1:0] vpn,
                                     input logic [ASID_W-1:0] asid);
    logic m;
    m = t.global_page || t.asid == asid;
    for (int k = 0; k < LEVELS; k++)
      if (k >= int'(t.level) && t.vpn[k*VPN_PART_W +: VPN_PART_W] != vpn[k*VPN_PART_W +: VPN_PART_W]) m = 1'b0;
    return m;
  endfunction

  // 32-bit physical address: the offset below a leaf of level L is 12 + VPN_PART_W * L bits, from the virtual address
  function automatic logic [31:0] compose_paddr(input logic [VLOW_W-1:0] vaddr_low, input logic [LVL_W-1:0] level,
                                                input logic [PPN_W-1:0] ppn);
    logic [31:0] r, pbase;
    pbase = {ppn, 12'b0};
    for (int i = 0; i < 32; i++) begin
      if (i < VLOW_W && i < 12 + VPN_PART_W * int'(level)) r[i] = vaddr_low[i];
      else                                                 r[i] = pbase[i];
    end
    return r;
  endfunction

  // Compose paddr[31:3] +/- 1 without any post-CAM adder using precomputed ppn_adj and parallel va_adj/carry flags
  function automatic logic [28:0] compose_paddr_adj(
    input logic [26:0]      va_adj,
    input logic [LVL_W-1:0] level,
    input logic [PPN_W-1:0] ppn,
    input logic [PPN_W-1:0] ppn_adj,
    input logic c0, input logic c1, input logic c2
  );
    if (RV64) begin
      case (level)
        LVL_W'(1): return {c1 ? ppn_adj[19:9]  : ppn[19:9],  va_adj[17:0]};
        LVL_W'(2): return {c2 ? ppn_adj[19:18] : ppn[19:18], va_adj[26:0]};
        default:   return {c0 ? ppn_adj[19:0]  : ppn[19:0],  va_adj[8:0]};
      endcase
    end else begin
      if (level == LVL_W'(1)) return {c1 ? ppn_adj[19:10] : ppn[19:10], va_adj[18:0]};
      else                    return {c0 ? ppn_adj[19:0]  : ppn[19:0],  va_adj[8:0]};
    end
  endfunction

  // satp: translation enabled (Sv39: MODE = 8) and ASID
  function automatic logic satp_on(input logic [XLEN_BITS-1:0] satp);
    return RV64 ? (satp[XLEN_BITS-1 -: 4] == 4'd8) : satp[XLEN_BITS-1];
  endfunction

  function automatic logic [ASID_W-1:0] satp_asid(input logic [XLEN_BITS-1:0] satp);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] s;
    /* verilator lint_on UNUSEDSIGNAL */
    s = 64'(satp);
    return RV64 ? s[44 +: ASID_W] : s[22 +: ASID_W];
  endfunction

  // Sv39: a virtual address must be sign-extended from bit 38
  function automatic logic va_canonical(input logic [XLEN_BITS-1:0] v);
    logic signed [XLEN_BITS-1:0] top;
    top = $signed(v) >>> 38;
    return top == '0 || top == '1;
  endfunction

  function automatic logic [1:0] effective_priv(input logic [1:0] access_type, input logic [1:0] privilege,
                                                input logic mprv, input logic [1:0] mpp);
    return (access_type != ACC_FETCH && mprv) ? mpp : privilege;
  endfunction

endpackage
`default_nettype wire
