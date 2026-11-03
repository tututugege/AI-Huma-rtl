// Ref: MemSubSystem/MemRouteBlock.cpp  MemRouteBlock::comb_request
`default_nettype none

// Request side: ICache / PTW-walk requests take the shared load port (index P3) away from the LSU.
// Priority ICACHE > WALK; an owner cannot win two cycles in a row (issued_owner_q = owner of last cycle's request).
// The displaced LSU request is remembered (lsu_replay_*): the response side answers it with a CONFLICT replay.
module mem_route_req import ttg_cfg_pkg::*; import memcpu_pkg::*; (
  input  logic                      lsu_load_valid   [NLD],
  input  logic [31:0]               lsu_load_addr    [NLD],
  input  logic [LD_ID_W-1:0]        lsu_load_req_id  [NLD],
  input  logic                      icache_req_valid,
  input  logic [31:0]               icache_req_addr,
  input  logic                      walk_req_valid,
  input  logic [31:0]               walk_req_addr,
  input  route_owner_e              issued_owner_q,
  input  logic [RT_ID_W-1:0]        next_id_q,
  output logic                      dcache_load_valid  [NLD],
  output logic [31:0]               dcache_load_addr   [NLD],
  output logic [31:0]               dcache_load_req_id [NLD],  // {route flag, 0.., id}
  output logic                      dcache_icache_probe,
  output logic                      grant_valid,               // walk grant (ICache learns from the response)
  output logic [RT_ID_W-1:0]        grant_req_id,
  output route_owner_e              owner_d,
  output logic                      lsu_replay_valid_d,
  output logic [LD_ID_W-1:0]        lsu_replay_id_d
);

  // ---- arbitration (Ref: comb_request ptw_owner selection) ----
  wire icache_cand = icache_req_valid && (issued_owner_q != OWN_ICACHE);
  wire walk_cand   = walk_req_valid   && (issued_owner_q != OWN_WALK);

  always_comb begin
    if (icache_cand)    owner_d = OWN_ICACHE;
    else if (walk_cand) owner_d = OWN_WALK;
    else                owner_d = OWN_NONE;
  end

  wire granted = owner_d != OWN_NONE;
  wire [31:0] route_addr = (owner_d == OWN_ICACHE) ? icache_req_addr : walk_req_addr;

  // ---- DCache load ports: pass-through, port P3 replaced by the route request ----
  for (genvar p = 0; p < NLD; p++) begin : g_port
    if (p == P3) begin : g_shared
      assign dcache_load_valid[p]  = granted ? 1'b1 : lsu_load_valid[p];
      assign dcache_load_addr[p]   = granted ? route_addr : lsu_load_addr[p];
      assign dcache_load_req_id[p] = granted ? {1'b1, {(31 - RT_ID_W){1'b0}}, next_id_q} : {1'b0, lsu_load_req_id[p]};
    end else begin : g_lsu_only
      assign dcache_load_valid[p]  = lsu_load_valid[p];
      assign dcache_load_addr[p]   = lsu_load_addr[p];
      assign dcache_load_req_id[p] = {1'b0, lsu_load_req_id[p]};
    end
  end

  assign dcache_icache_probe = (owner_d == OWN_ICACHE);
  assign grant_valid         = (owner_d == OWN_WALK);
  assign grant_req_id        = next_id_q;
  assign lsu_replay_valid_d  = lsu_load_valid[P3];
  assign lsu_replay_id_d     = lsu_load_req_id[P3];

endmodule

`default_nettype wire
