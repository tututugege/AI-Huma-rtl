// Ref: back-end/PreIduQueue.cpp  ftq_alloc / ftq_pop / ftq_recover / ftq_flush, comb_fire
`default_nettype none

// FTQ allocation pointer and occupancy. Entries are looked up by index only, so the head pointer of the reference
// model is not needed (nothing reads it): occupancy is tracked by `count` alone.
module pre_idu_ftq_ptr import ttg_cfg_pkg::*; import pre_idu_pkg::*; (
  input  logic                         clk,
  input  logic                         rst_n,
  input  logic                         alloc,
  input  logic                         flush,
  input  logic                         recover,          // branch mispredict: drop entries younger than recover_idx
  input  logic [FTQ_IDX_WIDTH-1:0]     recover_idx,
  input  logic [COMMIT_CNT_W-1:0]      pop_cnt,
  output logic [FTQ_IDX_WIDTH-1:0]     tail,             // index written by an allocation this cycle
  output logic [FTQ_COUNT_W-1:0]       count
);

  logic [FTQ_IDX_WIDTH-1:0] tail_q;
  logic [FTQ_IDX_WIDTH-1:0] tail_d;
  logic [FTQ_COUNT_W-1:0]   count_q;
  logic [FTQ_COUNT_W-1:0]   count_d;

  logic [FTQ_IDX_WIDTH-1:0] recover_tail;
  logic [FTQ_IDX_WIDTH-1:0] discarded;

  assign tail         = tail_q;
  assign count        = count_q;
  assign recover_tail = recover_idx + FTQ_IDX_WIDTH'(1);
  assign discarded    = tail_q - recover_tail;

  // Ref: ftq_flush > ftq_recover > (ftq_alloc, ftq_pop). On flush/recover no alloc happens in the reference model
  // (recover blocks `ready`) or its effect is wiped (flush); the pop is skipped.
  always_comb begin
    tail_d  = tail_q + FTQ_IDX_WIDTH'(alloc);
    count_d = count_q + FTQ_COUNT_W'(alloc) - FTQ_COUNT_W'(pop_cnt);
    if (flush) begin
      tail_d  = '0;
      count_d = '0;
    end else if (recover) begin
      tail_d  = recover_tail;
      count_d = count_q - FTQ_COUNT_W'(discarded);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tail_q  <= '0;
      count_q <= '0;
    end else begin
      tail_q  <= tail_d;
      count_q <= count_d;
    end
  end

`ifndef SYNTHESIS
  if ((FTQ_SIZE & (FTQ_SIZE - 1)) != 0) begin : g_pow2_check
    $error("FTQ_SIZE must be a power of 2");
  end
`endif

endmodule

`default_nettype wire
