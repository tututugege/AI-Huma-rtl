`default_nettype none
// Ref: MemSubSystem/MemSubsystem.cpp  AxiLlcTableRuntime (data/meta/valid/repl tables, lookup_latency = 3)
// Hardware memories: synchronous write (end of tick, one write port per array), registered read index carried
// through two more stages, asynchronous read at the delivery tick.  A read requested in tick t returns the row as
// it is after the writes of tick t+2 (writes of t+3 land after the read).  No array is reset: the valid bits of a
// set are cleared by a reset of the whole table only through `valid_q` writes, so a cold line never hits because
// its valid bit is written first (the valid array is the only one that must power up cleared).
module axi_llc_tables
  import axi_llc_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic rd_req,
  input  logic [SB-1:0] rd_set,
  input  tw_t tw,
  output logic lk_ok,
  output logic [WAYS-1:0] lk_v,
  output logic [WAYS-1:0] lk_d,
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

  // valid bits power up cleared (harness --x-initial 0 / FPGA init); everything else is written before it is read
  always_ff @(posedge clk) begin
    if (tw.line_en) data_q[tw.set][tw.way] <= tw.data;
  end
  always_ff @(posedge clk) begin
    if (tw.line_en) tag_q[tw.set][tw.way] <= tw.tag;
  end
  always_ff @(posedge clk) begin
    if (tw.line_en) dirty_q[tw.set][tw.way] <= tw.dirty;
  end
  always_ff @(posedge clk) begin
    if (tw.line_en) valid_q[tw.set][tw.way] <= 1'b1;
  end
  always_ff @(posedge clk) begin
    if (tw.repl_en) repl_q[tw.set] <= tw.repl;
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
