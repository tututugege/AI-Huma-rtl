// Ref: front-end/fifo/{fetch_address_FIFO,instruction_FIFO,PTAB,front2bank_FIFO}.cpp  (same queue in all four)
`default_nettype none

// Parameterised 1-read / 1-write queue used by the four front-end FIFOs.
// One cycle, in this order (the C++ "read call then write call, accumulated" protocol collapses to exactly this):
//   clear (refetch)  ->  drop the youngest entry if drop_tail  ->  push wdata if wr_en  ->  pop the head if rd_valid.
// The read port shows the head as it was at the START of the cycle (a push this cycle is not visible; there is no
// write-through into an empty queue: that C++ path is never exercised, see docs/analysis/frontend-boundary.md 3.1).
// rd_valid = rd_en & ~clear & queue non-empty; rdata is only meaningful when rd_valid.
// full / empty are functions of the START-of-cycle size (they replace the 8 redundant C++ latches):
// full = size >= FULL_AT.
// Writing into a completely full queue (without clear) is illegal (the C++ model exit(1)s on overflow).
module front_fifo #(
  parameter int DEPTH   = 16,
  parameter int W       = 32,
  parameter int FULL_AT = DEPTH
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         clear,
  input  logic         rd_en,
  input  logic         wr_en,
  input  logic         drop_tail,     // remove the youngest entry (BPU override of the block behind it)
  input  logic [W-1:0] wdata,
  output logic         rd_valid,
  output logic [W-1:0] rdata,
  output logic         full,
  output logic         empty,
  output logic [$clog2(DEPTH + 1)-1:0] size     // START-of-cycle occupancy
);

  localparam int PTR_W = $clog2(DEPTH);
  localparam int CNT_W = $clog2(DEPTH + 1);

  logic [W-1:0]     mem_q [DEPTH];
  logic [PTR_W-1:0] rd_ptr_q;
  logic [PTR_W-1:0] rd_ptr_d;
  logic [PTR_W-1:0] wr_ptr_q;
  logic [PTR_W-1:0] wr_ptr_d;
  logic [CNT_W-1:0] count_q;
  logic [CNT_W-1:0] count_d;
  logic [CNT_W-1:0] count_after_clear;
  logic             drop_eff;

  assign empty = (count_q == '0);
  assign size  = count_q;
  assign full  = (count_q >= CNT_W'(FULL_AT));
  assign rdata = mem_q[rd_ptr_q];

  // Ref: *_FIFO_comb (do_read) and *_FIFO model seq_write (clear -> push -> pop)
  always_comb begin
    rd_valid          = rd_en && !clear && !empty;
    count_after_clear = clear ? '0 : count_q;
    drop_eff          = drop_tail && !clear && !empty;
    count_d           = count_after_clear - CNT_W'(drop_eff) + CNT_W'(wr_en) - CNT_W'(rd_valid);
    wr_ptr_d          = wr_ptr_q - PTR_W'(drop_eff) + PTR_W'(wr_en);
    // after a clear the queue is empty, so the read pointer meets the write pointer (a push lands on the head)
    rd_ptr_d          = clear ? wr_ptr_q : rd_ptr_q + PTR_W'(rd_valid);
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
    if (wr_en) mem_q[wr_ptr_q] <= wdata;
  end

`ifndef SYNTHESIS
  if ((DEPTH & (DEPTH - 1)) != 0) begin : g_pow2_check
    $error("front_fifo DEPTH must be a power of 2 (pointers wrap naturally)");
  end
  // overflow: the C++ model exits on a push into a full queue (after the clear)
  assert property (@(posedge clk) disable iff (!rst_n) !(wr_en && !clear && count_q == CNT_W'(DEPTH)));
`endif

endmodule

`default_nettype wire
