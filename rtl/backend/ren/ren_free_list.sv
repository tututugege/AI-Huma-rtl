// Ref: back-end/Ren.cpp  class Ren  (free_list, free_head, free_head_commit, free_tail; F/D: the fp_* copies)
`default_nettype none

// 8-bank 1R1W circular free list of physical registers, one instance per register domain:
//   INT (defaults): NUM = PRF_NUM = 256 = 8 banks x 32 rows, ring positions wrap at 2^8 (power of two),
//                   ports head_next / ckpt_head / head / free_count are preg_t wide (PORT_W = PRF_IDX_WIDTH);
//   FP  (ren_fp):   NUM = FPRF_NUM = 96 = 8 banks x 12 rows, positions wrap mod 96, PORT_W = FP_PTR_W.
// The banks hold the local tag (preg - TAG_BASE); the read side adds TAG_BASE back (INT: TAG_BASE = 0).
// Read: 8 consecutive entries from head_q -> 1 read per bank (NL-to-1) + 8-way rotate.
// Write: up to 8 consecutive committed old_dest pregs at tail_q + rank -> at most 1 write per bank per cycle.
module ren_free_list
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N        = DECODE_WIDTH,
  parameter int C        = COMMIT_WIDTH,
  parameter int CW       = $clog2(C + 1),
  parameter int NUM      = PRF_NUM,          // ring slots = registers of the domain
  parameter int RESV     = RAT_NUM,          // registers held by the architectural RAT at reset (not in the list)
  parameter int TAG_BASE = 0,                // first preg tag of the domain (FP: FP_TAG_BASE)
  parameter int PORT_W   = PRF_IDX_WIDTH     // width of the ring-position ports (>= log2(NUM))
) (
  input  logic                 clk,
  input  logic                 rst_n,
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: ring positions are log2(NUM) bits, the INT ports are preg_t wide
  input  logic [PORT_W-1:0]    head_next,         // next head on normal fire (precomputed from alloc_req prefix)
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [C-1:0]         reclaim,
  input  logic [CW-1:0]        reclaim_rank [C],
  input  logic [CW-1:0]        reclaim_total,
  input  logic [CW-1:0]        alloc_commit_total,  // committing slots that took a register (head_commit advance)
  input  preg_t                reclaim_preg [C],  // old_dest_preg of committing slots
  input  logic                 flush,
  input  logic                 mispred,
  input  logic                 ckpt_hit,
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: as head_next
  input  logic [PORT_W-1:0]    ckpt_head,         // sparse checkpoint head (a ring position)
  /* verilator lint_on UNUSEDSIGNAL */
  output preg_t                window [N],        // free_list[head + k] (full preg tags)
  output logic [PORT_W-1:0]    free_count,
  output logic [PORT_W-1:0]    head
);

  localparam int NB   = N;
  localparam int NL   = NUM / NB;
  localparam int PW   = $clog2(NUM);           // ring position = stored local tag width
  localparam int BW   = $clog2(NB);
  localparam int LW   = $clog2(NL);
  localparam bit POW2 = (NUM == (1 << PW));    // the ring wraps for free at 2^PW
  typedef logic [PW-1:0] ptr_t;

  // ring position p + n (n < NUM): free wrap for a power of two, else mod NUM (ren_pkg::fp_ptr_add for the FP ring)
  function automatic ptr_t ring_add(input ptr_t p, input ptr_t n);
    logic [PW:0] sum;
    sum = {1'b0, p} + {1'b0, n};
    if (POW2) return sum[PW-1:0];
    return (sum >= (PW+1)'(NUM)) ? ptr_t'(sum - (PW+1)'(NUM)) : ptr_t'(sum);
  endfunction

  logic [PW-1:0] bank_q [NB][NL];
  ptr_t head_q, head_d, head_commit_q, head_commit_d, tail_q, tail_d;
  ptr_t write_ptr [C];
  ptr_t free_ptrs;

  assign head = PORT_W'(head_q);
  if (POW2) begin : g_cnt_pow2
    assign free_ptrs = tail_q - head_q;
  end else begin : g_cnt_mod
    assign free_ptrs = (tail_q >= head_q) ? (tail_q - head_q) : ptr_t'(tail_q + ptr_t'(NUM) - head_q);
  end
  assign free_count = PORT_W'(free_ptrs);

  // ---- read side: 8 consecutive entries from head_q (1 read per bank + 8-way rotate, line wraps mod NL) ----
  logic [LW-1:0] base_line, next_line;
  logic [BW-1:0] base_bank;
  logic [NL-1:0] base_oh, next_oh;
  logic [NB-1:0] bb_oh;
  logic [PW-1:0] bank_rd [NB];

  assign base_line = head_q[PW-1:BW];
  if (POW2) begin : g_line_pow2
    assign next_line = base_line + LW'(1);
  end else begin : g_line_mod
    assign next_line = (base_line == LW'(NL - 1)) ? LW'(0) : (base_line + LW'(1));
  end
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
    assign window[k] = preg_t'(TAG_BASE) + preg_t'(slot_tag);
  end

  // ---- write side: committed old_dest pregs append at tail + rank -> at most 1 write per bank ----
  for (genvar k = 0; k < C; k++) begin : g_wptr
    assign write_ptr[k] = ring_add(tail_q, ptr_t'(reclaim_rank[k]));
  end

  for (genvar b = 0; b < NB; b++) begin : g_wr_bank
    logic [C-1:0]  hit;
    logic [LW-1:0] lines [C];
    logic [PW-1:0] datas [C];
    logic          bank_we;
    logic [LW-1:0] bank_wline;
    logic [PW-1:0] bank_wdata;
    for (genvar k = 0; k < C; k++) begin : g_port
      /* verilator lint_off UNUSEDSIGNAL */   // waiver: the bits above the local tag are 0 inside the domain
      preg_t local_tag;
      /* verilator lint_on UNUSEDSIGNAL */
      assign local_tag = reclaim_preg[k] - preg_t'(TAG_BASE);
      assign hit[k]    = reclaim[k] & (write_ptr[k][BW-1:0] == BW'(b));
      assign lines[k]  = write_ptr[k][PW-1:BW];
      assign datas[k]  = local_tag[PW-1:0];
    end
    assign bank_we = |hit;
    ttg_onehot_mux #(.N(C), .W(LW)) u_wline (.sel(hit), .data(lines), .out(bank_wline));
    ttg_onehot_mux #(.N(C), .W(PW)) u_wdata (.sel(hit), .data(datas), .out(bank_wdata));

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        for (int l = 0; l < NL; l++) begin
          bank_q[b][l] <= ((l * NB + b) < (NUM - RESV)) ? PW'(RESV + l * NB + b) : '0;
        end
      end else if (bank_we) begin
        bank_q[b][bank_wline] <= bank_wdata;
      end
    end
  end

  // ---- pointers ----
  always_comb begin
    head_commit_d = ring_add(head_commit_q, ptr_t'(alloc_commit_total));
    tail_d        = ring_add(tail_q, ptr_t'(reclaim_total));
    if (flush)         head_d = head_commit_d;
    else if (mispred)  head_d = ckpt_hit ? ptr_t'(ckpt_head) : head_commit_d;
    else               head_d = ptr_t'(head_next);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      head_q        <= '0;
      head_commit_q <= '0;
      tail_q        <= ptr_t'(NUM - RESV);
    end else begin
      head_q        <= head_d;
      head_commit_q <= head_commit_d;
      tail_q        <= tail_d;
    end
  end

endmodule

`default_nettype wire
