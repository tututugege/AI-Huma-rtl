// Ref: back-end/Ren.cpp  class Ren  (RAT_checkpoint, alloc_checkpoint_head)
`default_nettype none

// Per-branch-tag recovery state: the spec RAT and the free-list head right after the branch renamed.
// Written by up to N branches per cycle (higher slot wins on equal tag); read (old value) at the mispredicted tag.
module ren_ckpt
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N  = DECODE_WIDTH,
  parameter int NB = MAX_BR_NUM
) (
  input  logic     clk,
  input  logic     rst_n,
  input  logic [N-1:0] wr_valid,
  input  br_tag_t  wr_br_id [N],
  input  rat_t     wr_rat   [N],
  input  preg_t    wr_head  [N],
  input  br_tag_t  rd_br_id,
  output rat_t     rd_rat,
  output preg_t    rd_head
);

  localparam int EW = $bits(rat_t) + PRF_IDX_WIDTH;

  logic [EW-1:0] entry_q [NB];
  logic [EW-1:0] entry_d [NB];
  logic [EW-1:0] wr_entry [N];
  logic [NB-1:0] rd_sel;
  logic [EW-1:0] rd_entry;

  for (genvar i = 0; i < N; i++) begin : g_wr_entry
    assign wr_entry[i] = {wr_head[i], wr_rat[i]};
  end

  for (genvar b = 0; b < NB; b++) begin : g_tag
    logic [N-1:0] hit;
    logic         hit_any;
    logic [EW-1:0] hit_value;
    for (genvar i = 0; i < N; i++) begin : g_hit
      assign hit[i] = wr_valid[i] & (wr_br_id[i] == br_tag_t'(b));
    end
    ren_last_write #(.N(N), .W(EW)) u_lw (.hit(hit), .data(wr_entry), .any(hit_any), .value(hit_value));
    assign entry_d[b] = hit_any ? hit_value : entry_q[b];
    assign rd_sel[b]  = (rd_br_id == br_tag_t'(b));

    always_ff @(posedge clk) begin
      if (!rst_n) entry_q[b] <= '0;
      else        entry_q[b] <= entry_d[b];
    end
  end

  ttg_onehot_mux #(.N(NB), .W(EW)) u_rd (.sel(rd_sel), .data(entry_q), .out(rd_entry));

  assign rd_rat  = rat_t'(rd_entry[$bits(rat_t)-1:0]);
  assign rd_head = rd_entry[EW-1 -: PRF_IDX_WIDTH];

endmodule

`default_nettype wire
