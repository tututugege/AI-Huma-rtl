// Ref: back-end/Lsu/TlbMmu.cpp  TlbMmu::top_comb / translate_lsu_ports / flush / cancel_pending_walk / seq
`default_nettype none

// N-port translation core shared by the DTLB (LD_LANES load ports then store ports) and, later, the ITLB (FETCH=1,
// one fetch port).
// Per cycle exactly one of three modes: fence (SFENCE.VMA: flush the TLB and the walk), cancel (pipeline flush /
// mispredict: drop the
// walk, tell the PTW), translate (serve the ports).
module tlb_mmu_core import tlb_mmu_pkg::*; #(
  parameter int LANES = 8,
  parameter int LD_LANES = 4,       // lanes [0, LD_LANES) are loads, the rest stores (ignored when FETCH)
  parameter bit FETCH = 1'b0,
  parameter int ENTRIES = 64
) (
  input  logic clk,
  input  logic rst_n,
  input  logic fence,
  input  logic cancel,
  input  logic [31:0] satp,
  input  logic [1:0]  privilege,
  input  logic        mxr,
  input  logic        sum,
  input  logic        mprv,
  input  logic [1:0]  mpp,
  input  logic        req_valid [LANES],
  input  logic [31:0] req_vaddr [LANES],
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
  // The ITLB (FETCH) path of the reference has no early retirement in translate mode (TlbMmu::translate goes straight into
  // top_comb; only translate_lsu_ports calls consume_completed_walk_refill first), so a completed walk is retired by the
  // fetch lane that asks for its page, or by a cancel.
  logic early_in_translate;
  assign early_in_translate = FETCH ? 1'b0 : early_refill_ok;
  assign early_consume = fence ? 1'b0 : (cancel ? early_done : early_in_translate);

  // ---- lane chain (lane 0 has priority) ----
  tlb_mmu_chain_t chain [LANES+1];
  logic [LANES-1:0] lane_req_issued, lane_resp_consumed;

  tlb_mmu_chain_t chain_start;
  always_comb begin
    chain_start.walk = early_consume ? '0 : walk_q;
    chain_start.refill_valid = early_refill_ok && (cancel || !FETCH);
    chain_start.refill = early_refill;
    chain_start.resp_valid = ptw_resp_valid && !early_consume;
  end
  assign chain[0] = chain_start;

  for (genvar l = 0; l < LANES; l++) begin : g_lane
    logic            table_hit;
    tlb_mmu_xlat_t   table_xlat;
    tlb_mmu_lookup #(.ENTRIES(ENTRIES)) u_lookup (
      .entry_valid, .entry, .vpn(req_vaddr[l][31:12]), .asid(satp[30:22]), .hit(table_hit), .xlat(table_xlat)
    );
    tlb_mmu_chain_t  lane_chain_in, lane_chain_out;
    assign lane_chain_in = chain[l];
    assign chain[l+1] = lane_chain_out;
    tlb_mmu_lane #(.ACCESS_TYPE(lane_access_type(l))) u_lane (
      .valid(req_valid[l] && translate), .vaddr(req_vaddr[l]), .satp, .privilege, .mxr, .sum, .mprv, .mpp,
      .table_hit, .table_xlat, .ptw_req_ready, .ptw_resp, .chain_in(lane_chain_in), .chain_out(lane_chain_out),
      .req_issued(lane_req_issued[l]), .resp_consumed(lane_resp_consumed[l]), .result(resp_result[l]),
      .paddr(resp_paddr[l])
    );
    assign resp_valid[l] = req_valid[l] && translate;
  end

  // ---- commit: walk register, refill, PTW port ----
  // Ref: TlbMmu::seq / apply_top_output. A cancel drops the walk but keeps the refill of an early-retired response.
  always_comb begin
    walk_d = (fence || cancel) ? '0 : chain[LANES].walk;
    refill_valid_end = chain[LANES].refill_valid;
    refill_end = chain[LANES].refill;
    ptw_req_valid = |lane_req_issued;
    // the request carries the walk register as left by the last lane (a walk is never rewritten after its request went
    // out)
    ptw_req_vpn = chain[LANES].walk.vpn;
    ptw_req_root_ppn = chain[LANES].walk.satp[21:0];
    ptw_resp_consumed = early_consume || (|lane_resp_consumed);
    ptw_flush = fence || cancel;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) walk_q <= '0;
    else        walk_q <= walk_d;
  end

endmodule

`default_nettype wire
