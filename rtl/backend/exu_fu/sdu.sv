// Ref: back-end/Exu/include/Fu.h  SduUnit
`default_nettype none

// Store-data unit: plain stores pass src2 through; AMOs combine src1 (old memory value) with src2 according to
// funct7[6:2].  Unlisted AMO encodings (LR/SC/reserved) pass src2, as in the C++ `default:` arm.
module sdu
  import exu_fu_pkg::*;
(
  input  logic             en,
  input  logic             consume,
  input  logic             is_atomic,
  input  logic [AMO_W-1:0] amo_op,
  input  logic [31:0]      src1_rdata,
  input  logic [31:0]      src2_rdata,
  output logic             complete,
  output logic             ready,
  output logic [31:0]      result
);

  exu_fu_sc_ctl u_ctl (.en(en), .consume(consume), .complete(complete), .ready(ready));

  logic lt_s, lt_u;
  always_comb begin
    lt_s = $signed(src1_rdata) < $signed(src2_rdata);  // amomin/amomax compare signed
    lt_u = src1_rdata < src2_rdata;
  end

  // Ref: SduUnit::impl_compute
  always_comb begin
    result = src2_rdata;  // plain store, amoswap and every unlisted AMO encoding
    if (is_atomic) begin
      case (amo_op)
        AMO_ADD:  result = src1_rdata + src2_rdata;
        AMO_XOR:  result = src1_rdata ^ src2_rdata;
        AMO_AND:  result = src1_rdata & src2_rdata;
        AMO_OR:   result = src1_rdata | src2_rdata;
        AMO_MIN:  result = lt_s ? src1_rdata : src2_rdata;
        AMO_MAX:  result = lt_s ? src2_rdata : src1_rdata;  // src1 > src2 (equal operands give the same value)
        AMO_MINU: result = lt_u ? src1_rdata : src2_rdata;
        AMO_MAXU: result = lt_u ? src2_rdata : src1_rdata;
        default:  result = src2_rdata;
      endcase
    end
  end

endmodule

`default_nettype wire
