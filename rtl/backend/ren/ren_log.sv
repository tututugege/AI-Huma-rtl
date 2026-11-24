// Ref: back-end/Ren.cpp  class Ren  (local ROB-indexed rename log, 8 banks x ROB_LINE_NUM rows, 1R1W, 25b packed)
`default_nettype none

// Local ROB-indexed rename log inside Ren (256 entries, 8 banks x 32 rows, 25 bits/entry stored).
// Packs dest_preg / old_dest_preg as 8-bit low tags (MSB == dest_fp) to save 2 bits/entry (512 FFs).
module ren_log
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N = DECODE_WIDTH
) (
  input  logic                     clk,
  input  logic [N-1:0]             wr_valid,
  input  logic [ROB_IDX_WIDTH-1:0] wr_rob_idx [N],
  input  ren_log_entry_t           wr_entry [N],
  input  logic [ROB_IDX_WIDTH-1:0] rd_base_next,
  output ren_log_entry_t           rd_slot [N]
);

  localparam int NB = ROB_BANK_NUM;
  localparam int NL = ROB_LINE_NUM;
  localparam int BW = $clog2(NB);
  localparam int LW = $clog2(NL);
  localparam int TW = $clog2(PRF_NUM);   // 8 bits (MSB reconstructed from dest_fp)

  typedef struct packed {
    logic          dest_en;
    logic          dest_fp;
    areg_t         dest_areg;
    logic [TW-1:0] dest_preg_lo;
    logic [TW-1:0] old_dest_preg_lo;
    logic          me_elim;
  } packed_log_t;

  localparam int EW = $bits(packed_log_t);

  logic [EW-1:0] entry_q [NB][NL];

  // ---- write side: up to N consecutive ROB indices -> at most one hit per bank ----
  logic [NB-1:0] bank_we;
  logic [LW-1:0] bank_wline [NB];
  logic [EW-1:0] bank_wdata [NB];

  for (genvar b = 0; b < NB; b++) begin : g_wr_bank
    logic [N-1:0]  hit;
    logic [LW-1:0] lines [N];
    logic [EW-1:0] datas [N];
    for (genvar i = 0; i < N; i++) begin : g_wr_lane
      packed_log_t pe;
      assign pe = '{
        dest_en:          wr_entry[i].dest_en,
        dest_fp:          wr_entry[i].dest_fp,
        dest_areg:        wr_entry[i].dest_areg,
        dest_preg_lo:     wr_entry[i].dest_preg[TW-1:0],
        old_dest_preg_lo: wr_entry[i].old_dest_preg[TW-1:0],
        me_elim:          wr_entry[i].me_elim
      };
      assign hit[i]   = wr_valid[i] & (wr_rob_idx[i][BW-1:0] == BW'(b));
      assign lines[i] = wr_rob_idx[i][ROB_IDX_WIDTH-1:BW];
      assign datas[i] = pe;
    end
    assign bank_we[b] = |hit;
    ttg_onehot_mux #(.N(N), .W(LW)) u_wline (.sel(hit), .data(lines), .out(bank_wline[b]));
    ttg_onehot_mux #(.N(N), .W(EW)) u_wdata (.sel(hit), .data(datas), .out(bank_wdata[b]));

    always_ff @(posedge clk) begin
      if (bank_we[b]) entry_q[b][bank_wline[b]] <= bank_wdata[b];
    end
  end

  // ---- read side: pre-registered 8-bank read at rd_base_next, rotated AFTER flip-flops ----
  // Latching bank_rd_q[0..7] + base_bank_q moves the 8:1 rotation mux off the rd_base_next critical path!
  logic [LW-1:0] base_line, next_line;
  logic [BW-1:0] base_bank, base_bank_q;
  logic [NL-1:0] base_oh, next_oh;
  logic [NB-1:0] bb_oh_q;
  logic [EW-1:0] bank_rd [NB];
  logic [EW-1:0] bank_rd_q [NB];
  logic [EW-1:0] rd_slot_rot [NB];

  assign base_line = rd_base_next[ROB_IDX_WIDTH-1:BW];
  assign next_line = base_line + LW'(1);
  assign base_bank = rd_base_next[BW-1:0];

  for (genvar l = 0; l < NL; l++) begin : g_line_dec
    assign base_oh[l] = (base_line == LW'(l));
    assign next_oh[l] = (next_line == LW'(l));
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
    ttg_onehot_mux #(.N(NL), .W(EW)) u_rd (.sel(rd_oh), .data(entry_q[b]), .out(bank_rd[b]));
    always_ff @(posedge clk) begin
      bank_rd_q[b] <= bank_rd[b];
    end
  end

  always_ff @(posedge clk) begin
    base_bank_q <= base_bank;
  end

  for (genvar b = 0; b < NB; b++) begin : g_bank_dec
    assign bb_oh_q[b] = (base_bank_q == BW'(b));
  end

  for (genvar k = 0; k < NB; k++) begin : g_rot
    logic [NB-1:0] slot_sel;
    packed_log_t   pe;
    for (genvar b = 0; b < NB; b++) begin : g_sel
      assign slot_sel[b] = bb_oh_q[(b - k + NB) % NB];
    end
    ttg_onehot_mux #(.N(NB), .W(EW)) u_rot (.sel(slot_sel), .data(bank_rd_q), .out(rd_slot_rot[k]));
    assign pe = packed_log_t'(rd_slot_rot[k]);
    assign rd_slot[k] = '{
      dest_en:       pe.dest_en,
      dest_fp:       pe.dest_fp,
      dest_areg:     pe.dest_areg,
      dest_preg:     {pe.dest_fp, pe.dest_preg_lo},
      old_dest_preg: {pe.dest_fp, pe.old_dest_preg_lo},
      me_elim:       pe.me_elim
    };
  end

  // waiver: MSB of wr_entry.dest_preg / old_dest_preg equals dest_fp
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_msb;
  always_comb begin
    unused_msb = 1'b0;
    for (int i = 0; i < N; i++) unused_msb ^= wr_entry[i].dest_preg[PRF_IDX_WIDTH-1] ^ wr_entry[i].old_dest_preg[PRF_IDX_WIDTH-1];
  end
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
