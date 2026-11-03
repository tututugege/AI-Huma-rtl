`default_nettype none
// Ref: AXI_LLC.cpp  AXI_LLC::drive_write_path (stage 2) and try_launch_pending_write_lookup (also stage 5)
// Order inside the stage (C++ 1443-1772): write-response drain -> memory write response (victim write-back done,
// ctx commit) -> finished ctx
// -> response register -> read-victim queue head -> global victim write-back issue (early return) -> accept a write
// -> queue front into ctx -> launch lookup.
// lint: stage functions take whole state/input vectors; each stage reads only the subset it needs.
/* verilator lint_off UNUSEDSIGNAL */
module axi_llc_s2_wpath
  import axi_llc_pkg::*;
  import axi_llc_qry_pkg::*;
(
  input  st_t r,
  input  in_t i,
  input  ch_t ci,
  output ch_t co
);
  // C++ 1486-1601: memory write response -> end of the active victim write-back
  function automatic ch_t mem_write_resp(input st_t rr, input ch_t cc);
    ch_t c;
    logic [0:0] mm;
    logic [1:0] h;
    c = cc;
    c.n.vwb = '0;
    if (rr.vwb.forw) begin
      mm = rr.vwb.wm;
      c.n.wc[mm].vmdone = 1'b1;
      // try_commit_write_ctx_after_victim
      if (c.n.wc[mm].valid && c.n.wc[mm].cpend && !c.n.wc[mm].cdone && !tbl_busy(c)) begin
        c.wd = 1'b1; c.wm = 1'b1; c.wv = 1'b1; c.wr = 1'b1;
        c.tset = set_of(c.n.wc[mm].addr);
        c.tway = c.n.wc[mm].way;
        c.tdata = c.n.wc[mm].line;
        c.ttag = tag_of(c.n.wc[mm].addr);
        c.tdirty = 1'b1;
        c.trepl = next_way(c.n.wc[mm].way);
        c.n.wc[mm].cdone = 1'b1;
        c.n.wc[mm].cpend = 1'b0;
        c.n.wc[mm].vmdone = 1'b0;
      end
    end else if (rr.vwb.slot == SLOT_INV) begin
      h = rr.rvq.head;
      if (rr.rvq.cnt != 3'd0 && rr.rvq.ent[h].valid && rr.rvq.ent[h].addr == rr.vwb.addr) begin
        c.n.rvq.ent[h].valid = 1'b0;
        c.n.rvq.head = h + 2'd1;
        c.n.rvq.cnt = rr.rvq.cnt - 3'd1;
      end
    end else begin
      c.bad = 1'b1;  // victim response for an MSHR-owned slot: never observed
    end
    return c;
  endfunction

  // accept one write request into the per-master queue, then move queue fronts into free contexts
  function automatic ch_t accept_and_fill(input st_t rr, input in_t ii, input ch_t cc);
    ch_t c;
    logic found;
    logic [0:0] widx, mst, slot;
    c = cc;
    found = 1'b0;
    widx = 1'b0;
    for (int off = 0; off < NW; off++) begin
      mst = rr.rr_write + 1'(off);
      if (!found && ii.wr_v[mst] && rr.wq[mst].cnt < 2'(WQD) &&
          !victim_line_pending(rr, line_of(ii.wr_addr[mst]))) begin
        found = 1'b1;
        widx = mst;
      end
    end
    if (found) begin
      slot = rr.wq[widx].tail;
      c.wr_rdy[widx] = 1'b1;
      c.n.wq[widx].ent[slot].id = ii.wr_id[widx];
      c.n.wq[widx].ent[slot].size = ii.wr_size[widx];
      c.n.wq[widx].ent[slot].addr = ii.wr_addr[widx];
      c.n.wq[widx].ent[slot].data = ii.wr_data[widx];
      c.n.wq[widx].ent[slot].strb = ii.wr_strb[widx];
      c.n.wq[widx].tail = ~slot;
      c.n.wq[widx].cnt = rr.wq[widx].cnt + 2'd1;
      c.n.rr_write = ~widx;
      if (ii.wr_byp[widx]) c.bad = 1'b1;  // bypass writes: peripheral write master never active
    end
    for (int off = 0; off < NW; off++) begin
      mst = rr.rr_write + 1'(off);
      if (!c.n.wc[mst].valid && !c.n.wr[mst].valid && c.n.wq[mst].cnt != 2'd0 &&
          !victim_line_pending(c.n, line_of(c.n.wq[mst].ent[c.n.wq[mst].head].addr))) begin
        slot = c.n.wq[mst].head;
        c.n.wc[mst] = '0;
        c.n.wc[mst].valid = 1'b1;
        c.n.wc[mst].lpend = 1'b1;
        c.n.wc[mst].id = c.n.wq[mst].ent[slot].id;
        c.n.wc[mst].size = c.n.wq[mst].ent[slot].size;
        c.n.wc[mst].addr = c.n.wq[mst].ent[slot].addr;
        c.n.wc[mst].data = c.n.wq[mst].ent[slot].data;
        c.n.wc[mst].strb = c.n.wq[mst].ent[slot].strb;
        c.n.wq[mst].head = ~slot;
        c.n.wq[mst].cnt = c.n.wq[mst].cnt - 2'd1;
      end
    end
    return c;
  endfunction

  function automatic ch_t f_s2(input st_t rr, input in_t ii, input ch_t cc);
    ch_t c;
    c = cc;
    for (int m = 0; m < NW; m++) begin
      if (rr.wr[m].valid && ii.wr_ready[m]) c.n.wr[m] = '0;
    end
    if (ii.mwr_resp_v && rr.vwb.valid && rr.vwb.issued) c = mem_write_resp(rr, c);
    else if (ii.mwr_resp_v) c.bad = 1'b1;  // response without an active victim write: bypass write path, never observed
    for (int m = 0; m < NW; m++) begin
      if (c.n.wc[m].valid && !c.n.wr[m].valid && c.n.wc[m].cdone && !c.n.wc[m].cpend) begin
        c.n.wr[m].valid = 1'b1;
        c.n.wr[m].id = c.n.wc[m].id;
        c.n.wr[m].code = 2'd0;
        c.n.wr[m].line = line_of(c.n.wc[m].addr);
        c.n.wc[m] = '0;
      end
    end
    if (!c.n.vwb.valid && rr.rvq.cnt != 3'd0 && rr.rvq.ent[rr.rvq.head].valid) begin
      c.n.vwb.valid = 1'b1;
      c.n.vwb.issued = 1'b0;
      c.n.vwb.forw = 1'b0;
      c.n.vwb.wm = 1'b0;
      c.n.vwb.slot = SLOT_INV;
      c.n.vwb.addr = rr.rvq.ent[rr.rvq.head].addr;
      c.n.vwb.data = rr.rvq.ent[rr.rvq.head].data;
    end
    if (c.n.vwb.valid) begin
      if (!c.n.vwb.issued) begin
        c.mwr_v = 1'b1;
        c.mwr_addr = c.n.vwb.addr;
        c.mwr_data = c.n.vwb.data;
        if (ii.mwr_ready) c.n.vwb.issued = 1'b1;
      end
    end else begin
      c = accept_and_fill(rr, ii, c);
      c.n = launch_write_lookup(c.n);
    end
    return c;
  endfunction

  always_comb begin
    co = f_s2(r, i, ci);
  end
endmodule
/* verilator lint_on UNUSEDSIGNAL */

`default_nettype wire
