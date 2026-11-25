// SVA checker for external DDR AXI4 master interface on soc_top (simulation/formal only)
`default_nettype none

module sva_axi_ddr (
  input logic         clk,
  input logic         rst_n,
  input logic         d_arvalid,
  input logic         d_arready,
  input logic [5:0]   d_arid,
  input logic [31:0]  d_araddr,
  input logic [7:0]   d_arlen,
  input logic         d_rvalid,
  input logic         d_rready,
  input logic         d_awvalid,
  input logic         d_awready,
  input logic [5:0]   d_awid,
  input logic [31:0]  d_awaddr,
  input logic [7:0]   d_awlen,
  input logic         d_wvalid,
  input logic         d_wready,
  input logic [255:0] d_wdata,
  input logic [31:0]  d_wstrb,
  input logic         d_wlast,
  input logic         d_bvalid,
  input logic         d_bready
);

  // ---- AXI4 master stability rules (valid & payload must remain stable until ready) ----
  a_axi_ar_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (d_arvalid && !d_arready) |=> (d_arvalid && $stable(d_araddr) && $stable(d_arid) && $stable(d_arlen)))
    else $error("[SVA_AXI] AR channel unstable while waiting for arready");

  a_axi_aw_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (d_awvalid && !d_awready) |=> (d_awvalid && $stable(d_awaddr) && $stable(d_awid) && $stable(d_awlen)))
    else $error("[SVA_AXI] AW channel unstable while waiting for awready");

  a_axi_w_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (d_wvalid && !d_wready) |=> (d_wvalid && $stable(d_wdata) && $stable(d_wstrb) && $stable(d_wlast)))
    else $error("[SVA_AXI] W channel unstable while waiting for wready");

  // ---- Functional coverage points ----
  c_axi_ar_hs: cover property (@(posedge clk) disable iff (!rst_n) d_arvalid && d_arready);
  c_axi_aw_hs: cover property (@(posedge clk) disable iff (!rst_n) d_awvalid && d_awready);
  c_axi_w_hs:  cover property (@(posedge clk) disable iff (!rst_n) d_wvalid  && d_wready && d_wlast);
  c_axi_r_hs:  cover property (@(posedge clk) disable iff (!rst_n) d_rvalid  && d_rready);
  c_axi_b_hs:  cover property (@(posedge clk) disable iff (!rst_n) d_bvalid  && d_bready);

endmodule

`default_nettype wire
