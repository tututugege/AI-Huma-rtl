// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_mmio_out: drive the uncached unit onto the peripheral request port)
`default_nettype none

module lsu_mmio_out
  import lsu_pkg::*;
(
  input  logic             peripheral_ready,
  input  logic             unc_valid,
  input  logic             unc_is_load,
  input  logic [31:0]      unc_addr,
  input  logic [31:0]      unc_wdata,
  input  logic [2:0]       unc_func3,
  output logic             req_is_mmio,
  output logic             req_wen,
  output logic [31:0]      req_addr,
  output logic [31:0]      req_wdata,
  output logic [2:0]       req_fun3
);

  assign req_is_mmio = peripheral_ready && unc_valid;
  assign req_wen     = req_is_mmio && !unc_is_load;
  assign req_addr    = unc_addr;
  assign req_wdata   = unc_wdata;
  assign req_fun3    = unc_func3;

endmodule

`default_nettype wire
