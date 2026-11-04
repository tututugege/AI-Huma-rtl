// Ref: back-end/Exu/Csr.cpp  Csr::comb_csr_read  (table-driven read port)
`default_nettype none

// One CSR read port: CSR number -> register word (through the view mask). Unknown numbers read 0
// (the reference model aborts; unreachable, not replicated).
module csr_read
  import csr_pkg::*;
(
  input  logic [11:0] idx,
  input  logic [31:0] regs [NREG],
  output logic [31:0] rdata
);

  logic [NENT-1:0] sel;
  logic [31:0]     entry_value [NENT];

  for (genvar e = 0; e < NENT; e++) begin : g_entry
    assign sel[e]         = (idx == ENT_ADDR[e]);
    // sie / sip: only the delegated bits
    assign entry_value[e] = regs[ENT_REG[e]] & ENT_RMASK[e] & (ENT_DELEG[e] ? regs[R_MIDELEG] : ALL_ONES);
  end

  ttg_onehot_mux #(.N(NENT), .W(32)) u_mux (.sel(sel), .data(entry_value), .out(rdata));

endmodule

`default_nettype wire
