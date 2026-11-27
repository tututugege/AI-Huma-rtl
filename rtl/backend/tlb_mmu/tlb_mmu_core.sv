// Ref: back-end/Lsu/TlbMmu.cpp  TlbMmu::top_comb / translate_lsu_ports / flush / cancel_pending_walk / seq
`default_nettype none

// N-port translation core shared by the DTLB (one port per physical AGU, the type of a request comes with it)
// and the ITLB (FETCH=1, one fetch port).
// Per cycle exactly one of three modes: fence (SFENCE.VMA: flush the TLB and the walk), cancel (pipeline flush /
// mispredict: drop the
// walk, tell the PTW), translate (serve the ports).
module tlb_mmu_core import tlb_mmu_pkg::*; import ttg_cfg_pkg::*; #(
  parameter int LANES = 8,
  parameter bit FETCH = 1'b0,
  parameter int ENTRIES = 64,
  parameter int NPEEK = 0
) (
  input  logic clk,
  input  logic rst_n,
  input  logic fence,
  input  logic cancel,
  input  logic [XLEN_BITS-1:0] satp,
  input  logic [1:0]  privilege,
  input  logic        mxr,
  input  logic        sum,
  input  logic        mprv,
  input  logic [1:0]  mpp,
  input  logic        req_valid [LANES],
  input  logic [XLEN_BITS-1:0] req_vaddr [LANES],
  input  logic        req_is_store [LANES],   // request is a store address (the port type is per request)
  input  logic        ptw_req_ready,
  input  logic        ptw_resp_valid,
  input  tlb_mmu_ptw_resp_t ptw_resp,
  input  logic pf_page_set,
  input  logic [VPN_W-1:0] pf_page_vpn,
  input  logic [XLEN_BITS-1:0] peek_vaddr [(NPEEK > 0) ? NPEEK : 1],
  output logic        peek_ok    [(NPEEK > 0) ? NPEEK : 1],
  output logic [31:0] peek_paddr [(NPEEK > 0) ? NPEEK : 1],
  output logic        resp_valid [LANES],
  output logic [1:0]  resp_result [LANES],
  output logic [31:0] resp_paddr [LANES],
  output logic [28:0] resp_paddr_p1 [LANES],
  output logic [28:0] resp_paddr_m1 [LANES],
  output logic        ptw_req_valid,
  output logic [VPN_W-1:0] ptw_req_vpn,
  output logic [21:0] ptw_req_root_ppn,
  output logic        ptw_resp_consumed,
  output logic        ptw_flush,
  output logic        walk_next_v,
  output logic [VPN_W-1:0] walk_next_vpn
);


  logic translate;
  assign translate = !fence && !cancel;

  // ---- walk register ----
  tlb_mmu_walk_t walk_q, walk_d;

  // ---- TLB array ----
  logic [ENTRIES-1:0] entry_valid;
  tlb_mmu_entry_t     entry [ENTRIES];
  logic               refill_valid_end;
  tlb_mmu_entry_t     refill_end;

  tlb_mmu_store #(.ENTRIES(ENTRIES)) u_store (
    .clk, .rst_n, .fence, .refill_valid(refill_valid_end), .refill(refill_end), .entry_valid, .entry
  );

  // ---- completed walk is retired first ----
  logic           early_done, early_refill_ok, early_consume;
  tlb_mmu_entry_t early_refill;

  tlb_mmu_early u_early (
    .walk(walk_q), .resp_valid(ptw_resp_valid), .resp(ptw_resp), .done(early_done), .refill_ok(early_refill_ok),
    .refill(early_refill)
  );

  // translate: only a usable response is retired early; cancel: every matching response is consumed; fence: nothing
  // The ITLB (FETCH) path of the reference has no early retirement in translate mode (TlbMmu::translate goes
  // straight into top_comb; only translate_lsu_ports calls consume_completed_walk_refill first), so a completed
  // walk is retired by the fetch lane that asks for its page, or by a cancel.
  logic             pf_page_v_q, early_pf_drop;
  logic [VPN_W-1:0] pf_page_q;
  logic early_in_translate;
  assign early_pf_drop = !FETCH && translate && !early_refill_ok && pf_page_v_q && early_done && (walk_q.vpn == pf_page_q);
  assign early_in_translate = FETCH ? 1'b0 : (early_refill_ok || early_pf_drop);
  assign early_consume = fence ? 1'b0 : (cancel ? early_done : early_in_translate);

  // ---- cycle-start state (what lane 0 of the reference sees) ----
  tlb_mmu_walk_t  walk0;
  logic           resp0_valid, refill0_valid;
  tlb_mmu_entry_t refill1;
  always_comb begin
    walk0 = early_consume ? '0 : walk_q;
    resp0_valid = ptw_resp_valid && !early_consume;
    refill0_valid = early_refill_ok && (cancel || !FETCH);
    // refill made by the port that retires the walk: its page is the walk's page, ASID of the current satp
    refill1.tag = '{global_page: ptw_resp.perm[PERM_G], asid: satp_asid(satp), level: ptw_resp.level, vpn: walk0.vpn};
    refill1.xlat = mk_xlat(ptw_resp.level, ptw_resp.ppn, ptw_resp.perm);
  end

  // ---- ports, all evaluated in parallel ----
  // The reference serves the ports in order (lane 0 first) and each one updates the walk / refill / response it hands
  // on. Only two ports can change that state in a cycle:
  //   A. the first port that misses on the in-flight walk's page: it sends the walk's request, or consumes the PTW
  //      response (retiring the walk if the response is for that page: FAULT, or HIT + refill)
  //   B. after the walk is gone (idle at the cycle start, or retired by A), the first port that misses starts a new
  //      walk and sends its request
  // Every other port only reads the state: lanes after a successful A see A's refill, all misses report MISS.
  logic [LANES-1:0] miss0, miss1, walk_same, resp_perm_ok, use_refill1, retire;
  tlb_mmu_walk_t    walk_new [LANES];

  for (genvar l = 0; l < LANES; l++) begin : g_lane
    logic            table_hit;
    tlb_mmu_xlat_t   table_xlat;
    tlb_mmu_lookup #(.ENTRIES(ENTRIES)) u_lookup (
      .entry_valid, .entry, .vpn(req_vaddr[l][12 +: VPN_W]), .asid(satp_asid(satp)), .hit(table_hit), .xlat(table_xlat)
    );
    tlb_mmu_lane u_lane (
      .valid(req_valid[l] && translate), .access_type(FETCH ? ACC_FETCH : (req_is_store[l] ? ACC_STORE : ACC_LOAD)),
      .vaddr(req_vaddr[l]), .satp, .privilege, .mxr, .sum, .mprv, .mpp,
      .table_hit, .table_xlat, .refill0_valid, .refill0(early_refill), .refill1, .walk_vpn(walk0.vpn),
      .walk_satp(walk0.satp), .ptw_resp_fault(ptw_resp.fault), .ptw_resp_level(ptw_resp.level),
      .ptw_resp_ppn(ptw_resp.ppn), .ptw_resp_perm(ptw_resp.perm),
      .miss0(miss0[l]), .miss1(miss1[l]), .walk_same(walk_same[l]), .resp_perm_ok(resp_perm_ok[l]),
      .walk_new(walk_new[l]), .use_refill1(use_refill1[l]), .retire(retire[l]), .result(resp_result[l]),
      .paddr(resp_paddr[l]), .paddr_p1(resp_paddr_p1[l]), .paddr_m1(resp_paddr_m1[l])
    );
    assign resp_valid[l] = req_valid[l] && translate;
  end

  // A: the port that serves the in-flight walk
  logic [LANES-1:0] a_req, a_oh, after_a;
  logic             a_any, a_issue, a_consume, a_retire, a_ok;
  ttg_first_set #(.N(LANES)) u_first_a (.req(a_req), .onehot(a_oh), .any(a_any));
  always_comb begin
    a_req = walk0.active ? (miss0 & walk_same) : '0;
    for (int l = 0; l < LANES; l++) after_a[l] = |(a_req & ((LANES'(1) << l) - LANES'(1)));   // above A
    a_issue = a_any && !walk0.req_sent && ptw_req_ready;
    a_consume = a_any && walk0.req_sent && resp0_valid;
    a_retire = a_consume && ptw_resp.vpn == walk0.vpn;
    a_ok = a_retire && !ptw_resp.fault && |(a_oh & resp_perm_ok);
    retire = a_retire ? a_oh : '0;
    use_refill1 = a_ok ? after_a : '0;
  end

  // B: the port that starts a new walk. Picked for the three cases in parallel (walk idle at the cycle start: any
  // port, view 0; A retired the walk with a refill: ports above A, view 1; A retired it with a FAULT: ports above A,
  // view 0), the case selects at the end.
  logic [LANES-1:0] b_oh_idle, b_oh_ok, b_oh_fault, b_oh;
  logic             b_any_idle, b_any_ok, b_any_fault, b_any;
  tlb_mmu_walk_t    walk_b;
  ttg_first_set #(.N(LANES)) u_first_b_idle (.req(miss0), .onehot(b_oh_idle), .any(b_any_idle));
  ttg_first_set #(.N(LANES)) u_first_b_ok (.req(after_a & miss1), .onehot(b_oh_ok), .any(b_any_ok));
  ttg_first_set #(.N(LANES)) u_first_b_fault (.req(after_a & miss0), .onehot(b_oh_fault), .any(b_any_fault));
  always_comb begin
    if (!walk0.active) begin
      b_oh = b_oh_idle;
      b_any = b_any_idle;
    end else if (a_ok) begin
      b_oh = b_oh_ok;
      b_any = b_any_ok;
    end else begin
      b_oh = a_retire ? b_oh_fault : '0;
      b_any = a_retire && b_any_fault;
    end
    walk_b = '0;
    for (int l = 0; l < LANES; l++) walk_b = walk_b | (b_oh[l] ? walk_new[l] : '0);
    walk_b.req_sent = ptw_req_ready;
  end

  // ---- commit: walk register, refill, PTW port ----
  // Ref: TlbMmu::seq / apply_top_output. A cancel drops the walk but keeps the refill of an early-retired response.
  tlb_mmu_walk_t walk_end;
  always_comb begin
    walk_end = walk0;
    if (b_any)          walk_end = walk_b;
    else if (a_retire)  walk_end = '0;
    else if (a_issue)   walk_end.req_sent = 1'b1;
    walk_d = (fence || cancel) ? '0 : walk_end;
    refill_valid_end = a_ok || refill0_valid;
    refill_end = a_ok ? refill1 : early_refill;
    ptw_req_valid = a_issue || (b_any && ptw_req_ready);
    // the request carries the walk register as left by the last port (a walk is never rewritten after its request
    // went out)
    ptw_req_vpn = walk_end.vpn;
    ptw_req_root_ppn = walk_end.satp[21:0];
    ptw_resp_consumed = early_consume || a_consume;
    ptw_flush = fence || cancel;
  end

  assign walk_next_v   = walk_d.active;
  assign walk_next_vpn = walk_d.vpn;

  // ---- Optional read-only CAM peek ports (TlbMmu::peek_translate for ACC_FETCH, zero PTW / side effects) ----
  if (NPEEK > 0) begin : g_peek
    logic [1:0]        pk_eff_priv;
    logic              pk_pass;
    logic [ASID_W-1:0] pk_asid;
    assign pk_eff_priv = effective_priv(ACC_FETCH, privilege, mprv, mpp);
    assign pk_pass     = (pk_eff_priv == 2'd3) || !satp_on(satp);
    assign pk_asid     = satp_asid(satp);

    for (genvar p = 0; p < NPEEK; p++) begin : g_p
      logic          pk_tbl_hit, pk_rf_hit, pk_hit;
      /* verilator lint_off UNUSEDSIGNAL */  // peek only reads level, ppn, perm (not ppn_p1 / ppn_m1)
      tlb_mmu_xlat_t pk_tbl_xlat, pk_xlat;
      /* verilator lint_on UNUSEDSIGNAL */
      logic [31:0]   pk_id_pa;

      tlb_mmu_lookup #(.ENTRIES(ENTRIES)) u_pk_lookup (
        .entry_valid, .entry,
        .vpn(peek_vaddr[p][12 +: VPN_W]), .asid(pk_asid),
        .hit(pk_tbl_hit), .xlat(pk_tbl_xlat)
      );

      always_comb begin
        pk_id_pa   = (RV64 && (peek_vaddr[p][XLEN_BITS-1:32] != '0)) ? 32'h7fff_ffff : peek_vaddr[p][31:0];
        pk_rf_hit  = refill_valid_end && !fence && tag_match(refill_end.tag, peek_vaddr[p][12 +: VPN_W], pk_asid);
        pk_hit     = pk_rf_hit || pk_tbl_hit;
        pk_xlat    = pk_rf_hit ? refill_end.xlat : pk_tbl_xlat;
        if (pk_pass) begin
          peek_ok[p]    = 1'b1;
          peek_paddr[p] = pk_id_pa;
        end else if (va_canonical(peek_vaddr[p]) && pk_hit &&
                     perm_ok(pk_xlat.perm, ACC_FETCH, pk_eff_priv, sum, mxr)) begin
          peek_ok[p]    = 1'b1;
          peek_paddr[p] = compose_paddr(peek_vaddr[p][VLOW_W-1:0], pk_xlat.level, pk_xlat.ppn);
        end else begin
          peek_ok[p]    = 1'b0;
          peek_paddr[p] = '0;
        end
      end
    end
  end else begin : g_nopeek
    assign peek_ok[0]    = 1'b0;
    assign peek_paddr[0] = '0;
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_pk;
    assign unused_pk = ^peek_vaddr[0];
    /* verilator lint_on UNUSEDSIGNAL */
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      walk_q      <= '0;
      pf_page_v_q <= 1'b0;
      pf_page_q   <= '0;
    end else begin
      walk_q <= walk_d;
      if (pf_page_set) begin
        pf_page_v_q <= 1'b1;
        pf_page_q   <= pf_page_vpn;
      end else if (early_pf_drop) begin
        pf_page_v_q <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
