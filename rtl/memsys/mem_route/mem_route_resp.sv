// Ref: MemSubSystem/MemRouteBlock.cpp  MemRouteBlock::comb_response
`default_nettype none

// Response side: the DCache response of load port P3 belongs to the route block when a route request was issued
// last cycle.  Route responses (req_id bit 31) are hidden from the LSU; the LSU request displaced from P3 is answered
// with a CONFLICT replay.  HIT -> data to ICache / PTW; CONFLICT -> ICache retry|miss, wake the walk;
// MSHR_HIT / MSHR_FULL -> ICache miss, the walk waits for an MSHR fill (ptw_wait).
module mem_route_resp import ttg_cfg_pkg::*; import memcpu_pkg::*; (
  input  logic                      resp_valid   [NLD],
  input  logic [31:0]               resp_req_id  [NLD],
  input  logic [XLEN_BITS-1:0]               resp_data    [NLD],
  input  logic [1:0]                resp_replay  [NLD],
  input  logic                      resp3_retry,
  input  logic                      mshr_fill,
  input  route_owner_e              issued_owner_q,
  input  logic [RT_ID_W-1:0]        issued_id_q,
  input  logic                      ptw_wait_q,
  input  logic                      issued_hi_q,      // address bit 2 of the route request (word inside a dword)
  input  logic                      lsu_replay_valid_q,
  input  logic [LD_ID_W-1:0]        lsu_replay_id_q,
  // LSU view of the load responses
  output logic                      lsu_valid    [NLD],
  output logic [31:0]               lsu_req_id   [NLD],
  output logic [XLEN_BITS-1:0]               lsu_data     [NLD],
  output logic [1:0]                lsu_replay   [NLD],
  // ICache response
  output logic                      ic_valid,
  output logic                      ic_retry,
  output logic                      ic_miss,
  output logic [31:0]               ic_data,
  // PTW feedback
  output logic                      ptw_event_valid,
  output logic [XLEN_BITS-1:0]      ptw_event_data,
  output logic [RT_ID_W-1:0]        ptw_event_req_id,
  output logic                      wakeup_walk,
  output logic                      ptw_wait_d
);

  // ---- which load responses belong to the route block ----
  logic route_resp [NLD];
  for (genvar p = 0; p < NLD; p++) begin : g_route_flag
    assign route_resp[p] = resp_req_id[p][31];
  end

  wire id_match   = resp_req_id[P3][RT_ID_W-1:0] == issued_id_q;
  wire own_resp   = (issued_owner_q != OWN_NONE) && resp_valid[P3] && route_resp[P3] && id_match;
  wire owner_ic   = issued_owner_q == OWN_ICACHE;
  wire owner_walk = issued_owner_q == OWN_WALK;
  wire [1:0] rp   = resp_replay[P3];
  wire is_hit     = own_resp && (rp == REPLAY_HIT);
  wire is_conf    = own_resp && (rp == REPLAY_CONFLICT);
  wire is_wait    = own_resp && (rp == REPLAY_MSHR_HIT || rp == REPLAY_MSHR_FULL);

  // ---- LSU view: route responses vanish; the displaced LSU request of port P3 is answered with CONFLICT ----
  for (genvar p = 0; p < NLD; p++) begin : g_lsu
    if (p == P3) begin : g_shared
      assign lsu_valid[p]  = own_resp ? lsu_replay_valid_q : (resp_valid[p] && !route_resp[p]);
      assign lsu_req_id[p] = own_resp ? {1'b0, lsu_replay_id_q} : resp_req_id[p];
      assign lsu_data[p]   = own_resp ? '0 : resp_data[p];
      assign lsu_replay[p] = own_resp ? REPLAY_CONFLICT : resp_replay[p];
    end else begin : g_plain
      assign lsu_valid[p]  = resp_valid[p] && !route_resp[p];
      assign lsu_req_id[p] = resp_req_id[p];
      assign lsu_data[p]   = resp_data[p];
      assign lsu_replay[p] = resp_replay[p];
    end
  end

  // ---- ICache response ----
  assign ic_valid = owner_ic && (is_hit || is_conf || is_wait);
  assign ic_retry = owner_ic && is_conf && resp3_retry;
  assign ic_miss  = owner_ic && (is_wait || (is_conf && !resp3_retry));
  // the dcache answers with a data word of XLEN bits; the ICache wants the 32-bit word the probe addressed
  /* verilator lint_off UNUSEDSIGNAL */  // only the addressed 32-bit word reaches the ICache
  logic [XLEN_BITS-1:0] ic_word;
  /* verilator lint_on UNUSEDSIGNAL */
  assign ic_word  = (XLEN_BITS == 64 && issued_hi_q) ? (resp_data[P3] >> 32) : resp_data[P3];
  assign ic_data  = (owner_ic && is_hit) ? ic_word[31:0] : 32'd0;

  // ---- PTW feedback ----
  assign ptw_event_valid  = owner_walk && is_hit;
  assign ptw_event_data   = resp_data[P3];
  assign ptw_event_req_id = issued_id_q;

  // a walk that must wait for a fill is woken by mshr_fill (now, or later through ptw_wait_q)
  assign wakeup_walk = (owner_walk && (is_conf || (is_wait && mshr_fill))) || (mshr_fill && ptw_wait_q);

  // ptw_wait_q: set by a wait response without a fill (to "this response was the walk's"), cleared by every fill
  always_comb begin
    if (mshr_fill)     ptw_wait_d = 1'b0;
    else if (is_wait)  ptw_wait_d = owner_walk;
    else               ptw_wait_d = ptw_wait_q;
  end

endmodule

`default_nettype wire
