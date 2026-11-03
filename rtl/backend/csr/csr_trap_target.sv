// Ref: back-end/Exu/Csr.cpp  Csr::comb_exception (trap_pc)
`default_nettype none

// Trap vector: vectored mode (tvec[0]) adds 4*code for interrupts; otherwise the raw tvec register.
module csr_trap_target (
  input  logic [31:0] tvec,
  input  logic        is_interrupt,
  input  logic [3:0]  cause_code,
  output logic [31:0] target_pc
);

  logic [31:0] vectored_pc;
  assign vectored_pc = {tvec[31:2], 2'b00} + {26'b0, cause_code, 2'b00};
  assign target_pc   = (tvec[0] && is_interrupt) ? vectored_pc : tvec;

endmodule

`default_nettype wire
