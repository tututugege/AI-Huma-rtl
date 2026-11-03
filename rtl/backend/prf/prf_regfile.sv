// Ref: back-end/Prf.cpp  class Prf  reg_file[] / seq
`default_nettype none

// Physical register storage: NREG x 32, asynchronous read ports, per-register write enable from prf_write_arb.
module prf_regfile import ttg_cfg_pkg::*; #(
  parameter int NREG  = PRF_NUM,
  parameter int LANES = ISSUE_WIDTH
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [NREG-1:0]          reg_wr_en,
  input  logic [31:0]              reg_wr_data [NREG],
  input  logic [PRF_IDX_WIDTH-1:0] rd_addr [2][LANES],
  output logic [31:0]              rd_data [2][LANES]
);

  logic [31:0] reg_file_q [NREG];

  // Ref: Prf::comb_read (register file part)
  always_comb begin
    for (int s = 0; s < 2; s++) begin
      for (int i = 0; i < LANES; i++) begin
        rd_data[s][i] = reg_file_q[rd_addr[s][i]];
      end
    end
  end

  // Ref: Prf::comb_begin + comb_write  (each register has its own write enable; reset value 0 kept: x0 and
  // never-written registers are read by the reference model)
  for (genvar p = 0; p < NREG; p++) begin : g_reg
    always_ff @(posedge clk) begin
      if (!rst_n)            reg_file_q[p] <= '0;
      else if (reg_wr_en[p]) reg_file_q[p] <= reg_wr_data[p];
    end
  end

endmodule

`default_nettype wire
