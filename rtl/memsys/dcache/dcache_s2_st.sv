`default_nettype none
// Ref: MemSubSystem/RealDcache.cpp  RealDcache::stage2_comb (store ports)
// Stage 2, store side (pure combinational), for a granted store slot, in priority order:
//   1. same line as the fill request of this tick: HIT, the store is merged into the next fill snapshot (mrg_en);
//   2. cache hit: HIT + word write + PLRU touch;
//   3. miss: WB merge ok -> HIT, WB merge busy -> CONFLICT, existing MSHR entry -> HIT (merge request),
//      no free entry -> MSHR_FULL, else allocate -> HIT.
// The C++ also merges into the fill write of stage 2 and answers CONFLICT for a hit on the way being filled; both
// need a granted store in the bank of the fill that is in stage 2, which stage 1 never grants (notes section 4).
// Replayed slots: CONFLICT (no retry field for stores), or no response when dcache_s1 issues the hidden retry.
module dcache_s2_st
  import dcache_pkg::*;
(
  input  logic [NST-1:0]       slot_valid,
  input  logic [NST-1:0]       slot_replayed,
  input  logic [31:0]          slot_addr   [NST],
  input  logic [NST-1:0]       retry_issue,
  input  logic [WAYS-1:0]      rd_valid    [NST],
  input  logic [TAG_W-1:0]     rd_tag      [NST][WAYS],
  input  logic [NST-1:0]       wb_mrg_ok,
  input  logic [NST-1:0]       wb_mrg_busy,
  input  logic [NST-1:0]       find_hit,
  input  logic [CNT_W-1:0]     free_rem,                // free MSHR entries left after the loads
  // fill request of this tick (before forwarding; only valid/line are used)
  input  logic                 fr_valid,
  input  logic [LINE_W-1:0]    fr_line,
  output logic [NST-1:0]       resp_valid,
  output logic [1:0]           resp_replay [NST],
  output logic [NST-1:0]       mreq_en,
  output logic [NST-1:0]       pw_en,                   // word write into the cache
  output logic [1:0]           pw_way      [NST],
  output logic [NST-1:0]       lu_en,
  output logic [NST-1:0]       mrg_en                   // merge into the next fill snapshot
);

  logic [NST-1:0]   cand_alloc, alloc_ok;
  logic [CNT_W-1:0] used [NST+1];
  assign used[0] = '0;

  for (genvar i = 0; i < NST; i++) begin : g_st
    logic [WAYS-1:0] hit_in, hit_oh;
    logic            hit_any, normal, to_fill;
    logic [1:0]      hit_way;
    logic [TAG_W-1:0] tag;
    assign tag = slot_addr[i][31 -: TAG_W];
    always_comb begin
      for (int w = 0; w < WAYS; w++) hit_in[w] = rd_valid[i][w] && rd_tag[i][w] == tag;
    end
    ttg_first_set #(.N(WAYS)) u_hit (.req(hit_in), .onehot(hit_oh), .any(hit_any));
    always_comb begin
      hit_way = '0;
      for (int w = 0; w < WAYS; w++) if (hit_oh[w]) hit_way = 2'(w);
    end

    assign normal       = slot_valid[i] && !slot_replayed[i];
    assign to_fill      = normal && fr_valid && slot_addr[i][31:OFF_W] == fr_line;
    // miss path: first of WB merge / existing entry / allocation
    assign cand_alloc[i] = normal && !to_fill && !hit_any && !wb_mrg_ok[i] && !wb_mrg_busy[i] && !find_hit[i];
    assign alloc_ok[i]   = cand_alloc[i] && (free_rem > used[i]);
    assign used[i+1]     = used[i] + CNT_W'(alloc_ok[i]);

    assign mrg_en[i] = to_fill;
    assign pw_en[i]  = normal && !to_fill && hit_any;
    assign pw_way[i] = hit_way;
    assign lu_en[i]  = pw_en[i];
    assign mreq_en[i] = normal && !to_fill && !hit_any && !wb_mrg_ok[i] && !wb_mrg_busy[i] &&
                        (find_hit[i] || alloc_ok[i]);

    always_comb begin
      resp_valid[i]  = slot_valid[i] && !(slot_replayed[i] && retry_issue[i]);
      resp_replay[i] = RP_CONFLICT;
      if (normal) begin
        if (to_fill) begin
          resp_replay[i] = RP_HIT;
        end else if (hit_any) begin
          resp_replay[i] = RP_HIT;
        end else if (wb_mrg_ok[i]) begin
          resp_replay[i] = RP_HIT;
        end else if (wb_mrg_busy[i]) begin
          resp_replay[i] = RP_CONFLICT;
        end else if (find_hit[i] || alloc_ok[i]) begin
          resp_replay[i] = RP_HIT;
        end else begin
          resp_replay[i] = RP_MSHR_FULL;
        end
      end
    end
  end

endmodule
`default_nettype wire
