`default_nettype none
// Ref: AXI_Interconnect.cpp  AXI_Interconnect::comb_write_request (LLC branch), has_same_line_read_hazard
// Write-master capture: only the FIRST valid master (fixed priority 0 -> 1: w_arb_rr_idx never moves on the live
//   path) whose line
// has no pending read is handled; it is accepted if its ready-first register is already set, else the register is
//   raised.
module axi_ic_wr
  import axi_ic_pkg::*;
(
  input  logic          clk,
  input  logic          rst_n,
  input  logic          phase0,
  input  logic          m_valid [NW],
  input  logic          hazard  [NW],     // same-line read hazard of the master's line (axi_ic_haz)
  output logic          acc     [NW],
  output logic          ready_o2 [NW],    // meaningful for the peripheral port only (DCache ignores write ready)
  output logic          sel_first        // master 1 is the selected one (else master 0)
);
  logic ready_q [NW];
  logic [NW-1:0] elig, onehot;
  logic any_elig;

  for (genvar i = 0; i < NW; i++) begin : g_e
    assign elig[i] = m_valid[i] && !hazard[i];
  end
  ttg_first_set #(.N(NW)) u_fs (.req(elig), .onehot(onehot), .any(any_elig));
  assign sel_first = onehot[1];

  for (genvar i = 0; i < NW; i++) begin : g_w
    logic take;
    logic raise;
    assign take  = onehot[i] && ready_q[i];
    assign raise = onehot[i] && !ready_q[i];
    assign acc[i]      = take;
    assign ready_o2[i] = onehot[i] || ready_q[i];
    if (i == MASTER_DCACHE_W) begin : g_dc
      always_ff @(posedge clk) begin
        if (!rst_n) ready_q[i] <= 1'b0;
        else        ready_q[i] <= raise;
      end
    end else begin : g_cpu
      always_ff @(posedge clk) begin
        if (!rst_n)      ready_q[i] <= 1'b0;
        else if (phase0) ready_q[i] <= raise;
      end
    end
  end

  logic unused_any;
  assign unused_any = any_elig;
endmodule

`default_nettype wire
