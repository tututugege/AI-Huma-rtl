`default_nettype none
// Ref: AXI_LLC.cpp  AXI_LLC::drive_read_responses (stage 1 of comb())
// Read-response slot per master: the fresh flag is dropped one tick after a response appears; a consumed response
// is replaced by the
// head of the per-master queue (C++ 1335-1357).  Reads the old registers only.
// lint: stage functions take whole state/input vectors; each stage reads only the subset it needs.
/* verilator lint_off UNUSEDSIGNAL */
module axi_llc_s1_rresp
  import axi_llc_pkg::*;
(
  input  st_t r,
  input  in_t i,
  input  ch_t ci,
  output ch_t co
);
  function automatic ch_t f_s1(input st_t rr, input in_t ii, input ch_t cc);
    ch_t c;
    logic h;
    c = cc;
    for (int m = 0; m < NR; m++) begin
      if (rr.rr[m].valid && rr.rr[m].fresh) begin
        c.n.rr[m].fresh = 1'b0;
      end else if (rr.rr[m].valid && ii.rd_ready[m]) begin
        if (rr.rr[m].qcnt != 2'd0) begin
          h = rr.rr[m].qhead;
          c.n.rr[m].valid = 1'b1;
          c.n.rr[m].fresh = 1'b1;
          c.n.rr[m].id = rr.rr[m].qid[h];
          c.n.rr[m].data = rr.rr[m].qdata[h];
          c.n.rr[m].qhead = ~h;
          c.n.rr[m].qcnt = rr.rr[m].qcnt - 2'd1;
        end else begin
          c.n.rr[m].valid = 1'b0;
          c.n.rr[m].fresh = 1'b0;
          c.n.rr[m].id = 4'd0;
        end
      end
    end
    return c;
  endfunction

  always_comb begin
    co = f_s1(r, i, ci);
  end
endmodule
/* verilator lint_on UNUSEDSIGNAL */

`default_nettype wire
