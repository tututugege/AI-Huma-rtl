// Ref: back-end/Exu/include/AbstractFU.h  SingleCycleFU
`default_nettype none

// Handshake of a single-cycle FU (ALU/BRU/AGU/SDU/CSR): the result is produced in the cycle the uop arrives
// (complete = en); the FU can take a new uop next cycle unless the finished one is still waiting to be consumed.
module exu_fu_sc_ctl (
  input  logic en,
  input  logic consume,
  output logic complete,
  output logic ready
);

  always_comb begin
    complete = en;                 // SingleCycleFU::comb_issue
    ready    = !en || consume;     // SingleCycleFU::comb_consume
  end

endmodule

`default_nettype wire
