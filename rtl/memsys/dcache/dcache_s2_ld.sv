`default_nettype none
// Ref: MemSubSystem/RealDcache.cpp  RealDcache::stage2_comb (load ports)
// Stage 2, load side (pure combinational). Priority for a granted load: WriteBuffer bypass > cache hit (updates PLRU) >
// ICache probe (lookup only) > MSHR hit > MSHR full > allocate a new MSHR entry (replays later as MSHR_HIT).
// Replayed (bank-conflict) loads answer CONFLICT/retry, except the LSU ones whose hidden retry is issued by
// dcache_s1 (no response).
module dcache_s2_ld
  import dcache_pkg::*;
(
  input  logic [NLD-1:0]       slot_valid,
  input  logic [NLD-1:0]       slot_replayed,
  input  logic [31:0]          slot_addr   [NLD],
  input  logic [NLD-1:0]       retry_issue,
  input  logic [2:0]           icache_req_s2,
  input  logic [WAYS-1:0]      rd_valid    [NLD],
  input  logic [TAG_W-1:0]     rd_tag      [NLD][WAYS],
  input  logic [31:0]          rd_data     [NLD][WAYS],
  input  logic [NLD-1:0]       byp_valid,
  input  logic [31:0]          byp_data    [NLD],
  input  logic [NLD-1:0]       find_hit,
  input  logic [CNT_W-1:0]     free_in,
  output logic [NLD-1:0]       resp_valid,
  output logic [31:0]          resp_data   [NLD],
  output logic [NLD-1:0]       resp_retry,
  output logic [1:0]           resp_replay [NLD],
  output logic [NLD-1:0]       mreq_en,                 // allocate / request an MSHR entry
  output logic [NLD-1:0]       lu_en,                   // PLRU touch (cache hit)
  output logic [1:0]           lu_way      [NLD],
  output logic [CNT_W-1:0]     alloc_cnt                // entries claimed by the loads (free-count chain)
);

  logic [NLD-1:0] cand_alloc, alloc_ok;
  logic [CNT_W-1:0] used [NLD+1];

  assign used[0] = '0;
  for (genvar i = 0; i < NLD; i++) begin : g_ld
    logic [WAYS-1:0] hit_in, hit_oh;
    logic            hit_any;
    logic [31:0]     hit_data;
    logic            probe, normal;
    logic [TAG_W-1:0] tag;
    assign tag = slot_addr[i][31 -: TAG_W];
    always_comb begin
      for (int w = 0; w < WAYS; w++) hit_in[w] = rd_valid[i][w] && rd_tag[i][w] == tag;
    end
    ttg_first_set #(.N(WAYS)) u_hit (.req(hit_in), .onehot(hit_oh), .any(hit_any));
    always_comb begin
      hit_data = '0;
      lu_way[i] = '0;
      for (int w = 0; w < WAYS; w++) if (hit_oh[w]) begin
        hit_data  = rd_data[i][w];
        lu_way[i] = 2'(w);
      end
    end

    assign normal = slot_valid[i] && !slot_replayed[i];
    assign probe  = icache_req_s2 == 3'(i);
    // miss without an MSHR entry yet (neither WB bypass, hit, probe nor existing entry)
    assign cand_alloc[i] = normal && !byp_valid[i] && !hit_any && !probe && !find_hit[i];
    assign alloc_ok[i]   = cand_alloc[i] && (free_in > used[i]);
    assign used[i+1]     = used[i] + CNT_W'(alloc_ok[i]);
    assign mreq_en[i]    = alloc_ok[i];
    assign lu_en[i]      = normal && !byp_valid[i] && hit_any;

    always_comb begin
      resp_valid[i]  = slot_valid[i] && !(slot_replayed[i] && retry_issue[i]);
      resp_retry[i]  = slot_replayed[i];
      resp_data[i]   = '0;
      resp_replay[i] = RP_CONFLICT;
      if (normal) begin
        resp_retry[i] = 1'b0;
        if (byp_valid[i]) begin
          resp_data[i]   = byp_data[i];
          resp_replay[i] = RP_HIT;
        end else if (hit_any) begin
          resp_data[i]   = hit_data;
          resp_replay[i] = RP_HIT;
        end else if (probe) begin
          resp_replay[i] = RP_CONFLICT;
        end else if (find_hit[i] || alloc_ok[i]) begin
          resp_replay[i] = RP_MSHR_HIT;
        end else begin
          resp_replay[i] = RP_MSHR_FULL;
        end
      end
    end
  end
  assign alloc_cnt = used[NLD];

endmodule
`default_nettype wire
