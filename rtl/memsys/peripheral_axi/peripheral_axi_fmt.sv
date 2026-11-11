// Ref: MemSubSystem/PeripheralAxi.cpp  PeripheralAxi::access_size_bytes, pack_write_data/strb, extract_read_data
`default_nettype none

// Access-size dependent formatting of the single-word peripheral transfers.
//   size  : AXI total_size = bytes - 1  (func3[1:0]: 0 -> 1 byte, 1 -> 2 bytes, else 4 bytes)
//   wstrb / wdata : store data masked to the access size, byte strobes of word 0
//   rdata : load data of a response word, sign/zero extended by the full 3-bit func3 (LB/LH/LW/LBU/LHU; others raw)
module peripheral_axi_fmt import memcpu_pkg::*; import ttg_cfg_pkg::*; (
  input  logic [2:0]          func3,
  /* verilator lint_off UNUSEDSIGNAL */  // the AXI path is one 32-bit word
  input  logic [XLEN_BITS-1:0] wdata,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0]         rd_word,
  output logic [PA_SIZE_W-1:0] size,
  output logic [3:0]          wstrb,
  output logic [31:0]         wdata_packed,
  output logic [XLEN_BITS-1:0] rdata_ext
);

  always_comb begin
    case (func3[1:0])
      2'd0:    begin size = 2'd0; wstrb = 4'h1; wdata_packed = {24'd0, wdata[7:0]};  end
      2'd1:    begin size = 2'd1; wstrb = 4'h3; wdata_packed = {16'd0, wdata[15:0]}; end
      default: begin size = 2'd3; wstrb = 4'hF; wdata_packed = wdata[31:0];          end   // lw/sw, low word of sd
    endcase
  end

  always_comb begin
    case (func3)
      3'b000:  rdata_ext = XLEN_BITS'($signed(rd_word[7:0]));
      3'b001:  rdata_ext = XLEN_BITS'($signed(rd_word[15:0]));
      3'b100:  rdata_ext = XLEN_BITS'(rd_word[7:0]);
      3'b101:  rdata_ext = XLEN_BITS'(rd_word[15:0]);
      3'b110:  rdata_ext = XLEN_BITS'(rd_word);                // lwu (rv64)
      default: rdata_ext = XLEN_BITS'($signed(rd_word));       // lw (sign-extended on rv64)
    endcase
  end

endmodule

`default_nettype wire
