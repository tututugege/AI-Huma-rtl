// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (lrsc_unit: LR/SC reservation)
`default_nettype none

// LR/SC reservation register.  Rule chain of a cycle: P1 (commit clears spec_q) -> F (SC consumes / LR arms)
// -> I (page fault of a load or store clears) -> L (mispredict clears if speculative and younger than redirect ROB ptr).
module lsu_lrsc
  import lp_pkg::*;
(
  input  logic             clk,
  input  logic             rst_n,
  output logic             valid_q,            // cur.lrsc_unit (SC verdict of this cycle uses these)
  output logic [31:0]      addr_q,
  output logic [ROBW-1:0]  rob_idx_q,
  output logic             rob_flag_q,
  output logic             spec_q,
  input  logic             valid_i,            // after comb_lsu2exe (SC consumed / LR armed)
  input  logic [31:0]      addr_i,
  input  logic [ROBW-1:0]  rob_idx_i,
  input  logic             rob_flag_i,
  input  logic             spec_i,
  input  logic             pf_clear,           // a load or store page fault (comb_tlb_in_*)
  input  logic             mispred,
  input  logic [ROBW-1:0]  dec_rob_idx,
  input  logic             dec_rob_flag
);
  logic alive;
  assign alive = valid_i && !pf_clear &&
                 !(mispred && spec_i && lp_rob_younger(rob_idx_i, rob_flag_i, dec_rob_idx, dec_rob_flag));

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_q    <= 1'b0;
      spec_q     <= 1'b0;
    end else begin
      valid_q    <= alive;
      spec_q     <= alive ? spec_i : 1'b0;
    end
    addr_q     <= addr_i;
    rob_idx_q  <= rob_idx_i;
    rob_flag_q <= rob_flag_i;
  end
endmodule

`default_nettype wire
