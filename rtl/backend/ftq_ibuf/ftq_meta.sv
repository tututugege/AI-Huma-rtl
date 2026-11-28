// Ref: back-end/PreIduQueue.cpp  ftq_train_meta_fifo[] (8-bank strict 1-cycle sync 1R1W SRAM, pre-launched on next_comm_ptr)
`default_nettype none

// FTQ training-metadata storage: 8 x (8 x 74b) strict 1-cycle synchronous 1R1W SRAM (`ttg_sram_1r1w`, write-first).
// Written once at BPU S2 (s2_ptr); pre-launched every cycle for the 8-bank commit window [next_comm_ptr .. next_comm_ptr+7].
module ftq_meta import ttg_cfg_pkg::*; import ftq_ibuf_pkg::*; (
  input  logic                        clk,
  input  logic                        rst_n,   // SRAM sweep (ttg_sram_1r1w INIT_SWEEP)
  input  logic                        wr_en,
  input  logic [FTQ_IDX_WIDTH-1:0]    wr_idx,
  input  logic [BLK_ID_W-1:0]         wr_blk_id,
  input  ftq_meta_t                   wr_meta [BACKEND_FETCH_WIDTH],
  input  logic [FTQ_IDX_WIDTH-1:0]    next_comm_ptr,
  input  logic [FTQ_IDX_WIDTH-1:0]    rd_idx [COMMIT_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0] rd_offset [COMMIT_WIDTH],
  output ftq_meta_t                   rd_meta [COMMIT_WIDTH],
  output logic [BLK_ID_W-1:0]         rd_blk_id [COMMIT_WIDTH]
);

  localparam int NB = 8;
  localparam int NL = FTQ_SIZE / NB;
  localparam int BW = $clog2(NB);
  localparam int LW = $clog2(NL);
  localparam int EW = $bits(ftq_meta_entry_t);

  ftq_meta_entry_t wr_entry;
  always_comb begin
    wr_entry.blk_id = wr_blk_id;
    for (int s = 0; s < BACKEND_FETCH_WIDTH; s++) wr_entry.slots[s] = wr_meta[s];
  end

  logic [EW-1:0]   bank_rd [NB];
  ftq_meta_entry_t win     [NB];

  // 8 x (8 x 74b) strict sync 1R1W SRAM pre-launched from next_comm_ptr
  for (genvar b = 0; b < NB; b++) begin : g_bank
    logic [LW-1:0] raddr;
    logic          bank_we;
    if (b == NB - 1) begin : g_last
      assign raddr = next_comm_ptr[FTQ_IDX_WIDTH-1:BW];
    end else begin : g_wrap
      assign raddr = (BW'(b) < next_comm_ptr[BW-1:0])
                     ? (next_comm_ptr[FTQ_IDX_WIDTH-1:BW] + LW'(1))
                     :  next_comm_ptr[FTQ_IDX_WIDTH-1:BW];
    end
    assign bank_we = wr_en && (wr_idx[BW-1:0] == BW'(b));

    ttg_sram_1r1w #(
      .DEPTH      (NL),
      .WIDTH      (EW),
      .MASK_W     (1),
      .TAG        ("FTQ_META")
    ) u_sram (
      .clk  (clk), .rst_n(rst_n),
      .re   (1'b1),
      .raddr(raddr),
      .rdata(bank_rd[b]),
      .we   (bank_we),
      .waddr(wr_idx[FTQ_IDX_WIDTH-1:BW]),
      .wdata(EW'(wr_entry)),
      .wmask(1'b1)
    );
    assign win[b] = ftq_meta_entry_t'(bank_rd[b]);
  end

  // Ref: comb_commit_info (8-bank commit window guaranteed by Rob 8-bank guard)
  always_comb begin
    for (int p = 0; p < COMMIT_WIDTH; p++) begin
      ftq_meta_entry_t e;
      e            = win[rd_idx[p][BW-1:0]];
      rd_meta[p]   = e.slots[rd_offset[p]];
      rd_blk_id[p] = e.blk_id;
    end
  end

endmodule

`default_nettype wire
