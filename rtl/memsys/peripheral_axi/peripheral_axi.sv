// Ref: MemSubSystem/PeripheralAxi.cpp  PeripheralAxi
`default_nettype none

// LSU MMIO / uncached access unit (spec/peripheral_axi.io).  Top level only adapts the flat spec ports.
module peripheral_axi import memcpu_pkg::*; import ttg_cfg_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  input  logic cpu_en,
  input  logic        req_is_mmio,
  input  logic        req_wen,
  input  logic [31:0] req_addr,
  input  logic [XLEN_BITS-1:0] req_wdata,
  input  logic [2:0]  req_func3,
  input  logic        env_modeled,
  input  logic [XLEN_BITS-1:0] env_rdata,
  input  logic        axi_rd_req_accepted,
  input  logic        axi_rd_resp_valid,
  input  logic [31:0] axi_rd_resp_data,
  input  logic        axi_wr_req_accepted,
  input  logic        axi_wr_resp_valid,
  output logic        resp_ready,
  output logic        resp_is_mmio,
  output logic [XLEN_BITS-1:0] resp_rdata,
  output logic        axi_rd_req_valid,
  output logic [31:0] axi_rd_req_addr,
  output logic [PA_SIZE_W-1:0] axi_rd_req_size,
  output logic        axi_rd_resp_ready,
  output logic        axi_wr_req_valid,
  output logic [31:0] axi_wr_req_addr,
  output logic [PA_SIZE_W-1:0] axi_wr_req_size,
  output logic [3:0]  axi_wr_req_wstrb,
  output logic [31:0] axi_wr_req_wdata,
  output logic        axi_wr_resp_ready,
  output logic        env_rd_en,
  output logic [31:0] env_rd_addr,
  output logic [2:0]  env_rd_func3
);

  logic [2:0]  fmt_func3;
  logic [XLEN_BITS-1:0] fmt_wdata;
  logic [PA_SIZE_W-1:0] fmt_size;
  logic [3:0]  fmt_wstrb;
  logic [31:0] fmt_wdata_packed;
  logic [XLEN_BITS-1:0] fmt_rdata_ext;

  peripheral_axi_fmt u_fmt (
    .func3 (fmt_func3), .wdata (fmt_wdata), .rd_word (axi_rd_resp_data),
    .size (fmt_size), .wstrb (fmt_wstrb), .wdata_packed (fmt_wdata_packed), .rdata_ext (fmt_rdata_ext)
  );

  peripheral_axi_ctl u_ctl (.*);

endmodule

`default_nettype wire
