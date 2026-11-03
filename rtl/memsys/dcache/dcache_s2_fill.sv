`default_nettype none
// Ref: MemSubSystem/RealDcache.cpp  RealDcache::stage2_comb (fill part: victim selection, dirty write-back,
// fill_write, fill_resp)
// Stage 2, fill side: the snapshot `s2f` (line returned by the MSHR, one tick old) picks a victim way in its set
// (first invalid way, else tree-PLRU); a valid dirty victim is pushed to the WriteBuffer, which must have room,
// otherwise the fill
// is not performed this tick (and not acknowledged: the snapshot is held and retried).  Stores that hit the line
// being filled are
// merged into the fill data here (`fm_*`, only when stage 2 already handles that very fill; otherwise dcache_s1
// merges them later).
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
  // stores merged into the outgoing fill write
  input  logic [NST-1:0]       fm_en,
  input  logic [WORD_W-1:0]    fm_word  [NST],
  input  logic [31:0]          fm_data  [NST],
  input  logic [3:0]           fm_strb  [NST],
  // fill write (array write + mshr_fill wakeup)
  output logic                 fill_valid,
  output logic [1:0]           fill_way_eff,         // C++ fill_write.way_idx: victim, but 0 while the fill is stalled
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
  assign fill_way_eff = fill_valid ? victim : 2'd0;
  assign evict_line   = {fs_tag[victim], fill_set};
  assign evict_data   = fs_line[victim];

  always_comb begin
    fill_data  = s2f_data;
    fill_dirty = s2f_dirty;
    for (int p = 0; p < NST; p++) if (fm_en[p]) begin
      fill_data  = line_merge(fill_data, fm_word[p], fm_data[p], fm_strb[p]);
      fill_dirty = 1'b1;
    end
  end

endmodule
`default_nettype wire
