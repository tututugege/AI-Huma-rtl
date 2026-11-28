// Ref: back-end/Exu/Exu.cpp  Exu::init (AGU instances), back-end/Exu/include/Fu.h  AguUnit
`default_nettype none

// The LSU_AGU_COUNT address-generation units (load AGUs first, then store-address AGUs), ports flattened
// (combinational).
module agu_bank
  import ttg_cfg_pkg::*;
#(
  parameter int N = LSU_AGU_COUNT
) (
  input  logic [XLEN_BITS-1:0] src1_rdata [N],
  input  logic [31:0] imm        [N],
  output logic [XLEN_BITS-1:0] result     [N]
);

  for (genvar i = 0; i < N; i++) begin : g_agu
    agu u_agu (
      .src1_rdata(src1_rdata[i]), .imm(imm[i]),
      .result(result[i])
    );
  end

endmodule

`default_nettype wire
