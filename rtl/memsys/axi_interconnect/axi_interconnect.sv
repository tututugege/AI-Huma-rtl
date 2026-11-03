`default_nettype none
// Ref: axi-interconnect-kit/axi_interconnect/AXI_Interconnect.cpp  class AXI_Interconnect  (LLC-enabled live
//   paths, one tick per clk)
// Top of the interconnect core: port adaptation + wiring of the read capture, write capture, hazard check,
//   stage/dispatcher, DDR AR/R
// side, DDR AW/W/B side and the response registers.  The LLC is outside (lo_*/hz_* inputs, li_* outputs); see
//   docs/modules/axi_interconnect.md.
module axi_interconnect
  import axi_ic_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic phase0,
  input  logic m_rd_valid [4],
  input  logic [31:0] m_rd_addr [4],
  input  logic [7:0] m_rd_size [4],
  input  logic [3:0] m_rd_id [4],
  input  logic m_rd_bypass [4],
  input  logic m_rd_resp_ready [4],
  input  logic m_wr_valid [2],
  input  logic [31:0] m_wr_addr [2],
  input  logic [511:0] m_wr_data [2],
  input  logic [63:0] m_wr_strb [2],
  input  logic [7:0] m_wr_size [2],
  input  logic [3:0] m_wr_id [2],
  input  logic m_wr_bypass [2],
  input  logic m_wr_resp_ready [2],
  input  logic d_arready,
  input  logic d_rvalid,
  input  logic [5:0] d_rid,
  input  logic [255:0] d_rdata,
  input  logic d_awready,
  input  logic d_wready,
  input  logic d_bvalid,
  input  logic [5:0] d_bid,
  input  logic [1:0] d_bresp,
  input  logic lo_rd_req_ready [4],
  input  logic lo_rd_resp_valid [4],
  input  logic [3:0] lo_rd_resp_id [4],
  input  logic [511:0] lo_rd_resp_data [4],
  input  logic lo_wr_req_ready [2],
  input  logic lo_wr_resp_valid [2],
  input  logic [3:0] lo_wr_resp_id [2],
  input  logic [1:0] lo_wr_resp_resp [2],
  input  logic lo_mem_rd_req_valid,
  input  logic [31:0] lo_mem_rd_req_addr,
  input  logic [7:0] lo_mem_rd_req_size,
  input  logic [3:0] lo_mem_rd_req_id,
  input  logic lo_mem_wr_req_valid,
  input  logic [31:0] lo_mem_wr_req_addr,
  input  logic [511:0] lo_mem_wr_req_data,
  input  logic [63:0] lo_mem_wr_req_strb,
  input  logic [7:0] lo_mem_wr_req_size,
  input  logic [3:0] lo_mem_wr_req_id,
  input  logic hz_lookup_valid,
  input  logic hz_lookup_is_write,
  input  logic [31:0] hz_lookup_addr,
  input  logic [1:0] hz_lookup_master,
  input  logic [3:0] hz_lookup_id,
  input  logic hz_rresp_fresh [4],
  input  logic hz_rresp_valid [4],
  input  logic [3:0] hz_rresp_id [4],
  input  logic hz_mshr_valid [8],
  input  logic hz_mshr_is_write [8],
  input  logic [1:0] hz_mshr_master [8],
  input  logic [3:0] hz_mshr_id [8],
  input  logic [31:0] hz_mshr_line [8],
  output logic m_rd_resp_valid [4],
  output logic [3:0] m_rd_resp_id [4],
  output logic [511:0] m_rd_resp_data [4],
  output logic m_rd_accepted [4],
  output logic [3:0] m_rd_accepted_id [4],
  output logic m_wr_accepted [2],
  output logic m_wr_resp_valid [2],
  output logic [3:0] m_wr_resp_id [2],
  output logic [1:0] m_wr_resp_resp [2],
  output logic d_rready,
  output logic d_bready,
  output logic m_rd0_req_ready,
  output logic m_rd3_req_ready,
  output logic m_wr1_req_ready,
  output logic d_arvalid,
  output logic [5:0] d_arid,
  output logic [31:0] d_araddr,
  output logic [7:0] d_arlen,
  output logic d_awvalid,
  output logic [5:0] d_awid,
  output logic [31:0] d_awaddr,
  output logic [7:0] d_awlen,
  output logic d_wvalid,
  output logic [255:0] d_wdata,
  output logic [31:0] d_wstrb,
  output logic d_wlast,
  output logic li_rd_valid [4],
  output logic [31:0] li_rd_addr [4],
  output logic [7:0] li_rd_size [4],
  output logic [3:0] li_rd_id [4],
  output logic li_rd_bypass [4],
  output logic li_rd_resp_ready [4],
  output logic li_wr_valid [2],
  output logic [31:0] li_wr_addr [2],
  output logic [511:0] li_wr_data [2],
  output logic [63:0] li_wr_strb [2],
  output logic [7:0] li_wr_size [2],
  output logic [3:0] li_wr_id [2],
  output logic li_wr_bypass [2],
  output logic li_wr_resp_ready [2],
  output logic li_mem_rd_req_ready,
  output logic li_mem_rd_resp_valid,
  output logic [511:0] li_mem_rd_resp_data,
  output logic [3:0] li_mem_rd_resp_id,
  output logic li_mem_wr_req_ready,
  output logic li_mem_wr_resp_valid,
  output logic [1:0] li_mem_wr_resp
);
  // ---------------- internal buses ----------------
  logic          up_v [NR];
  logic [31:0]   up_addr [NR];
  logic [3:0]    up_id [NR];
  logic          stg_rd_v [NR];
  logic [3:0]    stg_rd_id;
  logic          stg_rd_any;
  logic [31:0]   stg_rd_addr;
  logic          stg_wr_v [NW];
  logic [31:0]   li_addr;
  logic [7:0]    li_size;
  logic [3:0]    li_id;
  logic          li_byp;
  logic [511:0]  li_wdata;
  logic [63:0]   li_wstrb;
  logic          acc_q_rd [NR];
  logic [3:0]    acc_id_q [NR];
  logic          acc_q_wr [NW];

  logic          rd_acc [NR];
  logic [31:0]   rd_cap_addr [NR];
  logic [7:0]    rd_cap_size [NR];
  logic [3:0]    rd_cap_id [NR];
  logic          rd_cap_byp [NR];
  logic          rd_ready_o2 [NR];

  logic          wr_acc [NW];
  logic          wr_ready_o2 [NW];
  logic          wr_sel_first;
  logic          wr_hazard [NW];

  logic          rr_v [NR];
  logic [3:0]    rr_id [NR];
  logic [511:0]  rr_data [NR];
  logic          wr_rsp_v [NW];
  logic [3:0]    wr_rsp_id [NW];
  logic [1:0]    wr_rsp_resp [NW];
  logic          resp_rd_ready [NR];
  logic          resp_wr_ready [NW];

  logic [NM-1:0] rp_v;
  logic [NM:0]   pr_v;
  logic [25:0]   pr_line [NM+1];
  logic          fr_v;
  logic [25:0]   fr_line;
  logic          wp_v [2];
  logic [25:0]   wp_line [2];

  logic          hz_mshr_rd [NM];
  logic          hz_lookup_rd;
  for (genvar s = 0; s < NM; s++) begin : g_hz
    assign hz_mshr_rd[s] = hz_mshr_valid[s] && !hz_mshr_is_write[s];
  end
  assign hz_lookup_rd = hz_lookup_valid && !hz_lookup_is_write;

  // ---------------- read capture ----------------
  axi_ic_rd u_rd (
    .clk, .rst_n, .phase0,
    .m_valid(m_rd_valid), .m_addr(m_rd_addr), .m_size(m_rd_size), .m_id(m_rd_id), .m_byp(m_rd_bypass),
    .up_v, .up_id, .stage_rd_v(stg_rd_v), .stage_rd_id(stg_rd_id),
    .rr_v, .rr_id, .rp_v,
    .hz_rresp_valid(hz_rresp_valid), .hz_rresp_id(hz_rresp_id),
    .hz_lookup_valid, .hz_lookup_master, .hz_lookup_id,
    .hz_mshr_valid, .hz_mshr_master, .hz_mshr_id,
    .acc(rd_acc), .cap_addr(rd_cap_addr), .cap_size(rd_cap_size), .cap_id(rd_cap_id), .cap_byp(rd_cap_byp),
    .ready_o2(rd_ready_o2)
  );

  // ---------------- write capture ----------------
  axi_ic_haz u_haz (
    .w_addr(m_wr_addr), .m_rd_valid, .m_rd_addr, .up_v, .up_addr,
    .stage_rd_any(stg_rd_any), .stage_rd_addr(stg_rd_addr),
    .hz_lookup_rd, .hz_lookup_addr, .lo_mem_rd_valid(lo_mem_rd_req_valid), .lo_mem_rd_addr(lo_mem_rd_req_addr),
    .hz_mshr_rd, .hz_mshr_line, .pr_v, .pr_line, .hazard(wr_hazard)
  );

  axi_ic_wr u_wr (
    .clk, .rst_n, .phase0, .m_valid(m_wr_valid), .hazard(wr_hazard),
    .acc(wr_acc), .ready_o2(wr_ready_o2), .sel_first(wr_sel_first)
  );

  // ---------------- stage / dispatcher ----------------
  axi_ic_stage u_stage (
    .clk, .rst_n, .phase0,
    .rd_acc, .rd_addr(rd_cap_addr), .rd_size(rd_cap_size), .rd_id(rd_cap_id), .rd_byp(rd_cap_byp),
    .wr_acc, .wr_addr(m_wr_addr), .wr_size(m_wr_size), .wr_id(m_wr_id), .wr_byp(m_wr_bypass),
    .wr_data(m_wr_data), .wr_strb(m_wr_strb),
    .lo_rd_ready(lo_rd_req_ready), .lo_wr_ready(lo_wr_req_ready),
    .up_v, .up_addr, .up_id, .stg_rd_v, .stg_rd_id, .stg_rd_any, .stg_rd_addr, .stg_wr_v,
    .li_addr, .li_size, .li_id, .li_byp, .li_wdata, .li_wstrb,
    .acc_o1_rd(acc_q_rd), .acc_o1_id(acc_id_q), .acc_o1_wr(acc_q_wr)
  );

  // ---------------- DDR read side ----------------
  logic d_arlen_bit;
  axi_ic_ar u_ar (
    .clk, .rst_n,
    .lo_valid(lo_mem_rd_req_valid), .lo_addr(lo_mem_rd_req_addr), .lo_size(lo_mem_rd_req_size),
    .lo_id(lo_mem_rd_req_id),
    .wp_v, .wp_line,
    .d_arready, .d_rvalid, .d_rid, .d_rdata,
    .o_arvalid(d_arvalid), .o_arid(d_arid), .o_araddr(d_araddr), .o_arlen(d_arlen_bit),
    .li_rd_ready(li_mem_rd_req_ready), .li_resp_valid(li_mem_rd_resp_valid), .li_resp_data(li_mem_rd_resp_data),
    .li_resp_id(li_mem_rd_resp_id),
    .rp_v, .pr_v, .pr_line, .fr_v, .fr_line
  );
  assign d_arlen = {7'b0, d_arlen_bit};

  // ---------------- DDR write side ----------------
  logic d_awlen_bit;
  axi_ic_aw u_aw (
    .clk, .rst_n,
    .lo_valid(lo_mem_wr_req_valid), .lo_addr(lo_mem_wr_req_addr), .lo_data(lo_mem_wr_req_data),
    .lo_strb(lo_mem_wr_req_strb),
    .lo_size(lo_mem_wr_req_size), .lo_id(lo_mem_wr_req_id),
    .pr_v, .pr_line, .fr_v, .fr_line,
    .d_awready, .d_wready, .d_bvalid, .d_bid, .d_bresp,
    .o_awvalid(d_awvalid), .o_awid(d_awid), .o_awaddr(d_awaddr), .o_awlen(d_awlen_bit),
    .o_wvalid(d_wvalid), .o_wdata(d_wdata), .o_wstrb(d_wstrb), .o_wlast(d_wlast), .o_bready(d_bready),
    .li_wr_ready(li_mem_wr_req_ready), .li_resp_valid(li_mem_wr_resp_valid), .li_resp(li_mem_wr_resp),
    .wp_v, .wp_line
  );
  assign d_awlen = {7'b0, d_awlen_bit};
  assign d_rready = 1'b1;

  // ---------------- master-side responses ----------------
  axi_ic_resp u_resp (
    .clk, .rst_n,
    .lo_rd_valid(lo_rd_resp_valid), .lo_rd_id(lo_rd_resp_id), .lo_rd_data(lo_rd_resp_data),
    .hz_rd_fresh(hz_rresp_fresh),
    .lo_wr_valid(lo_wr_resp_valid), .lo_wr_id(lo_wr_resp_id), .lo_wr_resp(lo_wr_resp_resp),
    .m_rd_ready(m_rd_resp_ready), .m_wr_ready(m_wr_resp_ready),
    .rr_v, .rr_id, .rr_data,
    .wr_v(wr_rsp_v), .wr_id(wr_rsp_id), .wr_resp(wr_rsp_resp),
    .li_rd_ready(resp_rd_ready), .li_wr_ready(resp_wr_ready)
  );

  // ---------------- boundary outputs ----------------
  for (genvar m = 0; m < NR; m++) begin : g_o
    assign m_rd_resp_valid[m]  = rr_v[m];
    assign m_rd_resp_id[m]     = rr_id[m];
    assign m_rd_resp_data[m]   = rr_data[m];
    assign m_rd_accepted[m]    = acc_q_rd[m];
    assign m_rd_accepted_id[m] = acc_id_q[m];
    assign li_rd_valid[m]      = stg_rd_v[m];
    assign li_rd_addr[m]       = li_addr;
    assign li_rd_size[m]       = li_size;
    assign li_rd_id[m]         = li_id;
    assign li_rd_bypass[m]     = li_byp;
    assign li_rd_resp_ready[m] = resp_rd_ready[m];
  end
  for (genvar w = 0; w < NW; w++) begin : g_ow
    assign m_wr_accepted[w]    = acc_q_wr[w];
    assign m_wr_resp_valid[w]  = wr_rsp_v[w];
    assign m_wr_resp_id[w]     = wr_rsp_id[w];
    assign m_wr_resp_resp[w]   = wr_rsp_resp[w];
    assign li_wr_valid[w]      = stg_wr_v[w];
    assign li_wr_addr[w]       = li_addr;
    assign li_wr_data[w]       = li_wdata;
    assign li_wr_strb[w]       = li_wstrb;
    assign li_wr_size[w]       = li_size;
    assign li_wr_id[w]         = li_id;
    assign li_wr_bypass[w]     = li_byp;
    assign li_wr_resp_ready[w] = resp_wr_ready[w];
  end
  assign m_rd0_req_ready = rd_ready_o2[0];
  assign m_rd3_req_ready = rd_ready_o2[3];
  assign m_wr1_req_ready = wr_ready_o2[1];

  logic unused_ok;
  assign unused_ok = &{1'b0, rd_ready_o2[1], rd_ready_o2[2], wr_ready_o2[0], wr_sel_first};
endmodule

`default_nettype wire
