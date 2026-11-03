// Ref: MemSubSystem/MemRouteBlock.cpp  MemRouteBlock (comb_response / comb_request / seq)
`default_nettype none

// LSU / ICache / PTW <-> DCache request and response routing (spec/mem_route.io).
// Top level only adapts the flat spec ports.
module mem_route import ttg_cfg_pkg::*; import memcpu_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  input  logic cpu_en,
  // DCache response (published at tick 0)
  input  logic        dcache_resp_load_valid    [NLD],
  input  logic [31:0] dcache_resp_load_req_id   [NLD],
  input  logic [31:0] dcache_resp_load_data     [NLD],
  input  logic [1:0]  dcache_resp_load_replay   [NLD],
  input  logic        dcache_resp_load3_retry,
  input  logic        dcache_resp_store_valid   [NST],
  input  logic [31:0] dcache_resp_store_req_id  [NST],
  input  logic [1:0]  dcache_resp_store_replay  [NST],
  input  logic        dcache_resp_mshr_fill,
  input  logic [FILL_LINE_W-1:0] dcache_resp_mshr_fill_line,
  // LSU requests
  input  logic        lsu_req_load_valid        [NLD],
  input  logic [31:0] lsu_req_load_addr         [NLD],
  input  logic [LD_ID_W-1:0] lsu_req_load_req_id [NLD],
  input  logic        lsu_req_store_valid       [NST],
  input  logic [31:0] lsu_req_store_addr        [NST],
  input  logic [31:0] lsu_req_store_data        [NST],
  input  logic [ST_STRB_W-1:0] lsu_req_store_strb [NST],
  input  logic [ST_ID_W-1:0]   lsu_req_store_req_id [NST],
  // ICache and PTW walk requests
  input  logic        icache_req_valid,
  input  logic [31:0] icache_req_addr,
  input  logic        ptw_walk_req_valid,
  input  logic [31:0] ptw_walk_req_addr,
  // outputs: response side
  output logic        lsu_resp_load_valid       [NLD],
  output logic [31:0] lsu_resp_load_req_id      [NLD],
  output logic [31:0] lsu_resp_load_data        [NLD],
  output logic [1:0]  lsu_resp_load_replay      [NLD],
  output logic        lsu_resp_store_valid      [NST],
  output logic [31:0] lsu_resp_store_req_id     [NST],
  output logic [1:0]  lsu_resp_store_replay     [NST],
  output logic        lsu_resp_mshr_fill,
  output logic [FILL_LINE_W-1:0] lsu_resp_mshr_fill_line,
  output logic        icache_resp_valid,
  output logic        icache_resp_retry,
  output logic        icache_resp_miss,
  output logic [31:0] icache_resp_data,
  output logic        ptw_event_valid,
  output logic [31:0] ptw_event_data,
  output logic [PT_ID_W-1:0] ptw_event_req_id,
  output logic        ptw_wakeup_walk,
  // outputs: request side
  output logic        dcache_req_load_valid     [NLD],
  output logic [31:0] dcache_req_load_addr      [NLD],
  output logic [31:0] dcache_req_load_req_id    [NLD],
  output logic        dcache_req_store_valid    [NST],
  output logic [31:0] dcache_req_store_addr     [NST],
  output logic [31:0] dcache_req_store_data     [NST],
  output logic [ST_STRB_W-1:0] dcache_req_store_strb [NST],
  output logic [ST_ID_W-1:0]   dcache_req_store_req_id [NST],
  output logic        dcache_req_icache_probe,
  output logic        ptw_grant_valid,
  output logic [PT_ID_W-1:0] ptw_grant_req_id
);

  route_owner_e              issued_owner_q;
  logic [RT_ID_W-1:0]        issued_id_q;
  logic [RT_ID_W-1:0]        next_id_q;
  logic                      ptw_wait_q;
  logic                      lsu_replay_valid_q;
  logic [LD_ID_W-1:0]        lsu_replay_id_q;
  route_owner_e              owner_d;
  logic                      ptw_wait_d;
  logic                      lsu_replay_valid_d;
  logic [LD_ID_W-1:0]        lsu_replay_id_d;

  mem_route_state u_state (.*);

  mem_route_resp u_resp (
    .resp_valid  (dcache_resp_load_valid),
    .resp_req_id (dcache_resp_load_req_id),
    .resp_data   (dcache_resp_load_data),
    .resp_replay (dcache_resp_load_replay),
    .resp3_retry (dcache_resp_load3_retry),
    .mshr_fill   (dcache_resp_mshr_fill),
    .lsu_valid   (lsu_resp_load_valid),
    .lsu_req_id  (lsu_resp_load_req_id),
    .lsu_data    (lsu_resp_load_data),
    .lsu_replay  (lsu_resp_load_replay),
    .ic_valid    (icache_resp_valid),
    .ic_retry    (icache_resp_retry),
    .ic_miss     (icache_resp_miss),
    .ic_data     (icache_resp_data),
    .wakeup_walk (ptw_wakeup_walk),
    .*
  );

  mem_route_req u_req (
    .lsu_load_valid      (lsu_req_load_valid),
    .lsu_load_addr       (lsu_req_load_addr),
    .lsu_load_req_id     (lsu_req_load_req_id),
    .walk_req_valid      (ptw_walk_req_valid),
    .walk_req_addr       (ptw_walk_req_addr),
    .dcache_load_valid   (dcache_req_load_valid),
    .dcache_load_addr    (dcache_req_load_addr),
    .dcache_load_req_id  (dcache_req_load_req_id),
    .dcache_icache_probe (dcache_req_icache_probe),
    .grant_valid         (ptw_grant_valid),
    .grant_req_id        (ptw_grant_req_id),
    .*
  );

  // pass-through paths (the C++ memcpy's them): store responses, MSHR fill notification, store requests
  for (genvar s = 0; s < NST; s++) begin : g_store
    assign lsu_resp_store_valid[s]   = dcache_resp_store_valid[s];
    assign lsu_resp_store_req_id[s]  = dcache_resp_store_req_id[s];
    assign lsu_resp_store_replay[s]  = dcache_resp_store_replay[s];
    assign dcache_req_store_valid[s]  = lsu_req_store_valid[s];
    assign dcache_req_store_addr[s]   = lsu_req_store_addr[s];
    assign dcache_req_store_data[s]   = lsu_req_store_data[s];
    assign dcache_req_store_strb[s]   = lsu_req_store_strb[s];
    assign dcache_req_store_req_id[s] = lsu_req_store_req_id[s];
  end
  assign lsu_resp_mshr_fill      = dcache_resp_mshr_fill;
  assign lsu_resp_mshr_fill_line = dcache_resp_mshr_fill_line;

endmodule

`default_nettype wire
