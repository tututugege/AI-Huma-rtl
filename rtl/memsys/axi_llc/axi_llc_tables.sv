`default_nettype none
// Ref: MemSubSystem/MemSubsystem.cpp  AxiLlcTableRuntime (data/meta/valid/repl tables, lookup_latency = 3)
// Hardware memories: synchronous write (end of tick), registered read index carried through two more stages,
// asynchronous read at the
// delivery tick.  A read requested in tick t returns the row as it is after the writes of tick t+2 (writes of t+3
// land after the read).
module axi_llc_tables
  import axi_llc_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic rd_req,
  input  logic [SB-1:0] rd_set,
  input  logic wd, wm, wv, wr,
  input  logic [SB-1:0] tset,
  input  logic [WB-1:0] tway,
  input  line_t tdata,
  input  logic [TAGW-1:0] ttag,
  input  logic tdirty,
  input  logic [WB-1:0] trepl,
  output logic lk_ok,
  output logic [WAYS-1:0] lk_v, lk_d,
  output logic [WAYS-1:0][TAGW-1:0] lk_t,
  output logic [WAYS-1:0][511:0] lk_line,
  output logic [WB-1:0] lk_repl
);
  line_t data_q [SETS][WAYS];
  logic [TAGW-1:0] tag_q [SETS][WAYS];
  logic [WAYS-1:0] dirty_q [SETS];
  logic [WAYS-1:0] valid_q [SETS];
  logic [WB-1:0] repl_q [SETS];

  // read index pipeline: p1 <- request (end of tick t), p2, p3 (valid during tick t+3)
  logic [2:0] pv_q;
  logic [SB-1:0] p1_q, p2_q, p3_q;

  always_ff @(posedge clk) begin
    if (!rst_n) pv_q <= '0;
    else        pv_q <= {pv_q[1:0], rd_req};
    p1_q <= rd_set;
    p2_q <= p1_q;
    p3_q <= p2_q;
  end

  // synchronous writes, one always_ff per array
  always_ff @(posedge clk) begin
    if (wd) data_q[tset][tway] <= tdata;
  end
  always_ff @(posedge clk) begin
    if (wm) tag_q[tset][tway] <= ttag;
  end
  always_ff @(posedge clk) begin
    if (wm) dirty_q[tset][tway] <= tdirty;
  end
  always_ff @(posedge clk) begin
    if (wv) valid_q[tset][tway] <= 1'b1;
  end
  always_ff @(posedge clk) begin
    if (wr) repl_q[tset] <= trepl;
  end

  // asynchronous read of the registered index
  assign lk_ok   = pv_q[2];
  assign lk_v    = valid_q[p3_q];
  assign lk_d    = dirty_q[p3_q];
  assign lk_repl = repl_q[p3_q];
  always_comb begin
    for (int w = 0; w < WAYS; w++) begin
      lk_t[w]    = tag_q[p3_q][w];
      lk_line[w] = data_q[p3_q][w];
    end
  end
endmodule

`default_nettype wire
