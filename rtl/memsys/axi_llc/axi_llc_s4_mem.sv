`default_nettype none
// Ref: AXI_LLC.cpp  AXI_LLC::drive_mem_read_path (stage 4, C++ 2696-3016), live paths only
// (a) memory read response -> MSHR refill data (bypass entries answer directly); (b) pick the MSHR whose memory
// read is issued;
// (c) pick the oldest-slot MSHR with refill data: park a dirty victim (global write-back slot or queue), write the
// refill into the tables
//     (tick 1: refill_committed), then answer the master and free the MSHR (tick 2).
// lint: stage functions take whole state/input vectors; each stage reads only the subset it needs.
/* verilator lint_off UNUSEDSIGNAL */
module axi_llc_s4_mem
  import axi_llc_pkg::*;
  import axi_llc_qry_pkg::*;
(
  input  st_t r,
  input  in_t i,
  input  ch_t ci,
  output ch_t co
);
  // (a)
  function automatic ch_t mem_read_resp(input st_t rr, input in_t ii, input ch_t cc);
    ch_t c;
    logic done, hit;
    c = cc;
    hit = 1'b0;
    for (int s = 0; s < NMSHR; s++) begin
      if (!ii.mrr_id[3] && ii.mrr_id[2:0] == 3'(s) && rr.ms[s].valid) begin
        hit = 1'b1;
        done = 1'b0;
        if (rr.ms[s].bypass) done = enq_resp_ok(c.n, rr.ms[s].master);
        if (done) begin
          c.n = enq_resp_apply(c.n, rr.ms[s].master, rr.ms[s].id, ii.mrr_data);
          c.n.ms[s] = '0;
        end else begin
          c.n.ms[s].rvalid = 1'b1;
          c.n.ms[s].rdata = ii.mrr_data;
          c.n.ms[s].rcomm = c.n.ms[s].bypass;
        end
      end
    end
    if (!hit) c.bad = 1'b1;  // response for an unknown slot: never observed
    return c;
  endfunction

  // (b)
  function automatic ch_t mem_read_issue(input st_t rr, input in_t ii, input ch_t cc);
    ch_t c;
    logic found, direct;
    logic [2:0] sel;
    mshr_t e;
    c = cc;
    found = 1'b0;
    direct = 1'b0;
    sel = '0;
    for (int s = 0; s < NMSHR; s++) begin
      if (!found && rr.ms[s].valid && !rr.ms[s].mem_issued) begin
        found = 1'b1;
        sel = 3'(s);
      end
    end
    for (int s = 0; s < NMSHR; s++) begin  // CONFIG_AXI_LLC_BYPASS_DIRECT_ISSUE: bypass entry allocated this very tick
      if (!found && c.n.ms[s].valid && c.n.ms[s].bypass && !c.n.ms[s].mem_issued && !c.n.ms[s].rvalid &&
          !rr.ms[s].valid) begin
        found = 1'b1;
        direct = 1'b1;
        sel = 3'(s);
      end
    end
    if (found) begin
      e = direct ? c.n.ms[sel] : rr.ms[sel];
      c.mrd_v = 1'b1;
      c.mrd_addr = e.bypass ? e.addr : line_of(e.addr);
      c.mrd_size = e.bypass ? e.size : 8'd63;
      c.mrd_id = {1'b0, sel};
      if (ii.mrd_ready) c.n.ms[sel].mem_issued = 1'b1;
    end
    return c;
  endfunction

  // (c) dirty-victim snapshot must be parked before the refill overwrites the way (global write-back slot or queue)
  function automatic logic park_needed(input st_t rr, input st_t nn, input mshr_t e, input logic [2:0] cs);
    logic in_slot;
    in_slot = (nn.vwb.valid && !nn.vwb.forw && nn.vwb.addr == e.vaddr && nn.vwb.slot == {1'b0, cs}) ||
              victim_snapshot_present(nn, e.vaddr);
    return e.vdirty && !e.vdone && !victim_waits_write(rr, e.vaddr) && !in_slot;
  endfunction

  function automatic logic park_ok(input st_t rr, input st_t nn, input mshr_t e, input logic [2:0] cs);
    logic ok;
    ok = 1'b1;
    if (e.vdirty && !e.vdone) begin
      if (victim_waits_write(rr, e.vaddr)) ok = 1'b0;
      else if (park_needed(rr, nn, e, cs) && nn.vwb.valid) ok = enq_victim_ok(nn, {1'b0, cs}, e.vaddr);
    end
    return ok;
  endfunction

  function automatic st_t park_apply(input st_t rr, input st_t nn, input mshr_t e, input logic [2:0] cs);
    st_t o;
    o = nn;
    if (park_needed(rr, nn, e, cs)) begin
      if (!nn.vwb.valid) begin
        o.vwb.valid = 1'b1;
        o.vwb.issued = 1'b0;
        o.vwb.forw = 1'b0;
        o.vwb.wm = 1'b0;
        o.vwb.slot = {1'b0, cs};
        o.vwb.addr = e.vaddr;
        o.vwb.data = e.vdata;
      end else begin
        o = enq_victim_apply(nn, {1'b0, cs}, e.vaddr, e.vdata);
      end
    end
    return o;
  endfunction

  function automatic ch_t refill_commit(input st_t rr, input ch_t cc);
    ch_t c;
    logic found, ok;
    logic [2:0] cs;
    mshr_t e;
    c = cc;
    found = 1'b0;
    cs = '0;
    for (int s = 0; s < NMSHR; s++) begin
      if (!found && rr.ms[s].valid && rr.ms[s].rvalid) begin
        found = 1'b1;
        cs = 3'(s);
      end
    end
    if (found) begin
      e = c.n.ms[cs];
      if (!e.rcomm && !e.bypass) begin
        ok = park_ok(rr, c.n, e, cs);
        if (ok) c.n = park_apply(rr, c.n, e, cs);
        if (ok && !tbl_busy(c)) begin
          c.wd = 1'b1; c.wm = 1'b1; c.wv = 1'b1; c.wr = 1'b1;
          c.tset = set_of(e.addr);
          c.tway = e.way;
          c.tdata = e.rdata;
          c.ttag = tag_of(e.addr);
          c.tdirty = 1'b0;
          c.trepl = next_way(e.way);
          c.n.ms[cs].rcomm = 1'b1;
        end
      end else if (enq_resp_ok(c.n, e.master)) begin
        c.n = enq_resp_apply(c.n, e.master, e.id, e.bypass ? e.rdata : resp_of(e.addr, e.rdata));
        if (c.n.vwb.valid && !c.n.vwb.forw && c.n.vwb.slot == {1'b0, cs}) c.n.vwb.slot = SLOT_INV;
        c.n.ms[cs] = '0;
      end
    end
    return c;
  endfunction

  function automatic ch_t f_s4(input st_t rr, input in_t ii, input ch_t cc);
    ch_t c;
    c = cc;
    if (ii.mrr_v) c = mem_read_resp(rr, ii, c);
    c = mem_read_issue(rr, ii, c);
    c = refill_commit(rr, c);
    return c;
  endfunction

  always_comb begin
    co = f_s4(r, i, ci);
  end
endmodule
/* verilator lint_on UNUSEDSIGNAL */

`default_nettype wire
