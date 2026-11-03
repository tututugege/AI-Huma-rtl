`default_nettype none
// Ref: axi-interconnect-kit/axi_interconnect/AXI_LLC.cpp  class AXI_LLC (comb() final call of a tick + seq()),
// tables from MemSubsystem.cpp
// Top: port adaptation (flat spec ports <-> in_t), register file `r_q`, the five stage modules chained in C++
// order, the tables.
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
  st_t r_q;
  in_t in_w;
  ch_t c0, c1, c2, c3, c4, c5;
  logic t_ok;
  logic [WAYS-1:0] t_v, t_d;
  logic [WAYS-1:0][TAGW-1:0] t_t;
  logic [WAYS-1:0][511:0] t_line;
  logic [WB-1:0] t_repl;

  // ---- input packing ----
  always_comb begin
    in_w = IN_ZERO;
    for (int m = 0; m < NR; m++) begin
      in_w.rd_v[m] = up_rd_valid[m];
      in_w.rd_byp[m] = up_rd_bypass[m];
      in_w.rd_ready[m] = up_rd_resp_ready[m];
      in_w.rd_addr[m] = up_rd_addr[m];
      in_w.rd_size[m] = up_rd_size[m];
      in_w.rd_id[m] = up_rd_id[m];
    end
    for (int w = 0; w < NW; w++) begin
      in_w.wr_v[w] = up_wr_valid[w];
      in_w.wr_byp[w] = up_wr_bypass[w];
      in_w.wr_ready[w] = up_wr_resp_ready[w];
      in_w.wr_addr[w] = up_wr_addr[w];
      in_w.wr_size[w] = up_wr_size[w];
      in_w.wr_id[w] = up_wr_id[w];
      in_w.wr_data[w] = up_wr_data[w];
      in_w.wr_strb[w] = up_wr_strb[w];
    end
    in_w.mrd_ready = mem_rd_req_ready;
    in_w.mrr_v = mem_rd_resp_valid;
    in_w.mrr_data = mem_rd_resp_data;
    in_w.mrr_id = mem_rd_resp_id;
    in_w.mwr_ready = mem_wr_req_ready;
    in_w.mwr_resp_v = mem_wr_resp_valid;
    in_w.mwr_resp = mem_wr_resp;
    in_w.lk_ok = t_ok;
    in_w.lk_v = t_v;
    in_w.lk_d = t_d;
    in_w.lk_t = t_t;
    in_w.lk_line = t_line;
    in_w.lk_repl = t_repl;
  end

  // ---- stage chain (C++ comb() order); reg_write starts as a copy of the registers ----
  always_comb begin
    c0 = CH_ZERO;
    c0.n = r_q;
  end
  axi_llc_s1_rresp  u_s1 (.r(r_q), .i(in_w), .ci(c0), .co(c1));
  axi_llc_s2_wpath  u_s2 (.r(r_q), .i(in_w), .ci(c1), .co(c2));
  axi_llc_s3_lookup u_s3 (.r(r_q), .i(in_w), .ci(c2), .co(c3));
  axi_llc_s4_mem    u_s4 (.r(r_q), .i(in_w), .ci(c3), .co(c4));
  axi_llc_s5_accept u_s5 (.r(r_q), .i(in_w), .ci(c4), .co(c5));

  always_ff @(posedge clk) begin
    if (!rst_n) r_q <= ST_ZERO;
    else        r_q <= c5.n;
  end

  axi_llc_tables u_tables (
    .clk(clk), .rst_n(rst_n), .rd_req(c5.trd), .rd_set(c5.trd_set),
    .wd(c5.wd), .wm(c5.wm), .wv(c5.wv), .wr(c5.wr), .tset(c5.tset), .tway(c5.tway), .tdata(c5.tdata),
    .ttag(c5.ttag), .tdirty(c5.tdirty), .trepl(c5.trepl),
    .lk_ok(t_ok), .lk_v(t_v), .lk_d(t_d), .lk_t(t_t), .lk_line(t_line), .lk_repl(t_repl)
  );

  // ---- outputs ----
  always_comb begin
    for (int m = 0; m < NR; m++) begin
      up_rd_req_ready[m] = c5.rd_rdy[m];
      up_rd_resp_valid[m] = r_q.rr[m].valid;
      up_rd_resp_id[m] = r_q.rr[m].id;
      up_rd_resp_data[m] = r_q.rr[m].data;
    end
    for (int w = 0; w < NW; w++) begin
      up_wr_req_ready[w] = c5.wr_rdy[w];
      up_wr_resp_valid[w] = r_q.wr[w].valid;
      up_wr_resp_id[w] = r_q.wr[w].id;
      up_wr_resp_resp[w] = r_q.wr[w].code;
    end
    mem_rd_req_valid = c5.mrd_v;
    mem_rd_req_addr = c5.mrd_addr;
    mem_rd_req_size = c5.mrd_size;
    mem_rd_req_id = c5.mrd_id;
    mem_wr_req_valid = c5.mwr_v;
    mem_wr_req_addr = c5.mwr_addr;
    mem_wr_req_data = c5.mwr_data;
    mem_wr_req_strb = '1;
    mem_wr_req_size = 8'd63;
    mem_wr_req_id = 4'd0;
  end

  // ---- registers read by the interconnect (hazard / id-conflict checks) ----
  always_comb begin
    hz_lookup_valid = r_q.lv;
    hz_lookup_is_write = r_q.lw;
    hz_lookup_addr = r_q.laddr;
    hz_lookup_master = r_q.lmaster;
    hz_lookup_id = r_q.lid;
    for (int m = 0; m < NR; m++) begin
      hz_rresp_fresh[m] = r_q.rr[m].fresh;
      hz_rresp_valid[m] = r_q.rr[m].valid;
      hz_rresp_id[m] = r_q.rr[m].id;
    end
    for (int s = 0; s < NMSHR; s++) begin
      hz_mshr_valid[s] = r_q.ms[s].valid;
      hz_mshr_is_write[s] = 1'b0;  // partial-line write misses are never allocated (docs/modules/axi_llc.md section 2)
      hz_mshr_master[s] = r_q.ms[s].master;
      hz_mshr_id[s] = r_q.ms[s].id;
      hz_mshr_line[s] = r_q.ms[s].bypass ? r_q.ms[s].addr : line_of(r_q.ms[s].addr);
    end
    for (int w = 0; w < NW; w++) begin
      hz_wctx_valid[w] = r_q.wc[w].valid;
      hz_wctx_line[w] = line_of(r_q.wc[w].addr);
      hz_wresp_valid[w] = r_q.wr[w].valid;
      hz_wresp_line[w] = r_q.wr[w].line;
    end
  end

`ifndef SYNTHESIS
  // C++ paths the coverage analysis showed unreachable, and the queue-depth bounds
  assert property (@(posedge clk) disable iff (!rst_n) !c5.bad)
      else $error("axi_llc: unreachable path taken");
  // the C++ queues are 32 deep; the RTL depths (RQD/WQD/VQD) are never reached in any measured run
  for (genvar m = 0; m < NR; m++) begin : g_rq_bound
    assert property (@(posedge clk) disable iff (!rst_n) c5.n.rr[m].qcnt < 2'(RQD))
      else $error("axi_llc: read resp queue full");
  end
  for (genvar w = 0; w < NW; w++) begin : g_wq_bound
    assert property (@(posedge clk) disable iff (!rst_n) c5.n.wq[w].cnt < 2'(WQD))
      else $error("axi_llc: write queue full");
  end
  assert property (@(posedge clk) disable iff (!rst_n) c5.n.rvq.cnt < vq_cnt_t'(VQD))
      else $error("axi_llc: victim queue full");
`endif
endmodule

`default_nettype wire
