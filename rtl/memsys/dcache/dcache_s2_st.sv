`default_nettype none
// Ref: MemSubSystem/RealDcache.cpp  RealDcache::stage2_comb (store ports)
// Stage 2, store side (pure combinational), for a granted store slot, in priority order:
// 1. same line as the fill request of this tick  -> HIT, the store is merged into the fill (directly into the fill
// write when stage 2
//      already handles that very fill, else through `mrg_*` into the next snapshot);
//   2. cache hit: the way being filled in the same set -> CONFLICT, else HIT + word write + PLRU touch;
// 3. miss: WB merge ok -> HIT, WB merge busy -> CONFLICT, existing MSHR entry -> HIT (merge request), no free
// entry -> MSHR_FULL,
//      else allocate -> HIT.
// Replayed slots: CONFLICT (no `retry` field for stores), or no response when dcache_s1 issues the hidden retry.
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
  // fill request of this tick (before forwarding; only valid/line are used) and the fill write of stage 2
  input  logic                 fr_valid,
  input  logic [LINE_W-1:0]    fr_line,
  input  logic                 same_fill,               // fill request is the line already in stage 2
  input  logic                 s2f_valid,
  input  logic [SET_W-1:0]     s2f_set,
  input  logic                 fill_valid,
  input  logic [1:0]           fill_way_eff,
  output logic [NST-1:0]       resp_valid,
  output logic [1:0]           resp_replay [NST],
  output logic [NST-1:0]       mreq_en,
  output logic [NST-1:0]       pw_en,                   // word write into the cache
  output logic [1:0]           pw_way      [NST],
  output logic [NST-1:0]       lu_en,
  output logic [NST-1:0]       fm_en,                   // merge into the fill write of this tick
  output logic [NST-1:0]       mrg_en                   // merge into the next fill snapshot
);

  logic [NST-1:0]   cand_alloc, alloc_ok;
  logic [CNT_W-1:0] used [NST+1];
  assign used[0] = '0;

  for (genvar i = 0; i < NST; i++) begin : g_st
    logic [WAYS-1:0] hit_in, hit_oh;
    logic            hit_any, normal, to_fill, fill_way_hit;
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
    // hit on the way that stage 2 is filling in the same set (C++ also matches way 0 while the fill is stalled)
    assign fill_way_hit = s2f_valid && s2f_set == slot_addr[i][OFF_W +: SET_W] && fill_way_eff == hit_way;
    // miss path: first of WB merge / existing entry / allocation
    assign cand_alloc[i] = normal && !to_fill && !hit_any && !wb_mrg_ok[i] && !wb_mrg_busy[i] && !find_hit[i];
    assign alloc_ok[i]   = cand_alloc[i] && (free_rem > used[i]);
    assign used[i+1]     = used[i] + CNT_W'(alloc_ok[i]);

    assign fm_en[i]  = to_fill && same_fill && fill_valid;
    assign mrg_en[i] = to_fill && !(same_fill && fill_valid);
    assign pw_en[i]  = normal && !to_fill && hit_any && !fill_way_hit;
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
          resp_replay[i] = fill_way_hit ? RP_CONFLICT : RP_HIT;
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
