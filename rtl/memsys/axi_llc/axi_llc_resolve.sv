`default_nettype none
// Ref: AXI_LLC.cpp  try_complete_lookup (stage 3, 1921-2694), live paths only
// Resolution of the lookup whose table row has just arrived (lookup valid, issued, row valid).  Reads the OLD
// lookup registers and old MSHR / write-context state; its effects (table write, MSHR allocation, victim
// write-back, response enqueue) are requests to the owning units.
//   hit  + write : merge into the line, table write (dirty), update victim snapshots of in-flight refills
//   hit  + read  : response to the master (replacement pointer update unless bypass)
//   miss + write : full-line write: dirty victim -> write-back first (context waits), else table write
//   miss + read  : allocate an MSHR (also for bypass reads)
// Any unmet precondition (table busy, no way, MSHR busy, response queue full, write-back busy) is `retry`: the
// table read is issued again.
module axi_llc_resolve
  import axi_llc_pkg::*;
(
  input  logic act,                            // lookup valid + issued + table row valid
  input  logic is_write,
  input  logic bypass,
  input  addr_t laddr,
  // table row of the set
  input  logic [WAYS-1:0] lk_v,
  input  logic [WAYS-1:0] lk_d,
  input  logic [WAYS-1:0][TAGW-1:0] lk_t,
  input  logic [WAYS-1:0][511:0] lk_line,
  input  logic [WB-1:0] lk_repl,
  // write data of the context (write lookups)
  input  line_t wdata,
  input  logic [63:0] wstrb,
  input  logic [7:0] wsize,
  // conditions from other units
  input  logic tbl_busy2,                      // stage 2 wrote the tables in this tick
  input  logic vwb_busy2,
  input  logic acc_a,                          // read response queue of the master can take the response
  input  logic mshr_free,
  input  logic mshr_line_hit,                  // a refill of this line is already in flight
  input  logic [WAYS-1:0] reserved,
  // results
  output logic done,
  output logic retry,
  output tw_t tw,
  output logic enq_v,
  output line_t enq_data,
  output logic vu_go,
  output logic [WB-1:0] vu_way,
  output line_t vu_data,
  output logic cdone_set,
  output logic cpend_set,
  output addr_t vict_addr,
  output logic [WB-1:0] pick_way,
  output line_t vict_data,
  output logic forw_go,
  output logic alloc_go,
  output logic alloc_vdirty,
  output logic bad_partial                     // partial-line write miss (not implemented)
);
  logic [WAYS-1:0] tag_eq, hit_oh, inv_oh, sel_oh;
  logic hit_any, inv_any, pick_ok, vdirty;
  logic [WB-1:0] hit_way, inv_way, sel_way;
  logic [TAGW-1:0] vtag;
  line_t line_sel, merged;
  line_t way_line [WAYS];
  logic hit_w_ok, hit_r_want, hit_r_ok, miss_w_pick, miss_w_fwd, miss_w_direct, miss_r_ok;

  always_comb begin
    for (int w = 0; w < WAYS; w++) tag_eq[w] = lk_v[w] && lk_t[w] == tag_of(laddr);
  end
  ttg_first_set #(.N(WAYS)) u_hit (.req(tag_eq), .onehot(hit_oh), .any(hit_any));
  ttg_first_set #(.N(WAYS)) u_inv (.req(~lk_v), .onehot(inv_oh), .any(inv_any));
  ttg_onehot_to_idx #(.N(WAYS), .IDXW(WB)) u_hit_idx (.onehot(hit_oh), .idx(hit_way));
  ttg_onehot_to_idx #(.N(WAYS), .IDXW(WB)) u_inv_idx (.onehot(inv_oh), .idx(inv_way));
  axi_llc_waypick u_pick (.inv_any(inv_any), .inv_way(inv_way), .reserved(reserved), .repl(lk_repl),
                          .ok(pick_ok), .way(pick_way));

  // the way whose line is read: the hit way, else the victim way
  always_comb begin
    sel_way = hit_any ? hit_way : pick_way;
    sel_oh = WAYS'(1) << sel_way;
    vdirty = lk_v[pick_way] && lk_d[pick_way];
    vtag = lk_t[pick_way];
  end
  always_comb begin
    for (int w = 0; w < WAYS; w++) way_line[w] = lk_line[w];
  end
  ttg_onehot_mux #(.N(WAYS), .W(512)) u_line (.sel(sel_oh), .data(way_line), .out(line_sel));
  axi_llc_merge u_merge (.base(line_sel), .offset(laddr[5:0]), .data(wdata), .strb(wstrb), .size(wsize),
                         .merged(merged));

  // which of the four cases completes in this tick (none of these depends on the response queue)
  always_comb begin
    hit_w_ok = act && hit_any && is_write && !tbl_busy2;
    hit_r_want = act && hit_any && !is_write && (bypass || !tbl_busy2);
    miss_w_pick = act && !hit_any && is_write && pick_ok;
    miss_w_fwd = miss_w_pick && vdirty && !vwb_busy2;
    miss_w_direct = miss_w_pick && !vdirty && !tbl_busy2;
    miss_r_ok = act && !hit_any && !is_write && !mshr_line_hit && mshr_free && pick_ok;
    bad_partial = act && !hit_any && is_write && !is_full_write(laddr, wstrb, wsize);
  end

  // the response queue decides whether a read hit completes
  always_comb begin
    hit_r_ok = hit_r_want && acc_a;
    done = hit_w_ok || hit_r_ok || miss_w_fwd || miss_w_direct || miss_r_ok;
    retry = act && !done;
  end

  // table write (hit write, direct write miss) / replacement-pointer update (hit read)
  always_comb begin
    tw = '0;
    tw.line_en = hit_w_ok || miss_w_direct;
    tw.repl_en = hit_w_ok || miss_w_direct || (hit_r_ok && !bypass);
    tw.set = set_of(laddr);
    tw.way = sel_way;
    tw.data = hit_any ? merged : wdata;       // full-line write miss: the merge result is the write data
    tw.tag = tag_of(laddr);
    tw.dirty = 1'b1;
    tw.repl = next_way(sel_way);
  end

  // requests to the owning units
  always_comb begin
    enq_v = hit_r_want;
    enq_data = resp_of(laddr, line_sel);
    vu_go = hit_w_ok;
    vu_way = hit_way;
    vu_data = merged;
    cdone_set = hit_w_ok || miss_w_direct;
    cpend_set = miss_w_fwd;
    forw_go = miss_w_fwd;
    vict_addr = addr_of(vtag, set_of(laddr));
    vict_data = line_sel;
    alloc_go = miss_r_ok;
    alloc_vdirty = vdirty && !bypass;
  end
endmodule

`default_nettype wire
