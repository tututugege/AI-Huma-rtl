// Ref: back-end/Ren.cpp  class Ren  (sparse K-entry single-write-port checkpoint data array)
`default_nettype none

// Single-write-port sparse checkpoint array (NK = REN_CKPT_NUM entries).
// Takes a single pre-selected RAT snapshot + free-list head (no internal N-to-1 write mux).
module ren_ckpt
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int NK = REN_CKPT_NUM,
  parameter int KW = (NK > 1) ? $clog2(NK) : 1,
  parameter int RW = RAT_NUM * $clog2(PRF_NUM),  // bits of one narrow RAT snapshot
  parameter int HW = $clog2(PRF_NUM)             // bits of one free-list head pointer
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          wr_en,
  input  logic [KW-1:0] wr_slot,
  input  logic [RW-1:0] wr_rat,
  input  logic [HW-1:0] wr_head,
  input  logic [KW-1:0] rd_slot,
  output logic [RW-1:0] rd_rat,
  output logic [HW-1:0] rd_head
);

  localparam int EW = RW + HW;

  logic [EW-1:0] entry_q [NK];
  logic [EW-1:0] wr_entry;
  logic [NK-1:0] rd_sel;
  logic [EW-1:0] rd_entry;

  assign wr_entry = {wr_head, wr_rat};

  for (genvar s = 0; s < NK; s++) begin : g_slot
    assign rd_sel[s] = (rd_slot == KW'(s));
    always_ff @(posedge clk) begin
      if (!rst_n) entry_q[s] <= '0;
      else if (wr_en && (wr_slot == KW'(s))) entry_q[s] <= wr_entry;
    end
  end

  ttg_onehot_mux #(.N(NK), .W(EW)) u_rd (.sel(rd_sel), .data(entry_q), .out(rd_entry));

  assign rd_rat  = rd_entry[RW-1:0];
  assign rd_head = rd_entry[EW-1 -: HW];

endmodule

`default_nettype wire
