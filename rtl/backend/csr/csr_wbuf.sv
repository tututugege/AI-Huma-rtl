// Ref: back-end/Exu/Csr.cpp  Csr::comb_csr_write (csr_we/csr_idx/csr_wdata/csr_wcmd staging registers)
`default_nettype none

// A CSR instruction latches its write request at execute; the register file is only written when ROB commits it.
module csr_wbuf
  import csr_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        exe_we,
  input  logic [11:0] exe_idx,
  input  logic [31:0] exe_wdata,
  input  logic [1:0]  exe_wcmd,
  input  logic        commit,
  input  logic [31:0] old_value,       // current value of CSR pending_idx (read port 2)
  output logic [11:0] pending_idx,
  output logic        commit_fire,     // commit of a staged write this cycle
  output logic [31:0] commit_wdata     // value after csrrs/csrrc read-modify-write
);

  logic        we_q, we_d;
  logic [11:0] idx_q, idx_d;
  logic [31:0] wdata_q, wdata_d;
  logic [1:0]  wcmd_q, wcmd_d;

  assign pending_idx = idx_q;
  assign commit_fire = commit & we_q;

  always_comb begin
    idx_d   = exe_we ? exe_idx   : idx_q;
    wdata_d = exe_we ? exe_wdata : wdata_q;
    wcmd_d  = exe_we ? exe_wcmd  : wcmd_q;
    // reference: the commit clears csr_we after the execute stage set it, so a staged write
    // arriving in the same cycle as the commit of the previous one is dropped
    we_d    = commit_fire ? 1'b0 : (exe_we | we_q);
  end

  always_comb begin
    unique case (wcmd_q)
      WCMD_S:  commit_wdata = wdata_q | old_value;
      WCMD_C:  commit_wdata = ~wdata_q & old_value;
      default: commit_wdata = wdata_q;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      we_q    <= 1'b0;
      idx_q   <= 12'd0;
      wdata_q <= 32'd0;
      wcmd_q  <= 2'd0;
    end else begin
      we_q    <= we_d;
      idx_q   <= idx_d;
      wdata_q <= wdata_d;
      wcmd_q  <= wcmd_d;
    end
  end

endmodule

`default_nettype wire
