`default_nettype none
// Ref: axi-interconnect-kit/axi_interconnect/AXI_LLC.cpp  class AXI_LLC (comb() final call of a tick + seq()),
// tables from MemSubsystem.cpp
// Top: port adaptation only (flat spec ports <-> packed vectors of axi_llc_core).
// Design note: docs/modules/axi_llc.md
module axi_llc
  import axi_llc_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic up_rd_valid [4],
  input logic [31:0] up_rd_addr [4],
  input logic [7:0] up_rd_size [4],
  input logic [3:0] up_rd_id [4],
  input logic up_rd_bypass [4],
  input logic up_rd_resp_ready [4],
  input logic up_wr_valid [2],
  input logic [31:0] up_wr_addr [2],
  input logic [511:0] up_wr_data [2],
  input logic [63:0] up_wr_strb [2],
  input logic [7:0] up_wr_size [2],
  input logic [3:0] up_wr_id [2],
  input logic up_wr_bypass [2],
  input logic up_wr_resp_ready [2],
  input logic mem_rd_req_ready,
  input logic mem_rd_resp_valid,
  input logic [511:0] mem_rd_resp_data,
  input logic [3:0] mem_rd_resp_id,
  input logic mem_wr_req_ready,
  input logic mem_wr_resp_valid,
  input logic [1:0] mem_wr_resp,
  output logic up_rd_req_ready [4],
  output logic up_rd_resp_valid [4],
  output logic [3:0] up_rd_resp_id [4],
  output logic [511:0] up_rd_resp_data [4],
  output logic up_wr_req_ready [2],
  output logic up_wr_resp_valid [2],
  output logic [3:0] up_wr_resp_id [2],
  output logic [1:0] up_wr_resp_resp [2],
  output logic mem_rd_req_valid,
  output logic [31:0] mem_rd_req_addr,
  output logic [7:0] mem_rd_req_size,
  output logic [3:0] mem_rd_req_id,
  output logic mem_wr_req_valid,
  output logic [31:0] mem_wr_req_addr,
  output logic [511:0] mem_wr_req_data,
  output logic [63:0] mem_wr_req_strb,
  output logic [7:0] mem_wr_req_size,
  output logic [3:0] mem_wr_req_id,
  output logic hz_lookup_valid,
  output logic hz_lookup_is_write,
  output logic [31:0] hz_lookup_addr,
  output logic [1:0] hz_lookup_master,
  output logic [3:0] hz_lookup_id,
  output logic hz_rresp_fresh [4],
  output logic hz_rresp_valid [4],
  output logic [3:0] hz_rresp_id [4],
  output logic hz_mshr_valid [8],
  output logic hz_mshr_is_write [8],
  output logic [1:0] hz_mshr_master [8],
  output logic [3:0] hz_mshr_id [8],
  output logic [31:0] hz_mshr_line [8],
  output logic hz_wctx_valid [2],
  output logic [31:0] hz_wctx_line [2],
  output logic hz_wresp_valid [2],
  output logic [31:0] hz_wresp_line [2]
);
  logic [NR-1:0] rd_v, rd_byp, rd_ready, rd_rdy, rr_valid, hz_rr_fresh;
  logic [NR-1:0][31:0] rd_addr;
  logic [NR-1:0][7:0] rd_size;
  logic [NR-1:0][3:0] rd_id, rr_id;
  logic [NR-1:0][511:0] rr_data;
  logic [NW-1:0] wr_v, wr_byp, wr_ready, wr_rdy, wr_resp_valid, hz_wc_valid;
  logic [NW-1:0][31:0] wr_addr, hz_wc_line, hz_wr_line;
  logic [NW-1:0][7:0] wr_size;
  logic [NW-1:0][3:0] wr_id, wr_resp_id;
  logic [NW-1:0][1:0] wr_resp_code;
  logic [NW-1:0][511:0] wr_data;
  logic [NW-1:0][63:0] wr_strb;
  logic [NMSHR-1:0] hz_ms_valid, hz_ms_is_write;
  logic [NMSHR-1:0][1:0] hz_ms_master;
  logic [NMSHR-1:0][3:0] hz_ms_id;
  logic [NMSHR-1:0][31:0] hz_ms_line;

  // ---- spec ports (unpacked arrays) <-> packed vectors ----
  always_comb begin
    for (int m = 0; m < NR; m++) begin
      rd_v[m] = up_rd_valid[m];
      rd_byp[m] = up_rd_bypass[m];
      rd_ready[m] = up_rd_resp_ready[m];
      rd_addr[m] = up_rd_addr[m];
      rd_size[m] = up_rd_size[m];
      rd_id[m] = up_rd_id[m];
    end
    for (int w = 0; w < NW; w++) begin
      wr_v[w] = up_wr_valid[w];
      wr_byp[w] = up_wr_bypass[w];
      wr_ready[w] = up_wr_resp_ready[w];
      wr_addr[w] = up_wr_addr[w];
      wr_size[w] = up_wr_size[w];
      wr_id[w] = up_wr_id[w];
      wr_data[w] = up_wr_data[w];
      wr_strb[w] = up_wr_strb[w];
    end
  end

  axi_llc_core u_core (
    .clk(clk), .rst_n(rst_n),
    .rd_v(rd_v), .rd_byp(rd_byp), .rd_ready(rd_ready), .rd_addr(rd_addr), .rd_size(rd_size), .rd_id(rd_id),
    .wr_v(wr_v), .wr_byp(wr_byp), .wr_ready(wr_ready), .wr_addr(wr_addr), .wr_size(wr_size), .wr_id(wr_id),
    .wr_data(wr_data), .wr_strb(wr_strb),
    .mrd_ready(mem_rd_req_ready), .mrr_v(mem_rd_resp_valid), .mrr_data(mem_rd_resp_data), .mrr_id(mem_rd_resp_id),
    .mwr_ready(mem_wr_req_ready), .mwr_resp_v(mem_wr_resp_valid), .mwr_resp_code(mem_wr_resp),
    .rd_rdy(rd_rdy), .rr_valid(rr_valid), .rr_id(rr_id), .rr_data(rr_data), .wr_rdy(wr_rdy),
    .wr_resp_valid(wr_resp_valid), .wr_resp_id(wr_resp_id), .wr_resp_code(wr_resp_code),
    .mrd_v(mem_rd_req_valid), .mrd_addr(mem_rd_req_addr), .mrd_size(mem_rd_req_size), .mrd_id(mem_rd_req_id),
    .mwr_v(mem_wr_req_valid), .mwr_addr(mem_wr_req_addr), .mwr_data(mem_wr_req_data), .mwr_strb(mem_wr_req_strb),
    .mwr_size(mem_wr_req_size), .mwr_id(mem_wr_req_id),
    .hz_lk_valid(hz_lookup_valid), .hz_lk_is_write(hz_lookup_is_write), .hz_lk_addr(hz_lookup_addr),
    .hz_lk_master(hz_lookup_master), .hz_lk_id(hz_lookup_id), .hz_rr_fresh(hz_rr_fresh),
    .hz_ms_valid(hz_ms_valid), .hz_ms_is_write(hz_ms_is_write), .hz_ms_master(hz_ms_master), .hz_ms_id(hz_ms_id),
      .hz_ms_line(hz_ms_line),
    .hz_wc_valid(hz_wc_valid), .hz_wc_line(hz_wc_line), .hz_wr_line(hz_wr_line)
  );

  always_comb begin
    for (int m = 0; m < NR; m++) begin
      up_rd_req_ready[m] = rd_rdy[m];
      up_rd_resp_valid[m] = rr_valid[m];
      up_rd_resp_id[m] = rr_id[m];
      up_rd_resp_data[m] = rr_data[m];
      hz_rresp_fresh[m] = hz_rr_fresh[m];
      hz_rresp_valid[m] = rr_valid[m];
      hz_rresp_id[m] = rr_id[m];
    end
    for (int w = 0; w < NW; w++) begin
      up_wr_req_ready[w] = wr_rdy[w];
      up_wr_resp_valid[w] = wr_resp_valid[w];
      up_wr_resp_id[w] = wr_resp_id[w];
      up_wr_resp_resp[w] = wr_resp_code[w];
      hz_wctx_valid[w] = hz_wc_valid[w];
      hz_wctx_line[w] = hz_wc_line[w];
      hz_wresp_valid[w] = wr_resp_valid[w];
      hz_wresp_line[w] = hz_wr_line[w];
    end
    for (int s = 0; s < NMSHR; s++) begin
      hz_mshr_valid[s] = hz_ms_valid[s];
      hz_mshr_is_write[s] = hz_ms_is_write[s];
      hz_mshr_master[s] = hz_ms_master[s];
      hz_mshr_id[s] = hz_ms_id[s];
      hz_mshr_line[s] = hz_ms_line[s];
    end
  end
endmodule

`default_nettype wire
