`default_nettype none
// Ref: AXI_LLC.cpp  AXI_LLC::try_complete_lookup (stage 3, C++ 1921-2694), live paths only
// Runs when the table row of the registered lookup arrives (3 ticks after the read request).  Hit: read hit / write
// hit (merge, dirty,
// victims of in-flight refills).  Miss: full-line write miss (victim write-back via the global slot, or direct
// table write) and
// read miss (MSHR allocation, also for bypass reads).  Any failed precondition drops lookup_issued so the table
// read is re-issued.
// lint: stage functions take whole state/input vectors; each stage reads only the subset it needs.
/* verilator lint_off UNUSEDSIGNAL */
module axi_llc_s3_lookup
  import axi_llc_pkg::*;
  import axi_llc_qry_pkg::*;
(
  input  st_t r,
  input  in_t i,
  input  ch_t ci,
  output ch_t co
);
  function automatic ch_t hit_write(input st_t rr, input in_t ii, input ch_t cc, input logic [WB-1:0] hw);
    ch_t c;
    line_t merged;
    logic [SB-1:0] set;
    logic [0:0] m;
    c = cc;
    set = set_of(rr.laddr);
    m = rr.lmaster[0];
    if (tbl_busy(c)) begin
      c.n.li = 1'b0;  // stall_lookup_on_table_busy
    end else begin
      merged = merge_line(ii.lk_line[hw], rr.laddr, c.n.wc[m].data, c.n.wc[m].strb, c.n.wc[m].size);
      for (int s = 0; s < NMSHR; s++) begin
        if (rr.ms[s].valid && !rr.ms[s].bypass && !rr.ms[s].rcomm && set_of(rr.ms[s].addr) == set &&
            rr.ms[s].way == hw && line_of(rr.ms[s].addr) != line_of(rr.laddr)) begin
          c.n.ms[s].vdirty = 1'b1;
          c.n.ms[s].vdone = 1'b0;
          c.n.ms[s].vaddr = line_of(rr.laddr);
          c.n.ms[s].vdata = merged;
        end
      end
      c.wd = 1'b1; c.wm = 1'b1; c.wv = 1'b1; c.wr = 1'b1;
      c.tset = set;
      c.tway = hw;
      c.tdata = merged;
      c.ttag = tag_of(rr.laddr);
      c.tdirty = 1'b1;
      c.trepl = next_way(hw);
      c.n = lookup_done(c.n);
      c.n.wc[m].cdone = 1'b1;
    end
    return c;
  endfunction

  function automatic ch_t hit_read(input st_t rr, input in_t ii, input ch_t cc, input logic [WB-1:0] hw);
    ch_t c;
    logic ok;
    c = cc;
    if (!rr.lb && tbl_busy(c)) begin
      c.n.li = 1'b0;
    end else begin
      ok = enq_resp_ok(c.n, rr.lmaster);
      if (!ok) begin
        c.n.li = 1'b0;
      end else begin
        c.n = enq_resp_apply(c.n, rr.lmaster, rr.lid, resp_of(rr.laddr, ii.lk_line[hw]));
        if (!rr.lb) begin
          c.wr = 1'b1;
          c.tset = set_of(rr.laddr);
          c.trepl = next_way(hw);
        end
        c.n = lookup_done(c.n);
      end
    end
    return c;
  endfunction

  function automatic ch_t miss_write(input st_t rr, input in_t ii, input ch_t cc, input logic inv_ok,
                                     input logic [WB-1:0] iw);
    ch_t c;
    logic [WB-1:0] vw;
    logic ok, vd;
    line_t merged;
    logic [0:0] m;
    c = cc;
    m = rr.lmaster[0];
    ok = pick_way(rr, set_of(rr.laddr), inv_ok, iw, ii.lk_repl, line_of(rr.laddr), vw);
    vd = ii.lk_v[vw] && ii.lk_d[vw];
    // partial-line write miss: never observed
    if (!is_full_write(rr.laddr, c.n.wc[m].strb, c.n.wc[m].size)) c.bad = 1'b1;
    if (!ok) begin
      c.n.li = 1'b0;
    end else begin
      merged = merge_line('0, rr.laddr, c.n.wc[m].data, c.n.wc[m].strb, c.n.wc[m].size);
      if (vd) begin
        if (c.n.vwb.valid) begin
          c.n.li = 1'b0;  // stall_lookup_on_victim_wb_busy
        end else begin
          c.n.vwb.valid = 1'b1;
          c.n.vwb.issued = 1'b0;
          c.n.vwb.forw = 1'b1;
          c.n.vwb.wm = m;
          c.n.vwb.slot = 4'd0;
          c.n.vwb.addr = addr_of(ii.lk_t[vw], set_of(rr.laddr));
          c.n.vwb.data = ii.lk_line[vw];
          c.n.wc[m].cpend = 1'b1;
          c.n.wc[m].vdirty = 1'b1;
          c.n.wc[m].vaddr = addr_of(ii.lk_t[vw], set_of(rr.laddr));
          c.n.wc[m].way = vw;
          c.n.wc[m].line = merged;
          c.n = lookup_done(c.n);
        end
      end else if (tbl_busy(c)) begin
        c.n.li = 1'b0;
      end else begin
        c.wd = 1'b1; c.wm = 1'b1; c.wv = 1'b1; c.wr = 1'b1;
        c.tset = set_of(rr.laddr);
        c.tway = vw;
        c.tdata = merged;
        c.ttag = tag_of(rr.laddr);
        c.tdirty = 1'b1;
        c.trepl = next_way(vw);
        c.n.wc[m].cdone = 1'b1;
        c.n = lookup_done(c.n);
      end
    end
    return c;
  endfunction

  function automatic ch_t miss_read(input st_t rr, input in_t ii, input ch_t cc, input logic inv_ok,
                                    input logic [WB-1:0] iw);
    ch_t c;
    logic [WB-1:0] vw;
    logic [2:0] mi, fi;
    logic ok, vd, found;
    c = cc;
    found = find_mshr_line(rr, line_of(rr.laddr), mi);
    ok = find_free_mshr(rr, fi);
    if (found || !ok) begin
      c.n.li = 1'b0;
    end else if (!pick_way(rr, set_of(rr.laddr), inv_ok, iw, ii.lk_repl, line_of(rr.laddr), vw)) begin
      c.n.li = 1'b0;
    end else begin
      vd = ii.lk_v[vw] && ii.lk_d[vw];
      c.n.ms[fi] = '0;
      c.n.ms[fi].valid = 1'b1;
      c.n.ms[fi].bypass = rr.lb;
      c.n.ms[fi].addr = rr.laddr;
      c.n.ms[fi].way = vw;
      c.n.ms[fi].size = rr.lsize;
      c.n.ms[fi].master = rr.lmaster;
      c.n.ms[fi].id = rr.lid;
      c.n.ms[fi].vdirty = vd;
      c.n.ms[fi].vdone = !vd;
      c.n.ms[fi].vaddr = vd ? addr_of(ii.lk_t[vw], set_of(rr.laddr)) : 32'd0;
      c.n.ms[fi].vdata = vd ? ii.lk_line[vw] : '0;
      c.n = lookup_done(c.n);
    end
    return c;
  endfunction

  function automatic ch_t f_s3(input st_t rr, input in_t ii, input ch_t cc);
    ch_t c;
    logic hit, inv;
    logic [WB-1:0] hw, iw;
    c = cc;
    hit = 1'b0;
    inv = 1'b0;
    hw = '0;
    iw = '0;
    if (rr.lv && rr.li && ii.lk_ok) begin
      for (int w = 0; w < WAYS; w++) begin
        if (!hit) begin
          if (!ii.lk_v[w] && !inv) begin
            inv = 1'b1;
            iw = WB'(w);
          end
          if (ii.lk_v[w] && ii.lk_t[w] == tag_of(rr.laddr)) begin
            hit = 1'b1;
            hw = WB'(w);
          end
        end
      end
      if (hit && rr.lw) c = hit_write(rr, ii, c, hw);
      else if (hit) c = hit_read(rr, ii, c, hw);
      else if (rr.lw) c = miss_write(rr, ii, c, inv, iw);
      else c = miss_read(rr, ii, c, inv, iw);
    end
    return c;
  endfunction

  always_comb begin
    co = f_s3(r, i, ci);
  end
endmodule
/* verilator lint_on UNUSEDSIGNAL */

`default_nettype wire
