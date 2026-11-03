// Ref: back-end/Idu.cpp  class Idu (br_mask_cp / br_mask_cp_1, comb_fire steps 2 and 4)
`default_nettype none

// Branch-mask checkpoint table: entry t holds the in-flight-branch mask as it was when tag t was allocated
// (including t itself). Entry 0 does not exist (tag 0 is never allocated) and reads as zero.
//   * every non-flush cycle: resolved bits (clear_mask) are removed from every entry
//   * a firing lane writes the checkpoint of its tag (overrides the clear, written value is already clear-free)
//   * ROB flush: entries keep their value (the reference model returns before touching them)
module idu_br_cp #(
  parameter int DW   = 8,
  parameter int NTAG = 64,
  parameter int TAGW = $clog2(NTAG)
) (
  input  logic            clk,
  input  logic            rst_n,
  input  logic            rob_flush,
  input  logic [NTAG-1:0] clear_mask,                // bit 0 ignored by the caller
  input  logic [NTAG-1:0] wr_tag_oh [DW],            // tag written by lane i (zero = no write)
  input  logic [NTAG-1:0] wr_data [DW],
  input  logic [TAGW-1:0] rd_br_id,
  output logic [NTAG-1:0] rd_data
);

  logic [NTAG-1:0] cp_cur [NTAG];                      // entry 0 is a constant zero (unused flops removed)
  logic [NTAG-1:0] cp_nxt [NTAG];
  logic [NTAG-1:0] rd_sel;

  assign cp_cur[0] = '0;
  assign cp_nxt[0] = '0;

  for (genvar t = 1; t < NTAG; t++) begin : g_entry
    logic [DW-1:0]   lane_sel;
    logic [NTAG-1:0] wr_val;
    logic            wr_any;

    for (genvar l = 0; l < DW; l++) begin : g_sel
      assign lane_sel[l] = wr_tag_oh[l][t];
    end
    ttg_onehot_mux #(.N(DW), .W(NTAG)) u_wr (.sel(lane_sel), .data(wr_data), .out(wr_val));
    assign wr_any  = |lane_sel;
    assign cp_nxt[t] = rob_flush ? cp_cur[t] : (wr_any ? wr_val : (cp_cur[t] & ~clear_mask));

    logic [NTAG-1:0] entry_q;
    always_ff @(posedge clk) begin
      if (!rst_n) entry_q <= '0;
      else        entry_q <= cp_nxt[t];
    end
    assign cp_cur[t] = entry_q;
  end

  // read port: checkpoint of the mispredicted branch's tag
  assign rd_sel = NTAG'(1) << rd_br_id;
  ttg_onehot_mux #(.N(NTAG), .W(NTAG)) u_rd (.sel(rd_sel), .data(cp_cur), .out(rd_data));

endmodule

`default_nettype wire
