// Ref: back-end/Lsu/TlbMmu.cpp  TlbMmu::top_comb / translate_lsu_ports / flush / cancel_pending_walk / seq
`default_nettype none

// N-port translation core shared by the DTLB (LD_LANES load ports then store ports) and, later, the ITLB (FETCH=1,
// one fetch port).
// Per cycle exactly one of three modes: fence (SFENCE.VMA: flush the TLB and the walk), cancel (pipeline flush /
// mispredict: drop the
// walk, tell the PTW), translate (serve the ports).
module tlb_mmu_core import tlb_mmu_pkg::*; import ttg_cfg_pkg::*; #(
  parameter int LANES = 8,
  parameter int LD_LANES = 4,       // lanes [0, LD_LANES) are loads, the rest stores (ignored when FETCH)
  parameter bit FETCH = 1'b0,
  parameter int ENTRIES = 64
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
  input  logic        ptw_req_ready,
  input  logic        ptw_resp_valid,
  input  tlb_mmu_ptw_resp_t ptw_resp,
  output logic        resp_valid [LANES],
  output logic [1:0]  resp_result [LANES],
  output logic [31:0] resp_paddr [LANES],
  output logic        ptw_req_valid,
  output logic [VPN_W-1:0] ptw_req_vpn,
  output logic [21:0] ptw_req_root_ppn,
  output logic        ptw_resp_consumed,
  output logic        ptw_flush
);

  function automatic logic [1:0] lane_access_type(input int lane);
    return FETCH ? ACC_FETCH : (lane < LD_LANES ? ACC_LOAD : ACC_STORE);
  endfunction

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
  logic early_in_translate;
  assign early_in_translate = FETCH ? 1'b0 : early_refill_ok;
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
    refill1.xlat = '{level: ptw_resp.level, ppn: ptw_resp.ppn, perm: ptw_resp.perm};
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
    tlb_mmu_lane #(.ACCESS_TYPE(lane_access_type(l))) u_lane (
      .valid(req_valid[l] && translate), .vaddr(req_vaddr[l]), .satp, .privilege, .mxr, .sum, .mprv, .mpp,
      .table_hit, .table_xlat, .refill0_valid, .refill0(early_refill), .refill1, .walk_vpn(walk0.vpn),
      .walk_satp(walk0.satp), .ptw_resp_fault(ptw_resp.fault), .ptw_resp_level(ptw_resp.level),
      .ptw_resp_ppn(ptw_resp.ppn), .ptw_resp_perm(ptw_resp.perm),
      .miss0(miss0[l]), .miss1(miss1[l]), .walk_same(walk_same[l]), .resp_perm_ok(resp_perm_ok[l]),
      .walk_new(walk_new[l]), .use_refill1(use_refill1[l]), .retire(retire[l]), .result(resp_result[l]),
      .paddr(resp_paddr[l])
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

  always_ff @(posedge clk) begin
    if (!rst_n) walk_q <= '0;
    else        walk_q <= walk_d;
  end

endmodule

`default_nettype wire
