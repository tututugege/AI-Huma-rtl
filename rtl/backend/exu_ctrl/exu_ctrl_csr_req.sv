// Ref: back-end/Exu/Exu.cpp  Exu::comb_to_csr
`default_nettype none

// CSR request from the CSR slot (issue port 0). The slot only ever holds CSR instructions, and `csr_en` already
// excludes flush and killed instructions, so the C++ scan "valid CSR slot on port 0 that is not killed" is just csr_en.
module exu_ctrl_csr_req
  import ttg_cfg_pkg::*;
  import exu_ctrl_pkg::*;
(
  input  logic                     csr_en,
  input  logic [2:0]               func3,
  input  logic [31:0]              imm,
  input  logic [PRF_IDX_WIDTH-1:0] dest_preg,
  input  logic                     src2_is_imm,
  input  logic [XLEN_BITS-1:0]              src1_rdata,
  input  logic [CSR_IDX_WIDTH-1:0] csr_idx,
  output logic                     we,
  output logic                     re,
  output logic [CSR_IDX_WIDTH-1:0] idx,
  output logic [XLEN_BITS-1:0]              wdata,
  output logic [1:0]               wcmd
);

  logic csrrw_family;    // csrrw / csrrwi always write; csrrs/csrrc(i) write only with a non-zero source
  logic src_is_zero;
  logic rd_is_zero;

  always_comb begin
    csrrw_family = (func3 == 3'b001) || (func3 == 3'b101);
    src_is_zero  = (imm == 32'd0);
    rd_is_zero   = (dest_preg == '0);
    we    = csr_en && (csrrw_family || !src_is_zero);
    re    = csr_en && (!csrrw_family || !rd_is_zero);
    idx   = csr_en ? csr_idx : '0;
    wdata = src2_is_imm ? XLEN_BITS'(imm) : src1_rdata;   // zimm: zero-extended
    wcmd  = func3[1:0];
  end

endmodule

`default_nettype wire
