// Ref: back-end/PreIduQueue.cpp  Unified FTQ-64 5-pointer ring (comm_ptr <= pd_ptr <= {ifu_ptr, s2_ptr} <= bpu_ptr)
`default_nettype none

module ftq_ptr import ttg_cfg_pkg::*; import ftq_ibuf_pkg::*; (
  input  logic                         clk,
  input  logic                         rst_n,
  input  logic                         flush,
  input  logic                         recover,          // branch mispredict: drop entries younger than recover_idx
  input  logic [FTQ_IDX_WIDTH-1:0]     recover_idx,
  // Frontend S0 / IFU / S2 / PD pointer operations
  input  logic                         s0_wr_en,
  input  logic [1:0]                   s0_drop_tail_n,
  input  logic                         s0_ifu_pop,
  input  logic                         s2_wr_en,
  input  logic                         pd_fire,
  input  logic                         pd_flush,
  input  logic                         pd_empty_blk,
  // ROB commit retire
  input  logic [COMMIT_WIDTH-1:0]      commit_valid,
  input  logic [COMMIT_WIDTH-1:0]      commit_is_last,
  input  logic [FTQ_IDX_WIDTH-1:0]     commit_ftq_idx [COMMIT_WIDTH],
  // Registered pointers & next_comm_ptr (for ftq_meta strict sync SRAM pre-launch)
  output logic [FTQ_IDX_WIDTH-1:0]     comm_ptr,
  output logic [FTQ_IDX_WIDTH-1:0]     next_comm_ptr,
  output logic [FTQ_IDX_WIDTH-1:0]     pd_ptr,
  output logic [FTQ_IDX_WIDTH-1:0]     s2_ptr,
  output logic [FTQ_IDX_WIDTH-1:0]     ifu_ptr,
  output logic [FTQ_IDX_WIDTH-1:0]     bpu_ptr,
  output logic [FTQ_IDX_WIDTH-1:0]     s0_wr_idx,
  // Registered frontend flow-control flags
  output logic                         ftq_full,
  output logic                         fa_empty,
  output logic [1:0]                   fa_cnt_sat,
  output logic                         s2_empty
);

  localparam int W = FTQ_IDX_WIDTH;

  logic [W-1:0] comm_ptr_q, comm_ptr_d;
  logic [W-1:0] pd_ptr_q,   pd_ptr_d;
  logic [W-1:0] s2_ptr_q,   s2_ptr_d;
  logic [W-1:0] ifu_ptr_q,  ifu_ptr_d;
  logic [W-1:0] bpu_ptr_q,  bpu_ptr_d;
  logic [FTQ_SIZE-1:0] empty_blk_q, empty_blk_d;

  logic [W-1:0] total_cnt, fa_cnt;
  assign total_cnt  = bpu_ptr_q - comm_ptr_q;
  assign fa_cnt     = bpu_ptr_q - ifu_ptr_q;
  assign ftq_full   = (total_cnt >= W'(FTQ_SIZE - 1)) || (fa_cnt >= W'(15));
  assign fa_empty   = (ifu_ptr_q == bpu_ptr_q);
  assign fa_cnt_sat = (fa_cnt >= W'(3)) ? 2'd3 : fa_cnt[1:0];
  assign s2_empty   = (pd_ptr_q == s2_ptr_q);

  assign comm_ptr      = comm_ptr_q;
  assign next_comm_ptr = comm_ptr_d;
  assign pd_ptr        = pd_ptr_q;
  assign s2_ptr        = s2_ptr_q;
  assign ifu_ptr       = ifu_ptr_q;
  assign bpu_ptr       = bpu_ptr_q;

  logic [1:0]   drop_n_eff;
  logic [W-1:0] bpu_after_drop;
  assign drop_n_eff     = (W'(s0_drop_tail_n) < fa_cnt) ? s0_drop_tail_n : fa_cnt[1:0];
  assign bpu_after_drop = bpu_ptr_q - W'(drop_n_eff);
  assign s0_wr_idx      = bpu_after_drop;

  always_comb begin
    logic [W-1:0]        recover_tail, disc_rec, bpu_after_s0, disc_pd;
    logic                last_cm_v, skip_empty;
    logic [W-1:0]        last_cm_idx, comm_step1, cm_span;
    logic [FTQ_SIZE-1:0] eb_mid;

    comm_ptr_d   = comm_ptr_q;
    pd_ptr_d     = pd_ptr_q;
    s2_ptr_d     = s2_ptr_q;
    ifu_ptr_d    = ifu_ptr_q;
    bpu_ptr_d    = bpu_ptr_q;
    eb_mid       = empty_blk_q;
    empty_blk_d  = empty_blk_q;
    bpu_after_s0 = '0;
    disc_pd      = '0;
    last_cm_v    = 1'b0;
    last_cm_idx  = '0;
    comm_step1   = '0;
    cm_span      = '0;
    skip_empty   = 1'b0;

    recover_tail = recover_idx + W'(1);
    disc_rec     = bpu_ptr_q - recover_tail;

    if (flush) begin
      comm_ptr_d   = '0;
      pd_ptr_d     = '0;
      s2_ptr_d     = '0;
      ifu_ptr_d    = '0;
      bpu_ptr_d    = '0;
      empty_blk_d  = '0;
    end else if (recover) begin
      comm_ptr_d   = comm_ptr_q;
      pd_ptr_d     = recover_tail;
      s2_ptr_d     = recover_tail;
      ifu_ptr_d    = recover_tail;
      bpu_ptr_d    = recover_tail;
      for (int i = 0; i < FTQ_SIZE; i++) begin
        if ((W'(i) - recover_tail) < disc_rec) eb_mid[i] = 1'b0;
      end
      empty_blk_d = eb_mid;
    end else begin
      // 1. S0 allocate / S3-override drop_tail_n (0..2) / IFU issue pop
      if (drop_n_eff >= 2'd1) eb_mid[bpu_ptr_q - W'(1)] = 1'b0;
      if (drop_n_eff >= 2'd2) eb_mid[bpu_ptr_q - W'(2)] = 1'b0;
      bpu_after_s0 = bpu_after_drop + W'(s0_wr_en);
      bpu_ptr_d    = bpu_after_s0;
      if (s0_wr_en) begin
        eb_mid[bpu_after_drop] = 1'b0;
      end
      ifu_ptr_d = ifu_ptr_q + W'(s0_ifu_pop);

      // 2. BPU S2/S3 fill
      s2_ptr_d = s2_ptr_q + W'(s2_wr_en);

      // 3. Predecode in-place update (+ frontend-only rollback on pd_flush)
      pd_ptr_d = pd_ptr_q + W'(pd_fire);
      if (pd_fire) begin
        eb_mid[pd_ptr_q] = pd_empty_blk;
        if (pd_flush) begin
          disc_pd   = bpu_after_s0 - pd_ptr_d;
          for (int i = 0; i < FTQ_SIZE; i++) begin
            if ((W'(i) - pd_ptr_d) < disc_pd) eb_mid[i] = 1'b0;
          end
          bpu_ptr_d = pd_ptr_d;
          ifu_ptr_d = pd_ptr_d;
          s2_ptr_d  = pd_ptr_d;
        end
      end

      // 4. ROB commit retire (jump past highest committed ftq_is_last + skip at most 1 leading empty_blk)
      last_cm_v   = 1'b0;
      last_cm_idx = comm_ptr_q;
      for (int k = 0; k < COMMIT_WIDTH; k++) begin
        if (commit_valid[k] && commit_is_last[k]) begin
          last_cm_v   = 1'b1;
          last_cm_idx = commit_ftq_idx[k];
        end
      end
      comm_step1 = last_cm_v ? (last_cm_idx + W'(1)) : comm_ptr_q;
      cm_span    = comm_step1 - comm_ptr_q;
      for (int i = 0; i < FTQ_SIZE; i++) begin
        if ((W'(i) - comm_ptr_q) < cm_span) eb_mid[i] = 1'b0;
      end
      skip_empty = (comm_step1 != pd_ptr_d) && eb_mid[comm_step1];
      if (skip_empty) eb_mid[comm_step1] = 1'b0;
      comm_ptr_d  = comm_step1 + W'(skip_empty);
      empty_blk_d = eb_mid;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      comm_ptr_q   <= '0;
      pd_ptr_q     <= '0;
      s2_ptr_q     <= '0;
      ifu_ptr_q    <= '0;
      bpu_ptr_q    <= '0;
      empty_blk_q  <= '0;
    end else begin
      comm_ptr_q   <= comm_ptr_d;
      pd_ptr_q     <= pd_ptr_d;
      s2_ptr_q     <= s2_ptr_d;
      ifu_ptr_q    <= ifu_ptr_d;
      bpu_ptr_q    <= bpu_ptr_d;
      empty_blk_q  <= empty_blk_d;
    end
  end

`ifndef SYNTHESIS
  if ((FTQ_SIZE & (FTQ_SIZE - 1)) != 0) begin : g_pow2_check
    $error("FTQ_SIZE must be a power of 2");
  end
  assert property (@(posedge clk) disable iff (!rst_n)
    !(!flush && !recover && s0_wr_en && (total_cnt >= W'(FTQ_SIZE - 1))));
  assert property (@(posedge clk) disable iff (!rst_n)
    !(!flush && !recover && (comm_ptr_d != pd_ptr_d) && empty_blk_d[comm_ptr_d]));
`endif

endmodule

`default_nettype wire
