// Ref: back-end/Prf.cpp  Prf::comb_write
`default_nettype none

// Write-port arbitration: for every physical register find which write-back lanes target it.
// If several lanes write the same register in one cycle the highest lane index wins (the reference model
// performs the writes in lane order, so the last one overwrites). p0 is never written.
module prf_write_arb import ttg_cfg_pkg::*; #(
  parameter int LANES = ISSUE_WIDTH,
  parameter int NREG  = PRF_NUM
) (
  input  logic [LANES-1:0]         wb_valid,
  input  logic [LANES-1:0]         wb_dest_en,
  input  logic [PRF_IDX_WIDTH-1:0] wb_dest_preg [LANES],
  input  logic [31:0]              wb_result    [LANES],
  output logic [NREG-1:0]          reg_wr_en,
  output logic [31:0]              reg_wr_data  [NREG]
);

  logic [LANES-1:0] lane_writes;

  always_comb begin
    for (int i = 0; i < LANES; i++) begin
      lane_writes[i] = wb_valid[i] && wb_dest_en[i] && (wb_dest_preg[i] != '0);
    end
  end

  // Ref: Prf::comb_write -- per register: match vector, reversed so that find-first-set picks the highest lane
  for (genvar p = 0; p < NREG; p++) begin : g_reg
    logic [LANES-1:0] lane_hits;
    logic [LANES-1:0] lane_hits_rev;
    logic [LANES-1:0] winner_rev;
    logic [LANES-1:0] winner;
    logic             any_hit;

    always_comb begin
      for (int i = 0; i < LANES; i++) begin
        lane_hits[i]     = lane_writes[i] && (wb_dest_preg[i] == PRF_IDX_WIDTH'(p));
        lane_hits_rev[i] = lane_hits[LANES-1-i];
        winner[i]        = winner_rev[LANES-1-i];
      end
    end

    ttg_first_set #(.N(LANES)) u_last_writer (.req(lane_hits_rev), .onehot(winner_rev), .any(any_hit));
    ttg_onehot_mux #(.N(LANES), .W(32)) u_data (.sel(winner), .data(wb_result), .out(reg_wr_data[p]));

    assign reg_wr_en[p] = any_hit;
  end

endmodule

`default_nettype wire
