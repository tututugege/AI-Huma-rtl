// Ref: front-end/BPU/BPU_pipe.h  UbTab (S0 uBTB and S1 L1 table storage)
`default_nettype none

// Set-associative table of ub_ent_t.  One lookup read port (S0 / S1), one train read port (read-modify-write of the
// set at the head of the train queue) and one set write port with a way mask.  Reads see the START-of-cycle contents.
module bpu_ub_tab import bpu_pkg::*; import bpu_stage_pkg::*; #(
  parameter int SET_W = 5,
  parameter int WAYS  = 4
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic [SET_W-1:0]  rd_set,
  output ub_ent_t           rd_ent [WAYS],
  input  logic [SET_W-1:0]  tr_set,
  output ub_ent_t           tr_ent [WAYS],
  input  logic [WAYS-1:0]   wr_mask,
  input  logic [SET_W-1:0]  wr_set,
  input  ub_ent_t           wr_ent [WAYS]
);

  localparam int SETS = 1 << SET_W;

  ub_ent_t mem_q [SETS][WAYS];

  for (genvar w = 0; w < WAYS; w++) begin : g_way
    assign rd_ent[w] = mem_q[rd_set][w];
    assign tr_ent[w] = mem_q[tr_set][w];
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        for (int s = 0; s < SETS; s++) mem_q[s][w] <= '0;
      end else if (wr_mask[w]) begin
        mem_q[wr_set][w] <= wr_ent[w];
      end
    end
  end

endmodule

`default_nettype wire
