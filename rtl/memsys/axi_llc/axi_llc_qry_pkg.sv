`default_nettype none
// Ref: AXI_LLC.cpp  find_*/victim_line_pending/write_line_pending/pick_unreserved_way/enqueue_read_response/enqueue
// _read_victim_snapshot
// State queries and small updates shared by the stage modules.  All take the state version to look at (`r` old regs
// or `n` chain).
// lint: stage functions take whole state/input vectors; each stage reads only the subset it needs.
/* verilator lint_off UNUSEDSIGNAL */
package axi_llc_qry_pkg;
  import axi_llc_pkg::*;

  // ---- MSHR queries ----
  function automatic logic find_mshr_line(input st_t s, input addr_t line, output logic [2:0] idx);
    logic found;
    found = 1'b0;
    idx = '0;
    for (int i = 0; i < NMSHR; i++) begin
      if (!found && s.ms[i].valid && !s.ms[i].bypass && line_of(s.ms[i].addr) == line) begin
        found = 1'b1;
        idx = 3'(i);
      end
    end
    return found;
  endfunction

  function automatic logic find_free_mshr(input st_t s, output logic [2:0] idx);
    logic found;
    found = 1'b0;
    idx = '0;
    for (int i = 0; i < NMSHR; i++) begin
      if (!found && !s.ms[i].valid) begin
        found = 1'b1;
        idx = 3'(i);
      end
    end
    return found;
  endfunction

  function automatic logic has_mshr_for_master(input st_t s, input logic [1:0] m);
    logic any_m;
    any_m = 1'b0;
    for (int i = 0; i < NMSHR; i++) any_m |= s.ms[i].valid && s.ms[i].master == m;
    return any_m;
  endfunction

  // ---- pending-line queries ----
  function automatic logic victim_line_pending(input st_t s, input addr_t line);
    logic p;
    vq_idx_t sl;
    p = s.vwb.valid && s.vwb.addr == line;
    for (int i = 0; i < VQD; i++) begin
      sl = s.rvq.head + vq_idx_t'(i);
      if (vq_cnt_t'(i) < s.rvq.cnt && s.rvq.ent[sl].valid && s.rvq.ent[sl].addr == line) p = 1'b1;
    end
    for (int m = 0; m < NW; m++) begin
      if (s.wc[m].valid && s.wc[m].cpend && s.wc[m].vdirty && s.wc[m].vaddr == line) p = 1'b1;
    end
    for (int i = 0; i < NMSHR; i++) begin
      if (s.ms[i].valid && !s.ms[i].bypass && s.ms[i].vdirty && !s.ms[i].rcomm && s.ms[i].vaddr == line &&
          (s.ms[i].rvalid || s.ms[i].vdone ||
           (s.vwb.valid && !s.vwb.forw && s.vwb.addr == line && s.vwb.slot == 4'(i))))
        p = 1'b1;
    end
    return p;
  endfunction

  function automatic logic write_line_pending(input st_t s, input addr_t line);
    logic p;
    logic [0:0] sl;
    p = 1'b0;
    for (int m = 0; m < NW; m++) begin
      if (s.wc[m].valid && line_of(s.wc[m].addr) == line && !s.wc[m].cdone) p = 1'b1;
      for (int i = 0; i < WQD; i++) begin
        sl = s.wq[m].head + 1'(i);
        if (2'(i) < s.wq[m].cnt && line_of(s.wq[m].ent[sl].addr) == line) p = 1'b1;
      end
    end
    return p;
  endfunction

  // victim_snapshot_waits_for_write_resolution (old regs)
  function automatic logic victim_waits_write(input st_t s, input addr_t vaddr);
    logic w;
    w = (vaddr != 32'd0) && s.lv && s.lw && s.li && !s.lb && line_of(s.laddr) == vaddr;
    for (int m = 0; m < NW; m++) begin
      if (vaddr != 32'd0 && s.wc[m].valid && line_of(s.wc[m].addr) == vaddr && s.wc[m].cpend) w = 1'b1;
    end
    return w;
  endfunction

  // read_victim_snapshot_present
  function automatic logic victim_snapshot_present(input st_t s, input addr_t vaddr);
    logic p;
    vq_idx_t sl;
    p = (vaddr != 32'd0) && s.vwb.valid && !s.vwb.forw && s.vwb.addr == vaddr;
    for (int i = 0; i < VQD; i++) begin
      sl = s.rvq.head + vq_idx_t'(i);
      if (vaddr != 32'd0 && vq_cnt_t'(i) < s.rvq.cnt && s.rvq.ent[sl].valid && s.rvq.ent[sl].addr == vaddr) p = 1'b1;
    end
    return p;
  endfunction

  // ---- way selection ----
  function automatic logic way_reserved(input st_t s, input logic [SB-1:0] set, input logic [WB-1:0] way,
                                        input addr_t line);
    logic res;
    res = 1'b0;
    for (int m = 0; m < NW; m++) begin
      if (s.wc[m].valid && s.wc[m].cpend && set_of(s.wc[m].addr) == set && s.wc[m].way == way &&
          line_of(s.wc[m].addr) != line)
        res = 1'b1;
    end
    for (int i = 0; i < NMSHR; i++) begin
      if (s.ms[i].valid && !s.ms[i].bypass && !s.ms[i].rcomm && set_of(s.ms[i].addr) == set && s.ms[i].way == way &&
          line_of(s.ms[i].addr) != line)
        res = 1'b1;
    end
    return res;
  endfunction

  function automatic logic pick_way(input st_t s, input logic [SB-1:0] set, input logic inv_ok,
                                    input logic [WB-1:0] inv_way, input logic [WB-1:0] repl, input addr_t line,
                                    output logic [WB-1:0] way);
    logic found;
    logic [WB-1:0] cand;
    found = 1'b0;
    way = '0;
    if (inv_ok && !way_reserved(s, set, inv_way, line)) begin
      found = 1'b1;
      way = inv_way;
    end
    cand = repl;
    for (int off = 0; off < WAYS; off++) begin
      if (!found && !way_reserved(s, set, cand, line)) begin
        found = 1'b1;
        way = cand;
      end
      cand = next_way(cand);
    end
    return found;
  endfunction

  // ---- enqueue_read_response: accept test + apply (no side effects through arguments) ----
  function automatic logic enq_resp_ok(input st_t s, input logic [1:0] m);
    return !s.rr[m].valid || s.rr[m].qcnt < 2'(RQD);
  endfunction

  function automatic st_t enq_resp_apply(input st_t s, input logic [1:0] m, input logic [3:0] id, input line_t data);
    st_t o;
    logic t;
    o = s;
    if (!s.rr[m].valid) begin
      o.rr[m].valid = 1'b1;
      o.rr[m].fresh = 1'b1;
      o.rr[m].id = id;
      o.rr[m].data = data;
    end else begin
      t = s.rr[m].qtail;
      o.rr[m].qid[t] = id;
      o.rr[m].qdata[t] = data;
      o.rr[m].qtail = ~t;
      o.rr[m].qcnt = s.rr[m].qcnt + 2'd1;
    end
    return o;
  endfunction

  // ---- enqueue_read_victim_snapshot: already queued counts as success ----
  function automatic logic victim_queued(input st_t s, input logic [3:0] owner, input addr_t vaddr);
    logic dup;
    vq_idx_t sl;
    dup = 1'b0;
    for (int i = 0; i < VQD; i++) begin
      sl = s.rvq.head + vq_idx_t'(i);
      if (vq_cnt_t'(i) < s.rvq.cnt && s.rvq.ent[sl].valid && s.rvq.ent[sl].owner == owner &&
          s.rvq.ent[sl].addr == vaddr)
        dup = 1'b1;
    end
    return dup;
  endfunction

  function automatic logic enq_victim_ok(input st_t s, input logic [3:0] owner, input addr_t vaddr);
    return victim_queued(s, owner, vaddr) || s.rvq.cnt < vq_cnt_t'(VQD);
  endfunction

  function automatic st_t enq_victim_apply(input st_t s, input logic [3:0] owner, input addr_t vaddr,
                                           input line_t data);
    st_t o;
    o = s;
    if (!victim_queued(s, owner, vaddr)) begin
      o.rvq.ent[s.rvq.tail].valid = 1'b1;
      o.rvq.ent[s.rvq.tail].owner = owner;
      o.rvq.ent[s.rvq.tail].addr = vaddr;
      o.rvq.ent[s.rvq.tail].data = data;
      o.rvq.tail = s.rvq.tail + vq_idx_t'(1);
      o.rvq.cnt = s.rvq.cnt + vq_cnt_t'(1);
    end
    return o;
  endfunction

  // table_busy: any table write enabled in this tick so far
  function automatic logic tbl_busy(input ch_t c);
    return c.wd | c.wm | c.wv | c.wr;
  endfunction

  // try_launch_pending_write_lookup: start the lookup of a write context when the lookup engine is free (new-
  // version state)
  function automatic st_t launch_write_lookup(input st_t s);
    st_t o;
    logic found;
    logic [0:0] m;
    logic [0:0] sel;
    o = s;
    found = 1'b0;
    sel = 1'b0;
    if (!s.lv) begin
      for (int off = 0; off < NW; off++) begin
        m = s.rr_write + 1'(off);
        if (!found && s.wc[m].valid && s.wc[m].lpend) begin
          found = 1'b1;
          sel = m;
        end
      end
      if (found) begin
        o.lv = 1'b1;
        o.li = 1'b0;
        o.laddr = s.wc[sel].addr;
        o.lsize = s.wc[sel].size;
        o.lmaster = {1'b0, sel};
        o.lid = s.wc[sel].id;
        o.lw = 1'b1;
        o.lb = 1'b0;
        o.wc[sel].lpend = 1'b0;
        o.rr_write = ~sel;
      end
    end
    return o;
  endfunction

  // clear the lookup registers (lookup_valid=0 ...)
  function automatic st_t lookup_done(input st_t s);
    st_t o;
    o = s;
    o.lv = 1'b0;
    o.li = 1'b0;
    o.lw = 1'b0;
    o.lb = 1'b0;
    return o;
  endfunction
endpackage
/* verilator lint_on UNUSEDSIGNAL */

`default_nettype wire
