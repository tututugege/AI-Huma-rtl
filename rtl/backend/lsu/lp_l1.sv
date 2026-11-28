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
  input  logic [EPW-1:0]      ag_epoch [NLD],
  input  logic [NLD-1:0]      ag_wait_b,
  input  logic [7:0]          ag_pc8 [NLD],
  input  lp_agu_st_t          sa [NST],
  input  logic [NST-1:0]      sa_acc,
  // replay registers
  input  logic [NRP-1:0]      rp_v,
  input  logic [LQW-1:0]      rp_ldq [NRP],
  input  logic [NRP-1:0]      rp_pipe,          // the entry of rp[r] is still PIPE
  input  lp_rp_ent_t          rp_f [NRP],       // pre-registered immutable LDQ fields of rp[r]
  input  logic                srp_v,
  input  logic [SQW-1:0]      srp_stq,
  input  logic                srp_ok,           // the srp store is alive, has an address, no translation and no fault
  input  logic [XLEN_BITS-1:0]         srp_vaddr,
  // DTLB: one port per physical AGU (LSU_AGU_COUNT); a request is on the port of its AGU, a replay on the free port it took
  input  logic [LSU_AGU_COUNT-1:0] mmu_valid,
  input  logic [31:0]              mmu_paddr [LSU_AGU_COUNT],
  input  logic [28:0]              mmu_paddr_p1 [LSU_AGU_COUNT],
  input  logic [28:0]              mmu_paddr_m1 [LSU_AGU_COUNT],
  input  logic [1:0]               mmu_result [LSU_AGU_COUNT],
  input  logic [5:0]               mmu_entry [LSU_AGU_COUNT],
  output logic [LSU_AGU_COUNT-1:0] mmu_req_valid,
  output logic [XLEN_BITS-1:0]     mmu_req_vaddr [LSU_AGU_COUNT],
  output logic [5:0]               mmu_req_idx [LSU_AGU_COUNT],
  output logic [LSU_AGU_COUNT-1:0] mmu_req_st,       // the request is a store address (the port type is per request)
  // load slots
  output lp_l1in_t            l1 [NLD],
  output lp_tl_t              tl_l [NLD],       // writes into the LDQ entry
  output logic [1:0]          l_tlb [NLD],      // 0 hit, 1 miss, 2 page fault
  output logic                l_hit [NLD],      // physical address usable (hit or replay with a known address)
  output logic [31:0]         l_paddr [NLD],
  output logic [28:0]         l_paddr_p1 [NLD],
  output logic [28:0]         l_paddr_m1 [NLD],
  output logic                l_mmio [NLD],
  output logic [NRP-1:0]      rp_cons,          // replay register consumed this cycle
  // STA slots
  output logic [NST-1:0]      s1_v,
  output logic [NST-1:0]      s1_replay,
  output logic [SQW-1:0]      s1_stq [NST],
  output lp_tl_t              tl_s [NST],
  output logic [28:0]         tl_s_p1 [NST],
  output logic [28:0]         tl_s_m1 [NST],
  output logic [NST-1:0]      tl_s_miss,
  output logic                srp_cons,
  output logic                pf_any,           // a load or store page fault (clears the LR/SC reservation)
  // EXP-048 M3: Berti cross-page VA translation on free load-capable DTLB ports
  input  logic [NLD-1:0]      pf_xq_v,
  input  logic [38:0]         pf_xq_va [NLD],
  input  logic [NLD-1:0]      pf_xq_llc,
  input  logic                dtlb_walk_next_v,
  input  logic [26:0]         dtlb_walk_next_vpn,
  output logic [2:0]          pf_xq_pop,
  output logic [NLD-1:0]      pf_xans_v,
  output logic [25:0]         pf_xans_line [NLD],
  output logic [NLD-1:0]      pf_xans_llc,
  output logic                dtlb_pf_page_set,
  output logic [26:0]         dtlb_pf_page_vpn
);

  // Slot-level view of the DTLB responses: slot k reads the response of its DTLB port (its tag).  The requests are built per
  // port, not per slot: no slot-to-port selection sits between the AGU and the DTLB.
  logic [2:0]          mmu_l_req_port [NLD];
  logic [2:0]          mmu_s_req_port [NST];
  logic [NLD-1:0]      mmu_l_valid;
  logic [31:0]         mmu_l_paddr [NLD];
  logic [28:0]         mmu_l_paddr_p1 [NLD];
  logic [28:0]         mmu_l_paddr_m1 [NLD];
  logic [1:0]          mmu_l_result [NLD];
  logic [LQW-1:0]      mmu_l_entry [NLD];
  logic [NST-1:0]      mmu_s_valid;
  logic [31:0]         mmu_s_paddr [NST];
  logic [28:0]         mmu_s_paddr_p1 [NST];
  logic [28:0]         mmu_s_paddr_m1 [NST];
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
    return (k < NS) ? NLD + k : NL + NM - 1 - (k - NS);
  endfunction

  // ---- DTLB port allocation of the replays (a short chain over the replay registers, on thermometer counters) ----
  // used_new: the ports held by the new requests. The load replays take the free load-capable ports lowest first, so the j-th
  // replay that needs the DTLB gets the j-th free port (port_of[j]). The chain over the replay registers carries three
  // thermometer-coded counters (a consumed replay shifts them by one): the load slots left, the DTLB ports left and the
  // DTLB ports taken (its position selects the port).
  logic [NPH-1:0] used_new;
  logic [NLD-1:0] free_l;                 // free ports a load may use
  logic [2:0]     fcnt [NLD+1];           // free load-capable ports below q
  logic [2:0]     port_of [NLD];          // the j-th free load-capable port
  logic [2:0]     nf;
  logic [NLD-1:0] free_s;                 // free load slots: the AGU of the slot has no valid load request
  logic [2:0]     scnt [NLD+1];           // free load slots below q
  logic [2:0]     slot_of [NLD];          // the j-th free load slot
  logic [2:0]     nfs;
  logic [NLD-1:0] sr_t [NRP+1];           // sr_t[r][i]: more than i load slots left before replay register r
  logic [NLD-1:0] pr_t [NRP+1];           // more than i DTLB ports left
  logic [NLD-1:0] ut_t [NRP+1];           // more than i DTLB ports taken by the older replays
  logic [2:0]     rpos [NRP];             // replay register r takes the rpos-th free load slot
  logic [NRP-1:0] rp_ok;
  logic [NRP-1:0] rp_need;                // the replay of register r is a DTLB request
  logic [2:0]     rp_phys [NRP];          // its port
  logic [NPH-1:0] picked;                 // ports taken by the load replays
  always_comb begin
    // Slot k of L1 is AGU k, the DTLB port of an AGU is its own: a request holds them when the AGU holds a uop (a register of the EXU slot, before
    // the flush / mispredict kill), whether the request is accepted (alive) or not, so the replay allocation does not wait for the kill or the
    // acceptance check (they contain the flush)
    used_new = '0;
    for (int i = 0; i < NLD; i++) used_new[i] = ag[i].occ;
    for (int k = 0; k < NST; k++) if (sa[k].occ) used_new[st_phys(k)] = 1'b1;
    free_l = ~used_new[NLD-1:0];
    fcnt[0] = '0;
    for (int q = 0; q < NLD; q++) fcnt[q+1] = fcnt[q] + 3'(free_l[q]);
    nf = fcnt[NLD];
    for (int j = 0; j < NLD; j++) begin
      port_of[j] = '0;
      for (int q = 0; q < NLD; q++) if (free_l[q] && fcnt[q] == 3'(j)) port_of[j] = 3'(q);
    end
    free_s = '0;
    for (int i = 0; i < NLD; i++) free_s[i] = !ag[i].occ;
    scnt[0] = '0;
    for (int q = 0; q < NLD; q++) scnt[q+1] = scnt[q] + 3'(free_s[q]);
    nfs = scnt[NLD];
    for (int j = 0; j < NLD; j++) begin
      slot_of[j] = '0;
      for (int q = 0; q < NLD; q++) if (free_s[q] && scnt[q] == 3'(j)) slot_of[j] = 3'(q);
    end
    for (int i = 0; i < NLD; i++) begin
      sr_t[0][i] = nfs > 3'(i);
      pr_t[0][i] = nf > 3'(i);
    end
    ut_t[0] = '0;
    for (int r = 0; r < NRP; r++) begin
      logic cons, take_port;
      rp_need[r] = rp_pipe[r] && !rp_f[r].pa_v;
      cons = rp_v[r] && sr_t[r][0] && (!rp_need[r] || pr_t[r][0]);   // a slot left, and a port if it needs one
      rp_cons[r] = cons;
      rp_ok[r] = cons && rp_pipe[r];
      take_port = rp_ok[r] && rp_need[r];
      sr_t[r+1] = rp_ok[r] ? (sr_t[r] >> 1) : sr_t[r];
      pr_t[r+1] = take_port ? (pr_t[r] >> 1) : pr_t[r];
      ut_t[r+1] = take_port ? {ut_t[r][NLD-2:0], 1'b1} : ut_t[r];
      rp_phys[r] = '0;
      for (int j = 0; j < NLD; j++) begin   // the (ports taken)-th free port
        if (rp_need[r] && (j == 0 ? !ut_t[r][0] : (ut_t[r][j-1] && !ut_t[r][j]))) rp_phys[r] = port_of[j];
      end
    end
    // free load slot of the replay: the older consumed replays took the first ones
    rpos[0] = '0;
    for (int r = 1; r < NRP; r++) rpos[r] = rpos[r-1] + 3'(rp_ok[r-1]);
    picked = '0;
    for (int q = 0; q < NLD; q++)
      for (int j = 0; j < NLD; j++) if (free_l[q] && fcnt[q] == 3'(j) && ut_t[NRP][j]) picked[q] = 1'b1;
  end

  // ---- load slots ----
  always_comb begin
    for (int k = 0; k < NLD; k++) begin
      l1[k] = '0;
      mmu_l_req_port[k] = '0;
      for (int i = 0; i < NLD; i++) begin
        if (ag_acc[i] && i == k) begin
          mmu_l_req_port[k] = 3'(i);   // a new load sits in the slot and holds the port of its AGU
          l1[k].v = 1'b1;
          l1[k].need_tlb = 1'b1;
          l1[k].ldq = ag[i].ldq;
          l1[k].vaddr = ag[i].vaddr;
          l1[k].func3 = ag[i].func3;
          l1[k].snap_idx = ag[i].snap_idx;
          l1[k].snap_flag = ag[i].snap_flag;
          l1[k].lrsc = ag[i].lr;
          l1[k].epoch = ag_epoch[i];
          l1[k].second = 1'b0;
          l1[k].wait_b = ag_wait_b[i];
          l1[k].dest = ag[i].dest;
          l1[k].rob_idx = ag[i].rob_idx;
          l1[k].rob_flag = ag[i].rob_flag;
          l1[k].no_l1_spec = 1'b0;
          l1[k].pc8 = ag_pc8[i];
        end
      end
      for (int r = 0; r < NRP; r++) begin
        if (rp_ok[r] && slot_of[rpos[r][1:0]] == 3'(k)) begin
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
          l1[k].epoch = rp_f[r].epoch;
          l1[k].second = rp_f[r].second;
          l1[k].wait_b = rp_f[r].wait_b;
          l1[k].dest = rp_f[r].dest_preg;
          l1[k].rob_idx = rp_f[r].rob_idx;
          l1[k].rob_flag = rp_f[r].rob_flag;
          l1[k].no_l1_spec = rp_f[r].no_l1_spec;
          l1[k].pc8 = '0;
        end
      end
    end
  end

  // ---- DTLB responses of the load slots ----
  always_comb begin
    for (int k = 0; k < NLD; k++) begin
      logic resp_ok, r_hit, r_pf;
      mmu_l_valid[k]    = mmu_valid[mmu_l_req_port[k]];
      mmu_l_paddr[k]    = mmu_paddr[mmu_l_req_port[k]];
      mmu_l_paddr_p1[k] = mmu_paddr_p1[mmu_l_req_port[k]];
      mmu_l_paddr_m1[k] = mmu_paddr_m1[mmu_l_req_port[k]];
      mmu_l_result[k]   = mmu_result[mmu_l_req_port[k]];
      mmu_l_entry[k]    = LQW'(mmu_entry[mmu_l_req_port[k]]);
      resp_ok = mmu_l_valid[k] && mmu_l_entry[k] == l1[k].ldq;
      r_hit = resp_ok && mmu_l_result[k] == MMU_HIT;
      r_pf = resp_ok && mmu_l_result[k] == MMU_PF;
      tl_l[k] = '0;
      tl_l[k].hit = l1[k].v && l1[k].need_tlb && r_hit;
      tl_l[k].pf = l1[k].v && l1[k].need_tlb && r_pf;
      tl_l[k].paddr = mmu_l_paddr[k];
      tl_l[k].mmio = lsu_pkg::is_mmio_addr(mmu_l_paddr[k]);
      if (l1[k].need_tlb) begin
        l_hit[k]      = r_hit;
        l_tlb[k]      = r_hit ? TLB_HIT : (r_pf ? TLB_PF : TLB_MISS);
        l_paddr[k]    = mmu_l_paddr[k];
        l_paddr_p1[k] = mmu_l_paddr_p1[k];
        l_paddr_m1[k] = mmu_l_paddr_m1[k];
        l_mmio[k]     = r_hit && tl_l[k].mmio;
      end else begin
        l_hit[k]      = 1'b1;
        l_tlb[k]      = TLB_HIT;
        l_paddr[k]    = l1[k].paddr_reg;
        l_paddr_p1[k] = l1[k].paddr_reg[31:3] + 29'd1;
        l_paddr_m1[k] = l1[k].paddr_reg[31:3] - 29'd1;
        l_mmio[k]     = l1[k].mmio_reg;
      end
    end
  end

  // ---- STA slots ----
  logic       s_free;             // some STA slot has no valid request
  logic [2:0] s_slot;             // the lowest free STA slot (the STA replay takes it)
  logic       srp_free;
  logic [2:0] srp_phys;           // port of the STA replay
  logic       srp_req;            // the STA replay is a DTLB request
  always_comb begin
    s_free = 1'b0;
    s_slot = '0;
    for (int i = NST - 1; i >= 0; i--) if (!sa[i].occ) begin s_free = 1'b1; s_slot = 3'(i); end
    srp_free = 1'b0;
    srp_phys = '0;
    for (int q = NPH - 1; q >= NL; q--) if (!used_new[q] && !picked[q]) begin srp_free = 1'b1; srp_phys = 3'(q); end   // lowest free port a STA may use
    srp_cons = srp_v && s_free && srp_free;
    srp_req = srp_cons && srp_ok;
    for (int k = 0; k < NST; k++) begin
      s1_v[k] = 1'b0;
      s1_replay[k] = 1'b0;
      s1_stq[k] = '0;
      mmu_s_req_port[k] = '0;
      if (sa_acc[k]) begin
        mmu_s_req_port[k] = 3'(st_phys(k));   // a new STA sits in the slot and holds the port of its AGU
        s1_v[k] = 1'b1;
        s1_stq[k] = sa[k].stq;
      end
      if (srp_req && s_slot == 3'(k)) begin
        mmu_s_req_port[k] = srp_phys;
        s1_v[k] = 1'b1;
        s1_replay[k] = 1'b1;
        s1_stq[k] = srp_stq;
      end
    end
  end

  // ---- DTLB requests, built per port: new AGU / replay, then free load ports serve Berti cross-page xq ----
  logic [NPH-1:0]           lsu_mmu_v;
  logic [XLEN_BITS-1:0]     lsu_mmu_va  [NPH];
  logic [5:0]               lsu_mmu_idx [NPH];
  logic [NPH-1:0]           lsu_mmu_st;
  logic [NLD-1:0]           pf_p_en, pf_p_llc;
  logic [38:0]              pf_p_va [NLD];

  // Decouple mmu_req_vaddr / idx / st selection from late ag_acc / sa_acc / srp_ok:
  // port data muxes depend only on registered ag.occ / sa.occ / replay / srp_cons; acceptance gates lsu_mmu_v only.
  always_comb begin
    for (int q = 0; q < NPH; q++) begin
      lsu_mmu_v[q]   = 1'b0;
      lsu_mmu_va[q]  = '0;
      lsu_mmu_idx[q] = '0;
      lsu_mmu_st[q]  = 1'b0;
      if (q < NLD && ag_acc[q])                                                        lsu_mmu_v[q] = 1'b1;
      for (int k = 0; k < NST; k++) if (sa_acc[k] && st_phys(k) == q)                  lsu_mmu_v[q] = 1'b1;
      for (int r = 0; r < NRP; r++) if (rp_ok[r] && rp_need[r] && rp_phys[r] == 3'(q)) lsu_mmu_v[q] = 1'b1;
      if (srp_req && srp_phys == 3'(q))                                                lsu_mmu_v[q] = 1'b1;

      if (q < NLD && ag[q].occ) begin
        lsu_mmu_va[q]  = ag[q].vaddr;
        lsu_mmu_idx[q] = 6'(ag[q].ldq);
        lsu_mmu_st[q]  = 1'b0;
      end else begin
        logic sa_occ_q;
        sa_occ_q = 1'b0;
        for (int k = 0; k < NST; k++) begin
          if (sa[k].occ && st_phys(k) == q) begin
            sa_occ_q       = 1'b1;
            lsu_mmu_va[q]  = sa[k].vaddr;
            lsu_mmu_idx[q] = 6'(sa[k].stq);
            lsu_mmu_st[q]  = 1'b1;
          end
        end
        if (!sa_occ_q) begin
          for (int r = 0; r < NRP; r++) begin
            if (rp_ok[r] && rp_need[r] && rp_phys[r] == 3'(q)) begin
              lsu_mmu_va[q]  = rp_f[r].vaddr;
              lsu_mmu_idx[q] = 6'(rp_ldq[r]);
              lsu_mmu_st[q]  = 1'b0;
            end
          end
          if (srp_cons && srp_phys == 3'(q)) begin
            lsu_mmu_va[q]  = srp_vaddr;
            lsu_mmu_idx[q] = 6'(srp_stq);
            lsu_mmu_st[q]  = 1'b1;
          end
        end
      end
    end
  end

  always_comb begin
    logic [2:0] j;
    j = 3'd0;
    pf_p_en = '0; pf_p_llc = '0;
    for (int q = 0; q < NLD; q++) pf_p_va[q] = '0;
    for (int q = 0; q < NLD; q++) begin
      if (!used_new[q] && !picked[q] && !(srp_req && srp_phys == 3'(q)) && (j < 3'(NLD)) && pf_xq_v[j[1:0]]) begin
        pf_p_en[q]  = 1'b1;
        pf_p_va[q]  = pf_xq_va[j[1:0]];
        pf_p_llc[q] = pf_xq_llc[j[1:0]];
        j = j + 3'd1;
      end
    end
    pf_xq_pop = j;
    for (int q = 0; q < NPH; q++) begin
      if (q < NLD && pf_p_en[q]) begin
        mmu_req_valid[q] = 1'b1;
        mmu_req_vaddr[q] = {{(XLEN_BITS-39){pf_p_va[q][38]}}, pf_p_va[q]};
        mmu_req_idx[q]   = 6'd0;
        mmu_req_st[q]    = 1'b0;
      end else begin
        mmu_req_valid[q] = lsu_mmu_v[q];
        mmu_req_vaddr[q] = lsu_mmu_va[q];
        mmu_req_idx[q]   = lsu_mmu_idx[q];
        mmu_req_st[q]    = lsu_mmu_st[q];
      end
    end
  end

  always_comb begin
    dtlb_pf_page_set = 1'b0;
    dtlb_pf_page_vpn = '0;
    for (int q = 0; q < NLD; q++) begin
      pf_xans_v[q]    = pf_p_en[q] && mmu_valid[q] && (mmu_result[q] == MMU_HIT);
      pf_xans_line[q] = mmu_paddr[q][31:6];
      pf_xans_llc[q]  = pf_p_llc[q];
      if (pf_p_en[q] && mmu_valid[q] && (mmu_result[q] == MMU_MISS) &&
          dtlb_walk_next_v && (dtlb_walk_next_vpn == pf_p_va[q][38:12])) begin
        dtlb_pf_page_set = 1'b1;
        dtlb_pf_page_vpn = pf_p_va[q][38:12];
      end
    end
  end

  always_comb begin
    for (int k = 0; k < NST; k++) begin
      logic resp_ok;
      mmu_s_valid[k]    = mmu_valid[mmu_s_req_port[k]];
      mmu_s_paddr[k]    = mmu_paddr[mmu_s_req_port[k]];
      mmu_s_paddr_p1[k] = mmu_paddr_p1[mmu_s_req_port[k]];
      mmu_s_paddr_m1[k] = mmu_paddr_m1[mmu_s_req_port[k]];
      mmu_s_result[k]   = mmu_result[mmu_s_req_port[k]];
      mmu_s_entry[k]    = SQW'(mmu_entry[mmu_s_req_port[k]]);
      resp_ok = mmu_s_valid[k] && mmu_s_entry[k] == s1_stq[k];
      tl_s[k] = '0;
      tl_s[k].hit   = s1_v[k] && resp_ok && mmu_s_result[k] == MMU_HIT;
      tl_s[k].pf    = s1_v[k] && resp_ok && mmu_s_result[k] == MMU_PF;
      tl_s[k].paddr = mmu_s_paddr[k];
      tl_s[k].mmio  = lsu_pkg::is_mmio_addr(mmu_s_paddr[k]);
      tl_s_p1[k]    = mmu_s_paddr_p1[k];
      tl_s_m1[k]    = mmu_s_paddr_m1[k];
      tl_s_miss[k]  = s1_v[k] && !(tl_s[k].hit || tl_s[k].pf);
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
