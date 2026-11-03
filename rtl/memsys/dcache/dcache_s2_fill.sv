`default_nettype none
// Ref: MemSubSystem/RealDcache.cpp  RealDcache::stage2_comb (fill part: victim, write-back, fill_write, fill_resp)
// Stage 2, fill side: the snapshot `s2f` (the line returned by the MSHR, one tick old) picks a victim way in its
// set (first invalid way, else tree-PLRU).  A valid dirty victim is pushed to the WriteBuffer, which must have room;
// otherwise the fill is not performed this tick and not acknowledged (the snapshot is held and retried).  Stores to
// the line of the fill in stage 2 never reach stage 2 in the same tick (the fill owns that bank, so they were
// denied), hence the fill data is exactly the snapshot.
module dcache_s2_fill
  import dcache_pkg::*;
(
  input  logic                 s2f_valid,
  input  logic [MSHR_IDW-1:0]  s2f_id,
  input  logic                 s2f_dirty,
  input  logic [LINE_W-1:0]    s2f_line,
  input  logic [LINE_BITS-1:0] s2f_data,
  // snapshot of the set (state before this tick's writes)
  input  logic [WAYS-1:0]      fs_valid,
  input  logic [WAYS-1:0]      fs_dirty,
  input  logic [TAG_W-1:0]     fs_tag   [WAYS],
  input  logic [LINE_BITS-1:0] fs_line  [WAYS],
  input  logic [2:0]           fs_plru,
  input  logic                 wb_has_room,
  // fill write (array write + mshr_fill wakeup)
  output logic                 fill_valid,
  // way actually written: the way already holding the tag, else the victim
  output logic [1:0]           fill_way_tgt,
  output logic                 fill_dirty,
  output logic [LINE_BITS-1:0] fill_data,
  // fill acknowledge to the MSHR
  output logic                 fill_done,
  output logic [MSHR_IDW-1:0]  fill_done_id,
  // evicted dirty line -> WriteBuffer
  output logic                 evict_valid,
  output logic [LINE_W-1:0]    evict_line,
  output logic [LINE_BITS-1:0] evict_data
);

  logic [TAG_W-1:0]  fill_tag;
  logic [SET_W-1:0]  fill_set;
  assign fill_tag = s2f_line[LINE_W-1:SET_W];
  assign fill_set = s2f_line[SET_W-1:0];

  // ---- victim: first invalid way, else PLRU ----
  logic [WAYS-1:0] inv_oh;
  logic            any_invalid;
  logic [1:0]      victim;
  ttg_first_set #(.N(WAYS)) u_inv (.req(~fs_valid), .onehot(inv_oh), .any(any_invalid));
  always_comb begin
    victim = plru_victim(fs_plru);
    if (any_invalid) begin
      victim = '0;
      for (int w = 0; w < WAYS; w++) if (inv_oh[w]) victim = 2'(w);
    end
  end

  // ---- way already holding the line (write_dcache_line re-searches the set by tag) ----
  logic [WAYS-1:0] tag_match_oh;
  logic            tag_match_any;
  logic [WAYS-1:0] tag_match_in;
  always_comb begin
    for (int w = 0; w < WAYS; w++) tag_match_in[w] = fs_valid[w] && fs_tag[w] == fill_tag;
  end
  ttg_first_set #(.N(WAYS)) u_tag (.req(tag_match_in), .onehot(tag_match_oh), .any(tag_match_any));
  always_comb begin
    fill_way_tgt = victim;
    if (tag_match_any) begin
      for (int w = 0; w < WAYS; w++) if (tag_match_oh[w]) fill_way_tgt = 2'(w);
    end
  end

  // ---- decisions ----
  logic victim_dirty;
  assign victim_dirty = fs_valid[victim] && fs_dirty[victim];
  assign fill_valid   = s2f_valid && (!victim_dirty || wb_has_room);
  assign evict_valid  = s2f_valid && victim_dirty && wb_has_room;
  assign fill_done    = fill_valid;
  assign fill_done_id = s2f_id;
  assign evict_line   = {fs_tag[victim], fill_set};
  assign evict_data   = fs_line[victim];

  assign fill_data  = s2f_data;
  assign fill_dirty = s2f_dirty;

endmodule
`default_nettype wire
