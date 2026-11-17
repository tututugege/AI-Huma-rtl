// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (comb_exe2lsu_p slot compaction, comb_tlb_out_p, comb_tlb_in_ldq_p / co
`default_nettype none

// L1 slot formation of the staged LSU: the accepted AGU loads are compacted into the first load slots, the replay
// registers fill the next free slots (a register is consumed whenever a slot is free); the same for the STA slots
// and the STA replay register.  Produces the DTLB requests and decodes the DTLB responses of the slots.
module lp_l1
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  // new arrivals
  input  lp_agu_ld_t          ag [NLD],
  input  logic [NLD-1:0]      ag_acc,
  input  lp_agu_st_t          sa [NST],
  input  logic [NST-1:0]      sa_acc,
  // replay registers
  input  logic [NRP-1:0]      rp_v,
  input  logic [LQW-1:0]      rp_ldq [NRP],
  input  logic [NRP-1:0]      rp_pipe,          // the entry of rp[r] is still PIPE
  input  lp_ldq_t             rp_f [NRP],       // LDQ fields of the entry of rp[r]
  input  logic                srp_v,
  input  logic [SQW-1:0]      srp_stq,
  input  logic                srp_ok,           // the srp store is alive, has an address, no translation and no fault
  input  logic [XLEN_BITS-1:0]         srp_vaddr,
  // DTLB: one port per physical AGU (LSU_AGU_PHYS); a request is on the port of its AGU, a replay on the free port it took
  input  logic [LSU_AGU_PHYS-1:0] mmu_valid,
  input  logic [31:0]         mmu_paddr [LSU_AGU_PHYS],
  input  logic [1:0]          mmu_result [LSU_AGU_PHYS],
  input  logic [5:0]          mmu_entry [LSU_AGU_PHYS],
  output logic [LSU_AGU_PHYS-1:0] mmu_req_valid,
  output logic [XLEN_BITS-1:0] mmu_req_vaddr [LSU_AGU_PHYS],
  output logic [5:0]          mmu_req_idx [LSU_AGU_PHYS],
  output logic [LSU_AGU_PHYS-1:0] mmu_req_st,       // the request is a store address (the port type is per request)
  // load slots
  output lp_l1in_t            l1 [NLD],
  output lp_tl_t              tl_l [NLD],       // writes into the LDQ entry
  output logic [1:0]          l_tlb [NLD],      // 0 hit, 1 miss, 2 page fault
  output logic                l_hit [NLD],      // physical address usable (hit or replay with a known address)
  output logic [31:0]         l_paddr [NLD],
  output logic                l_mmio [NLD],
  output logic [NRP-1:0]      rp_cons,          // replay register consumed this cycle
  // STA slots
  output logic [NST-1:0]      s1_v,
  output logic [NST-1:0]      s1_replay,
  output logic [SQW-1:0]      s1_stq [NST],
  output lp_tl_t              tl_s [NST],
  output logic [NST-1:0]      tl_s_miss,
  output logic                srp_cons,
  output logic                pf_any            // a load or store page fault (clears the LR/SC reservation)
);

  // slot-level view of the DTLB requests / responses (the slot is the L1 slot, the port the physical one)
  logic [NLD-1:0]      mmu_l_req_valid;
  logic [XLEN_BITS-1:0] mmu_l_req_vaddr [NLD];
  logic [LQW-1:0]      mmu_l_req_idx [NLD];
  logic [2:0]          mmu_l_req_port [NLD];
  logic [NST-1:0]      mmu_s_req_valid;
  logic [XLEN_BITS-1:0] mmu_s_req_vaddr [NST];
  logic [SQW-1:0]      mmu_s_req_idx [NST];
  logic [2:0]          mmu_s_req_port [NST];
  logic [NLD-1:0]      mmu_l_valid;
  logic [31:0]         mmu_l_paddr [NLD];
  logic [1:0]          mmu_l_result [NLD];
  logic [LQW-1:0]      mmu_l_entry [NLD];
  logic [NST-1:0]      mmu_s_valid;
  logic [31:0]         mmu_s_paddr [NST];
  logic [1:0]          mmu_s_result [NST];
  logic [SQW-1:0]      mmu_s_entry [NST];

  // ---- shared AGUs / DTLB ports (LSU_AGU_SHARED, docs/TLB_PORTS.md in trace-model) ----
  // NPH physical ports: 0 .. NLD-1 serve the loads (the last NM of them are shared), NL .. NPH-1 serve the STAs (the first NM of
  // them are shared). A new load of AGU i holds port i, a new STA of AGU k holds port st_phys(k). A replay that needs the DTLB
  // takes a free port it may use (the load replays first, in register order, then the STA replay); with none it stays in its
  // register. NM = 0: every pipe has its own port, nothing is ever refused.
  localparam int NM  = LSU_AGU_SHARED;
  localparam int NL  = NLD - NM;
  localparam int NS  = NST - NM;
  localparam int NPH = NLD + NS;
  function automatic int st_phys(input int k);
    return (k < NS) ? NLD + k : NL + (k - NS);
  endfunction

  // ---- slots <-> DTLB ports ----
  // port q takes the request of the slot whose port tag is q (at most one valid request per port); a slot reads the response
  // of its port
  always_comb begin
    for (int q = 0; q < LSU_AGU_PHYS; q++) begin
      mmu_req_valid[q] = 1'b0;
      mmu_req_vaddr[q] = '0;
      mmu_req_idx[q] = '0;
      mmu_req_st[q] = 1'b0;
      for (int k = 0; k < NLD; k++) if (mmu_l_req_valid[k] && mmu_l_req_port[k] == 3'(q)) begin
        mmu_req_valid[q] = 1'b1;
        mmu_req_vaddr[q] = mmu_req_vaddr[q] | mmu_l_req_vaddr[k];
        mmu_req_idx[q] = mmu_req_idx[q] | 6'(mmu_l_req_idx[k]);
      end
      for (int k = 0; k < NST; k++) if (mmu_s_req_valid[k] && mmu_s_req_port[k] == 3'(q)) begin
        mmu_req_valid[q] = 1'b1;
        mmu_req_st[q] = 1'b1;
        mmu_req_vaddr[q] = mmu_req_vaddr[q] | mmu_s_req_vaddr[k];
        mmu_req_idx[q] = mmu_req_idx[q] | 6'(mmu_s_req_idx[k]);
      end
    end
    for (int k = 0; k < NLD; k++) begin
      mmu_l_valid[k] = mmu_valid[mmu_l_req_port[k]];
      mmu_l_paddr[k] = mmu_paddr[mmu_l_req_port[k]];
      mmu_l_result[k] = mmu_result[mmu_l_req_port[k]];
      mmu_l_entry[k] = LQW'(mmu_entry[mmu_l_req_port[k]]);
    end
    for (int k = 0; k < NST; k++) begin
      mmu_s_valid[k] = mmu_valid[mmu_s_req_port[k]];
      mmu_s_paddr[k] = mmu_paddr[mmu_s_req_port[k]];
      mmu_s_result[k] = mmu_result[mmu_s_req_port[k]];
      mmu_s_entry[k] = SQW'(mmu_entry[mmu_s_req_port[k]]);
    end
  end

  // ---- load slots ----
  logic [2:0]     pre [NLD+1];
  logic [2:0]     nnew;
  logic [2:0]     rpos [NRP];     // load slot of replay register r (after the new loads and the older replays)
  logic [NRP-1:0] rp_ok;
  logic [2:0]     acc;
  logic [NPH-1:0] used;           // physical ports taken: new requests, then the load replays in order
  logic [NPH-1:0] free_ld;
  logic [2:0]     rp_phys [NRP];  // physical port of the load replay of register r (when it needs the DTLB)
  always_comb begin
    used = '0;
    for (int i = 0; i < NLD; i++) used[i] = ag_acc[i];
    for (int k = 0; k < NST; k++) if (sa_acc[k]) used[st_phys(k)] = 1'b1;
    pre[0] = '0;
    for (int i = 0; i < NLD; i++) pre[i+1] = pre[i] + 3'(ag_acc[i]);
    nnew = pre[NLD];
    acc = nnew;
    free_ld = '0;
    for (int r = 0; r < NRP; r++) begin
      logic need, got;
      rpos[r] = acc;
      need = rp_v[r] && rpos[r] < 3'(NLD) && rp_pipe[r] && !rp_f[r].pa_v;   // a DTLB request
      got = 1'b1;
      rp_phys[r] = '0;
      if (need) begin
        got = 1'b0;
        for (int q = 0; q < NLD; q++) begin   // lowest free port a load may use
          if (!got && !used[q]) begin
            got = 1'b1;
            used[q] = 1'b1;
            rp_phys[r] = 3'(q);
          end
        end
      end
      rp_cons[r] = rp_v[r] && rpos[r] < 3'(NLD) && got;
      rp_ok[r] = rp_cons[r] && rp_pipe[r];
      acc = acc + 3'(rp_ok[r]);
    end
    free_ld = used;
  end

  always_comb begin
    for (int k = 0; k < NLD; k++) begin
      l1[k] = '0;
      mmu_l_req_port[k] = '0;
      for (int i = 0; i < NLD; i++) begin
        if (ag_acc[i] && pre[i] == 3'(k)) begin
          mmu_l_req_port[k] = 3'(i);   // a new load holds the port of its AGU
          l1[k].v = 1'b1;
          l1[k].need_tlb = 1'b1;
          l1[k].ldq = ag[i].ldq;
          l1[k].vaddr = ag[i].vaddr;
          l1[k].func3 = ag[i].func3;
          l1[k].snap_idx = ag[i].snap_idx;
          l1[k].snap_flag = ag[i].snap_flag;
          l1[k].lrsc = ag[i].lr;
        end
      end
      for (int r = 0; r < NRP; r++) begin
        if (rp_ok[r] && rpos[r] == 3'(k)) begin
          mmu_l_req_port[k] = rp_phys[r];
          l1[k].v = 1'b1;
          l1[k].replay = 1'b1;
          l1[k].need_tlb = !rp_f[r].pa_v;
          l1[k].ldq = rp_ldq[r];
          l1[k].vaddr = rp_f[r].vaddr;
          l1[k].func3 = rp_f[r].func3;
          l1[k].snap_idx = rp_f[r].snap_idx;
          l1[k].snap_flag = rp_f[r].snap_flag;
          l1[k].pa_v = rp_f[r].pa_v;
          l1[k].paddr_reg = rp_f[r].paddr;
          l1[k].mmio_reg = rp_f[r].mmio;
          l1[k].lrsc = rp_f[r].lrsc;
        end
      end
    end
  end

  // ---- DTLB requests and responses of the load slots ----
  always_comb begin
    for (int k = 0; k < NLD; k++) begin
      logic resp_ok, r_hit, r_pf;
      mmu_l_req_valid[k] = l1[k].v && l1[k].need_tlb;
      mmu_l_req_vaddr[k] = l1[k].vaddr;
      mmu_l_req_idx[k] = l1[k].ldq;
      resp_ok = mmu_l_valid[k] && mmu_l_entry[k] == l1[k].ldq;
      r_hit = resp_ok && mmu_l_result[k] == MMU_HIT;
      r_pf = resp_ok && mmu_l_result[k] == MMU_PF;
      tl_l[k] = '0;
      tl_l[k].hit = l1[k].v && l1[k].need_tlb && r_hit;
      tl_l[k].pf = l1[k].v && l1[k].need_tlb && r_pf;
      tl_l[k].paddr = mmu_l_paddr[k];
      tl_l[k].mmio = lsu_pkg::is_mmio_addr(mmu_l_paddr[k]);
      if (l1[k].need_tlb) begin
        l_hit[k] = r_hit;
        l_tlb[k] = r_hit ? TLB_HIT : (r_pf ? TLB_PF : TLB_MISS);
        l_paddr[k] = mmu_l_paddr[k];
        l_mmio[k] = r_hit && tl_l[k].mmio;
      end else begin
        l_hit[k] = 1'b1;
        l_tlb[k] = TLB_HIT;
        l_paddr[k] = l1[k].paddr_reg;
        l_mmio[k] = l1[k].mmio_reg;
      end
    end
  end

  // ---- STA slots ----
  logic [2:0] spre [NST+1];
  logic [2:0] ns;
  logic       srp_free;
  logic [2:0] srp_phys;           // physical port of the STA replay
  always_comb begin
    spre[0] = '0;
    for (int i = 0; i < NST; i++) spre[i+1] = spre[i] + 3'(sa_acc[i]);
    ns = spre[NST];
    srp_free = 1'b0;
    srp_phys = '0;
    for (int q = NPH - 1; q >= NL; q--) if (!free_ld[q]) begin srp_free = 1'b1; srp_phys = 3'(q); end   // lowest free port a STA may use
    srp_cons = srp_v && ns < 3'(NST) && srp_free;
    for (int k = 0; k < NST; k++) begin
      s1_v[k] = 1'b0;
      s1_replay[k] = 1'b0;
      s1_stq[k] = '0;
      mmu_s_req_vaddr[k] = '0;
      mmu_s_req_port[k] = '0;
      for (int i = 0; i < NST; i++) begin
        if (sa_acc[i] && spre[i] == 3'(k)) begin
          mmu_s_req_port[k] = 3'(st_phys(i));   // a new STA holds the port of its AGU
          s1_v[k] = 1'b1;
          s1_stq[k] = sa[i].stq;
          mmu_s_req_vaddr[k] = sa[i].vaddr;
        end
      end
      if (srp_cons && srp_ok && ns == 3'(k)) begin
        mmu_s_req_port[k] = srp_phys;
        s1_v[k] = 1'b1;
        s1_replay[k] = 1'b1;
        s1_stq[k] = srp_stq;
        mmu_s_req_vaddr[k] = srp_vaddr;
      end
      mmu_s_req_valid[k] = s1_v[k];
      mmu_s_req_idx[k] = s1_stq[k];
    end
  end

  always_comb begin
    for (int k = 0; k < NST; k++) begin
      logic resp_ok;
      resp_ok = mmu_s_valid[k] && mmu_s_entry[k] == s1_stq[k];
      tl_s[k] = '0;
      tl_s[k].hit = s1_v[k] && resp_ok && mmu_s_result[k] == MMU_HIT;
      tl_s[k].pf = s1_v[k] && resp_ok && mmu_s_result[k] == MMU_PF;
      tl_s[k].paddr = mmu_s_paddr[k];
      tl_s[k].mmio = lsu_pkg::is_mmio_addr(mmu_s_paddr[k]);
      tl_s_miss[k] = s1_v[k] && !(tl_s[k].hit || tl_s[k].pf);
    end
  end

  logic [NLD-1:0] pf_l;
  logic [NST-1:0] pf_s;
  always_comb begin
    for (int k = 0; k < NLD; k++) pf_l[k] = tl_l[k].pf;
    for (int k = 0; k < NST; k++) pf_s[k] = tl_s[k].pf;
  end
  assign pf_any = (|pf_l) | (|pf_s);

endmodule

`default_nettype wire
