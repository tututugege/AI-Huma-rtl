// Ref: front-end/fifo/instruction_FIFO.cpp  instruction_FIFO_comb + model; front-end/front_fifo_ports.h  FrontFifo
`default_nettype none

// instruction_FIFO: queue of predecoded fetch groups (fused A+B + optional intact Block A fallback).
// One cycle, in this order: clear (refetch) -> push wr_entry if wr_en -> pop the head if rd_en.
// The read port shows the head as it was at the START of the cycle (a push this cycle is not visible);
// rd_entry is only meaningful when !empty. full / empty / size are functions of the START-of-cycle occupancy.
// Writing into a completely full queue (without refetch) is illegal (the C++ model exit(1)s on overflow).
module inst_fifo import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             refetch,
  input  logic             rd_en,
  input  logic             wr_en,
  input  inst_fifo_entry_t wr_entry,
  output inst_fifo_entry_t rd_entry,
  output logic             full,
  output logic             empty,
  output logic [$clog2(INST_FIFO_DEPTH + 1)-1:0] size
);

  localparam int DEPTH = INST_FIFO_DEPTH;
  localparam int PTR_W = $clog2(DEPTH);
  localparam int CNT_W = $clog2(DEPTH + 1);

  inst_fifo_entry_t mem_q [DEPTH];
  logic [PTR_W-1:0] rd_ptr_q;
  logic [PTR_W-1:0] rd_ptr_d;
  logic [PTR_W-1:0] wr_ptr_q;
  logic [PTR_W-1:0] wr_ptr_d;
  logic [CNT_W-1:0] count_q;
  logic [CNT_W-1:0] count_d;
  logic             pop;

  assign empty    = (count_q == '0);
  assign size     = count_q;
  assign full     = (count_q >= CNT_W'(DEPTH));
  assign rd_entry = mem_q[rd_ptr_q];

  // Ref: *_FIFO_comb (do_read) and *_FIFO model seq_write (clear -> push -> pop)
  always_comb begin
    pop      = rd_en && !refetch && !empty;
    count_d  = (refetch ? '0 : count_q) + CNT_W'(wr_en) - CNT_W'(pop);
    wr_ptr_d = wr_ptr_q + PTR_W'(wr_en);
    // after a clear the queue is empty, so the read pointer meets the write pointer (a push lands on the head)
    rd_ptr_d = refetch ? wr_ptr_q : rd_ptr_q + PTR_W'(pop);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_ptr_q <= '0;
      wr_ptr_q <= '0;
      count_q  <= '0;
    end else begin
      rd_ptr_q <= rd_ptr_d;
      wr_ptr_q <= wr_ptr_d;
      count_q  <= count_d;
    end
  end

  // Storage: written like a memory (no reset: only entries between rd_ptr and wr_ptr are ever read as valid data)
  always_ff @(posedge clk) begin
    if (wr_en) mem_q[wr_ptr_q] <= wr_entry;
  end

`ifndef SYNTHESIS
  if ((DEPTH & (DEPTH - 1)) != 0) begin : g_pow2_check
    $error("inst_fifo INST_FIFO_DEPTH must be a power of 2 (pointers wrap naturally)");
  end
  // overflow: the C++ model exits on a push into a full queue (after the clear)
  assert property (@(posedge clk) disable iff (!rst_n) !(wr_en && !refetch && count_q == CNT_W'(DEPTH)));
`endif

endmodule

`default_nettype wire
