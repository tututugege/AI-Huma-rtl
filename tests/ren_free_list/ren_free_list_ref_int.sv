// Test reference copy (tests/ren_free_list): the module before the 2026-11-29 merge. Ref: back-end/Ren.cpp  class Ren  (free_list, free_head, free_head_commit, free_tail)
`default_nettype none

// 8-bank 1R1W circular free list of INT physical registers (PRF_NUM = 256 = 8 banks x 32 rows x 8-bit tag).
// Read: 8 consecutive entries from head_q -> 1 read per bank (32-to-1) + 8-way rotate.
// Write: up to 8 consecutive committed old_dest pregs at tail_q + rank -> at most 1 write per bank per cycle.
module ren_free_list_ref_int
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N  = DECODE_WIDTH,
  parameter int C  = COMMIT_WIDTH,
  parameter int CW = $clog2(C + 1)
) (
  input  logic                 clk,
  input  logic                 rst_n,
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: ring positions are log2(PRF_NUM) bits, tags may be wider
  input  preg_t                head_next,         // next head on normal fire (precomputed from alloc_req prefix)
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [C-1:0]         reclaim,
  input  logic [CW-1:0]        reclaim_rank [C],
  input  logic [CW-1:0]        reclaim_total,
  input  logic [CW-1:0]        alloc_commit_total,  // committing slots that took a register (head_commit advance)
  input  preg_t                reclaim_preg [C],  // old_dest_preg of committing slots
  input  logic                 flush,
  input  logic                 mispred,
  input  logic                 ckpt_hit,
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: a ring position is log2(PRF_NUM) bits, the tag may be wider
  input  preg_t                ckpt_head,         // sparse checkpoint head (a ring position)
  /* verilator lint_on UNUSEDSIGNAL */
  output preg_t                window [N],        // free_list[head + k]
  output preg_t                free_count,
  output preg_t                head
);

  localparam int NB = N;
  localparam int NL = PRF_NUM / NB;
  localparam int PW = $clog2(PRF_NUM);
  localparam int BW = $clog2(NB);
  localparam int LW = $clog2(NL);
  typedef logic [PW-1:0] ptr_t;

  // 8 banks x 32 rows x 8-bit INT preg tag (MSB is always 0 for INT domain)
  logic [PW-1:0] bank_q [NB][NL];
  ptr_t head_q, head_d, head_commit_q, head_commit_d, tail_q, tail_d;
  ptr_t write_ptr [C];

  assign head = preg_t'(head_q);

  ptr_t free_ptrs;
  assign free_ptrs  = tail_q - head_q;
  assign free_count = preg_t'(free_ptrs);

  // ---- read side: 8 consecutive entries from head_q (1 read per bank + 8-way rotate) ----
  logic [LW-1:0] base_line, next_line;
  logic [BW-1:0] base_bank;
  logic [NL-1:0] base_oh, next_oh;
  logic [NB-1:0] bb_oh;
  logic [PW-1:0] bank_rd [NB];

  assign base_line = head_q[PW-1:BW];
  assign next_line = base_line + LW'(1);
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
    ttg_onehot_mux #(.N(NL), .W(PW)) u_rd (.sel(rd_oh), .data(bank_q[b]), .out(bank_rd[b]));
  end

  for (genvar k = 0; k < NB; k++) begin : g_window
    logic [NB-1:0] slot_sel;
    logic [PW-1:0] slot_tag;
    for (genvar b = 0; b < NB; b++) begin : g_sel
      assign slot_sel[b] = bb_oh[(b - k + NB) % NB];
    end
    ttg_onehot_mux #(.N(NB), .W(PW)) u_rot (.sel(slot_sel), .data(bank_rd), .out(slot_tag));
    assign window[k] = preg_t'(slot_tag);
  end

  // ---- write side: committed old_dest pregs append at tail + rank -> at most 1 write per bank ----
  for (genvar k = 0; k < C; k++) begin : g_wptr
    assign write_ptr[k] = tail_q + ptr_t'(reclaim_rank[k]);
  end

  for (genvar b = 0; b < NB; b++) begin : g_wr_bank
    logic [C-1:0]  hit;
    logic [LW-1:0] lines [C];
    logic [PW-1:0] datas [C];
    logic          bank_we;
    logic [LW-1:0] bank_wline;
    logic [PW-1:0] bank_wdata;
    for (genvar k = 0; k < C; k++) begin : g_port
      assign hit[k]   = reclaim[k] & (write_ptr[k][BW-1:0] == BW'(b));
      assign lines[k] = write_ptr[k][PW-1:BW];
      assign datas[k] = reclaim_preg[k][PW-1:0];
    end
    assign bank_we = |hit;
    ttg_onehot_mux #(.N(C), .W(LW)) u_wline (.sel(hit), .data(lines), .out(bank_wline));
    ttg_onehot_mux #(.N(C), .W(PW)) u_wdata (.sel(hit), .data(datas), .out(bank_wdata));

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        for (int l = 0; l < NL; l++) begin
          bank_q[b][l] <= ((l * NB + b) < (PRF_NUM - RAT_NUM)) ? PW'(RAT_NUM + l * NB + b) : '0;
        end
      end else if (bank_we) begin
        bank_q[b][bank_wline] <= bank_wdata;
      end
    end
  end

  // ---- pointers ----
  always_comb begin
    head_commit_d = head_commit_q + ptr_t'(alloc_commit_total);
    tail_d        = tail_q + ptr_t'(reclaim_total);
    if (flush)         head_d = head_commit_d;
    else if (mispred)  head_d = ckpt_hit ? ptr_t'(ckpt_head) : head_commit_d;
    else               head_d = ptr_t'(head_next);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      head_q        <= '0;
      head_commit_q <= '0;
      tail_q        <= ptr_t'(PRF_NUM - RAT_NUM);
    end else begin
      head_q        <= head_d;
      head_commit_q <= head_commit_d;
      tail_q        <= tail_d;
    end
  end

  // lint sink (Verilator ignores unused_* names): upper bits of reclaim_preg are 0 for the INT domain
  logic unused_reclaim_hi;
  always_comb begin
    unused_reclaim_hi = 1'b0;
    for (int k = 0; k < C; k++) unused_reclaim_hi ^= ^reclaim_preg[k][PRF_IDX_WIDTH-1:PW];
  end

endmodule

`default_nettype wire
