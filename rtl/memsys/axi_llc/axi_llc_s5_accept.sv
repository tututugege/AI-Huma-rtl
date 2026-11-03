`default_nettype none
// Ref: AXI_LLC.cpp  try_launch_pending_write_lookup (stage 5), accept_new_requests (stage 6), drive_lookup_request
// (stage 7)
// Stage 5: a write context starts its lookup if stage 3 freed the engine.  Stage 6: round-robin read master
// accepted when no hazard
// (pending write / victim / MSHR on the line, response slot busy).  Stage 7: the registered lookup issues its table
// read.
// lint: stage functions take whole state/input vectors; each stage reads only the subset it needs.
/* verilator lint_off UNUSEDSIGNAL */
module axi_llc_s5_accept
  import axi_llc_pkg::*;
  import axi_llc_qry_pkg::*;
(
  input  st_t r,
  input  in_t i,
  input  ch_t ci,
  output ch_t co
);
  function automatic ch_t accept_read(input st_t rr, input in_t ii, input ch_t cc);
    ch_t c;
    logic found, ok, wpend;
    logic [1:0] idx, sel;
    logic [2:0] d0, d1;
    c = cc;
    found = 1'b0;
    sel = '0;
    for (int off = 0; off < NR; off++) begin
      idx = c.n.rr_read + 2'(off);
      wpend = 1'b0;
      for (int w = 0; w < NW; w++) begin
        if (ii.wr_v[w] && !ii.wr_byp[w] && line_of(ii.wr_addr[w]) == line_of(ii.rd_addr[idx])) wpend = 1'b1;
      end
      ok = ii.rd_v[idx] && !rr.rr[idx].valid && !c.n.rr[idx].valid && !c.n.lv && !wpend &&
           !write_line_pending(c.n, line_of(ii.rd_addr[idx])) && !victim_line_pending(c.n, line_of(ii.rd_addr[idx])) &&
           !find_mshr_line(c.n, line_of(ii.rd_addr[idx]), d0) &&
           !(!ii.rd_byp[idx] && idx != 2'd1 && has_mshr_for_master(c.n, idx)) && find_free_mshr(c.n, d1);
      if (!found && ok) begin
        found = 1'b1;
        sel = idx;
      end
    end
    if (found) begin
      c.rd_rdy[sel] = 1'b1;
      c.n.rr_read = sel + 2'd1;
      c.n.lv = 1'b1;
      c.n.li = 1'b0;
      c.n.laddr = ii.rd_addr[sel];
      c.n.lsize = ii.rd_size[sel];
      c.n.lmaster = sel;
      c.n.lid = ii.rd_id[sel];
      c.n.lw = 1'b0;
      c.n.lb = ii.rd_byp[sel];
    end
    return c;
  endfunction

  function automatic ch_t lookup_request(input st_t rr, input ch_t cc);
    ch_t c;
    logic [2:0] d;
    c = cc;
    if (rr.lv && c.n.lv && !rr.li && !victim_line_pending(c.n, line_of(c.n.laddr)) && !tbl_busy(c) &&
        !find_mshr_line(c.n, line_of(c.n.laddr), d)) begin
      c.trd = 1'b1;
      c.trd_set = set_of(c.n.laddr);
      c.n.li = 1'b1;
    end
    return c;
  endfunction

  function automatic ch_t f_s5(input st_t rr, input in_t ii, input ch_t cc);
    ch_t c;
    c = cc;
    c.n = launch_write_lookup(c.n);
    c = accept_read(rr, ii, c);
    c = lookup_request(rr, c);
    return c;
  endfunction

  always_comb begin
    co = f_s5(r, i, ci);
  end
endmodule
/* verilator lint_on UNUSEDSIGNAL */

`default_nettype wire
