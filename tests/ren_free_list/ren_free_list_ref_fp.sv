// Test reference copy (tests/ren_free_list): the module before the 2026-11-29 merge. Ref: back-end/Ren.cpp  class Ren  (fp_free_list, fp_free_head, fp_free_head_commit, fp_free_tail; F/D)
`default_nettype none

// 8-bank 1R1W circular free list of FP physical registers (FPRF_NUM = 96 = 8 banks x 12 rows x 7-bit local tag).
// Stores 7-bit FP local tag (preg - FP_TAG_BASE) and adds FP_TAG_BASE on read.
module ren_free_list_ref_fp
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N  = DECODE_WIDTH,
  parameter int C  = COMMIT_WIDTH,
  parameter int CW = $clog2(C + 1)
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  fp_ptr_t              head_next,         // next head on normal fire (precomputed from alloc_req prefix)
  input  logic [C-1:0]         reclaim,
  input  logic [CW-1:0]        reclaim_rank [C],
  input  logic [CW-1:0]        reclaim_total,     // = head_commit advance (no move elimination in the FP domain)
  input  preg_t                reclaim_preg [C],  // old_dest_preg of committing slots
  input  logic                 flush,
  input  logic                 mispred,
  input  logic                 ckpt_hit,
  input  fp_ptr_t              ckpt_head,         // sparse FP checkpoint head
  output preg_t                window [N],        // free_list[head + k]
  output fp_ptr_t              free_count,
  output fp_ptr_t              head
);

  localparam int NB = N;
  localparam int NL = FPN / NB;          // 96 / 8 = 12 rows per bank
  localparam int BW = $clog2(NB);
  localparam int LW = $clog2(NL);
  localparam int TW = FP_PTR_W;          // 7-bit local FP tag (0..95)

  logic [TW-1:0] bank_q [NB][NL];
  fp_ptr_t head_q, head_d, head_commit_q, head_commit_d, tail_q, tail_d;
  fp_ptr_t write_ptr [C];

  assign head = head_q;
  assign free_count = (tail_q >= head_q) ? (tail_q - head_q) : fp_ptr_t'(tail_q + fp_ptr_t'(FPN) - head_q);

  // ---- read side: 8 consecutive entries from head_q (1 read per bank + 8-way rotate, line wraps mod NL) ----
  logic [LW-1:0] base_line, next_line;
  logic [BW-1:0] base_bank;
  logic [NL-1:0] base_oh, next_oh;
  logic [NB-1:0] bb_oh;
  logic [TW-1:0] bank_rd [NB];

  assign base_line = head_q[FP_PTR_W-1:BW];
  assign next_line = (base_line == LW'(NL - 1)) ? LW'(0) : (base_line + LW'(1));
  assign base_bank = head_q[BW-1:0];

  for (genvar l = 0; l < NL; l++) begin : g_line_dec
    assign base_oh[l] = (base_line == LW'(l));
    assign next_oh[l] = (next_line == LW'(l));
  end
  for (genvar b = 0; b < NB; b++) begin : g_bank_dec
    assign bb_oh[b] = (base_bank == BW'(b));
  end

  for (genvar b = 0; b < NB; b++) begin : g_rd_bank
    logic          use_next;
    logic [NL-1:0] rd_oh;
    if (b == NB - 1) begin : g_last_bank
      assign use_next = 1'b0;
    end else begin : g_other_bank
      assign use_next = (BW'(b) < base_bank);
    end
    assign rd_oh = use_next ? next_oh : base_oh;
    ttg_onehot_mux #(.N(NL), .W(TW)) u_rd (.sel(rd_oh), .data(bank_q[b]), .out(bank_rd[b]));
  end

  for (genvar k = 0; k < NB; k++) begin : g_window
    logic [NB-1:0] slot_sel;
    logic [TW-1:0] slot_tag;
    for (genvar b = 0; b < NB; b++) begin : g_sel
      assign slot_sel[b] = bb_oh[(b - k + NB) % NB];
    end
    ttg_onehot_mux #(.N(NB), .W(TW)) u_rot (.sel(slot_sel), .data(bank_rd), .out(slot_tag));
    assign window[k] = preg_t'(FP_TAG_BASE) + preg_t'(slot_tag);
  end

  // ---- write side: committed old_dest pregs append at tail + rank -> at most 1 write per bank ----
  for (genvar k = 0; k < C; k++) begin : g_wptr
    assign write_ptr[k] = fp_ptr_add(tail_q, fp_ptr_t'(reclaim_rank[k]));
  end

  for (genvar b = 0; b < NB; b++) begin : g_wr_bank
    logic [C-1:0]  hit;
    logic [LW-1:0] lines [C];
    logic [TW-1:0] datas [C];
    logic          bank_we;
    logic [LW-1:0] bank_wline;
    logic [TW-1:0] bank_wdata;
    for (genvar k = 0; k < C; k++) begin : g_port
      /* verilator lint_off UNUSEDSIGNAL */
      logic [PRF_IDX_WIDTH-1:0] local_tag;
      /* verilator lint_on UNUSEDSIGNAL */
      assign local_tag = reclaim_preg[k] - preg_t'(FP_TAG_BASE);
      assign hit[k]    = reclaim[k] & (write_ptr[k][BW-1:0] == BW'(b));
      assign lines[k]  = write_ptr[k][FP_PTR_W-1:BW];
      assign datas[k]  = local_tag[TW-1:0];
    end
    assign bank_we = |hit;
    ttg_onehot_mux #(.N(C), .W(LW)) u_wline (.sel(hit), .data(lines), .out(bank_wline));
    ttg_onehot_mux #(.N(C), .W(TW)) u_wdata (.sel(hit), .data(datas), .out(bank_wdata));

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        for (int l = 0; l < NL; l++) begin
          bank_q[b][l] <= ((l * NB + b) < (FPN - FP_ARF_NUM)) ? TW'(FP_ARF_NUM + l * NB + b) : '0;
        end
      end else if (bank_we) begin
        bank_q[b][bank_wline] <= bank_wdata;
      end
    end
  end

  // ---- pointers ----
  always_comb begin
    head_commit_d = fp_ptr_add(head_commit_q, fp_ptr_t'(reclaim_total));
    tail_d        = fp_ptr_add(tail_q, fp_ptr_t'(reclaim_total));
    if (flush)         head_d = head_commit_d;
    else if (mispred)  head_d = ckpt_hit ? ckpt_head : head_commit_d;
    else               head_d = head_next;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      head_q        <= '0;
      head_commit_q <= '0;
      tail_q        <= fp_ptr_t'(FPN - FP_ARF_NUM);
    end else begin
      head_q        <= head_d;
      head_commit_q <= head_commit_d;
      tail_q        <= tail_d;
    end
  end

endmodule

`default_nettype wire
