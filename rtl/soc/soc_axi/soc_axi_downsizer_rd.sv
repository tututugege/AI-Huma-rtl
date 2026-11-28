// Ref: docs/modules/soc_axi.md  Multi-outstanding Full-AXI4 Read Width Downsizer (S_DATA_W -> M_DATA_W)
`default_nettype none

module soc_axi_downsizer_rd import soc_axi_pkg::*; #(
  parameter int S_DATA_W   = 256,
  parameter int M_DATA_W   = 64,
  parameter int ADDR_W     = 32,
  parameter int ID_W       = 6,
  parameter int MAX_RD_OUT = 16
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                s_arvalid,
  output logic                s_arready,
  input  logic [ID_W-1:0]     s_arid,
  input  logic [ADDR_W-1:0]   s_araddr,
  input  logic [7:0]          s_arlen,
  input  logic [2:0]          s_arsize,
  input  logic [1:0]          s_arburst,
  input  logic                s_arlock,
  input  logic [3:0]          s_arcache,
  input  logic [2:0]          s_arprot,
  input  logic [3:0]          s_arqos,
  input  logic [3:0]          s_arregion,
  output logic                s_rvalid,
  input  logic                s_rready,
  output logic [ID_W-1:0]     s_rid,
  output logic [S_DATA_W-1:0] s_rdata,
  output logic [1:0]          s_rresp,
  output logic                s_rlast,
  output logic                m_arvalid,
  input  logic                m_arready,
  output logic [ID_W-1:0]     m_arid,
  output logic [ADDR_W-1:0]   m_araddr,
  output logic [7:0]          m_arlen,
  output logic [2:0]          m_arsize,
  output logic [1:0]          m_arburst,
  output logic                m_arlock,
  output logic [3:0]          m_arcache,
  output logic [2:0]          m_arprot,
  output logic [3:0]          m_arqos,
  output logic [3:0]          m_arregion,
  input  logic                m_rvalid,
  output logic                m_rready,
  input  logic [ID_W-1:0]     m_rid,
  input  logic [M_DATA_W-1:0] m_rdata,
  input  logic [1:0]          m_rresp,
  input  logic                m_rlast
);

  localparam int RATIO   = S_DATA_W / M_DATA_W;
  localparam int S_OFF_W = $clog2(S_DATA_W / 8);
  localparam int M_OFF_W = $clog2(M_DATA_W / 8);
  localparam int SUB_W   = (RATIO > 1) ? $clog2(RATIO) : 1;
  localparam int RIDX_W  = (MAX_RD_OUT > 1) ? $clog2(MAX_RD_OUT) : 1;
  localparam int RCNT_W  = $clog2(MAX_RD_OUT + 1);
  localparam int AX_W    = ID_W + ADDR_W + 8 + 3 + 2 + 1 + 4 + 3 + 4 + 4;

  typedef struct packed {
    logic [ID_W-1:0]     id;
    logic [SUB_W-1:0]    sub_max;
    logic [SUB_W-1:0]    sub_cnt;
    logic [ADDR_W-1:0]   addr;
    logic [2:0]          msize;
    logic [1:0]          burst;
    logic [7:0]          mlen;
    logic [7:0]          wide_rem;
    logic [1:0]          resp;
    logic [S_DATA_W-1:0] buf_data;
  } rd_ent_t;

  rd_ent_t           rd_q [MAX_RD_OUT], rd_mid [MAX_RD_OUT], rd_d [MAX_RD_OUT];
  logic [RCNT_W-1:0] rd_cnt_q, rd_cnt_mid, rd_cnt_d;

  logic                out_rv_q, out_rv_d;
  logic [ID_W-1:0]     out_rid_q, out_rid_d;
  logic [S_DATA_W-1:0] out_rdata_q, out_rdata_d;
  logic [1:0]          out_rresp_q, out_rresp_d;
  logic                out_rlast_q, out_rlast_d;

  logic              mar_v, mar_r, ar_can_push, ar_fire;
  logic [7:0]        ar_mlen;
  logic [2:0]        ar_msize;
  logic [AX_W-1:0]   mar_pay;

  assign ar_mlen     = axi4_ds_m_len(s_arlen, s_arsize, M_OFF_W);
  assign ar_msize    = axi4_ds_m_size(s_arsize, M_OFF_W);
  assign ar_can_push = (rd_cnt_q < RCNT_W'(MAX_RD_OUT)) && mar_r;
  assign s_arready   = ar_can_push;
  assign ar_fire     = s_arvalid && ar_can_push;
  assign mar_v       = ar_fire;
  assign mar_pay     = {s_arid, s_araddr, ar_mlen, ar_msize, s_arburst,
                        s_arlock, s_arcache, s_arprot, s_arqos, s_arregion};

  soc_axi_skid #(.WIDTH(AX_W)) u_ar_skid (
    .clk, .rst_n,
    .s_valid(mar_v), .s_ready(mar_r), .s_data(mar_pay),
    .m_valid(m_arvalid), .m_ready(m_arready),
    .m_data({m_arid, m_araddr, m_arlen, m_arsize, m_arburst,
             m_arlock, m_arcache, m_arprot, m_arqos, m_arregion})
  );

  assign s_rvalid = out_rv_q;
  assign s_rid    = out_rid_q;
  assign s_rdata  = out_rdata_q;
  assign s_rresp  = out_rresp_q;
  assign s_rlast  = out_rlast_q;
  assign m_rready = !out_rv_q || s_rready;

  // Stage 1: match oldest outstanding entry for incoming m_rid
  logic              r_hit_v;
  logic [RIDX_W-1:0] r_hit_idx;
  always_comb begin
    r_hit_v   = 1'b0;
    r_hit_idx = '0;
    for (int i = 0; i < MAX_RD_OUT; i++) begin
      if (!r_hit_v && (RCNT_W'(i) < rd_cnt_q) && (rd_q[i].id == m_rid)) begin
        r_hit_v   = 1'b1;
        r_hit_idx = RIDX_W'(i);
      end
    end
  end

  // Stage 2: process incoming R beat and produce registered wide R output
  always_comb begin
    logic                r_fire, beat_done, txn_done;
    logic [S_DATA_W-1:0] new_buf;
    logic [1:0]          new_resp;
    logic [SUB_W-1:0]    lane;
    rd_ent_t             cur;

    r_fire      = m_rvalid && m_rready && r_hit_v;
    cur         = rd_q[r_hit_idx];
    lane        = cur.addr[S_OFF_W-1:M_OFF_W];
    new_buf     = cur.buf_data;
    new_buf[M_DATA_W * int'(lane) +: M_DATA_W] = m_rdata;
    new_resp    = axi4_merge_resp(cur.resp, m_rresp);
    beat_done   = (cur.sub_cnt == cur.sub_max) || m_rlast;
    txn_done    = (beat_done && (cur.wide_rem == 8'd0)) || m_rlast;

    out_rv_d    = (out_rv_q && !s_rready) ? 1'b1 : 1'b0;
    out_rid_d   = out_rid_q;
    out_rdata_d = out_rdata_q;
    out_rresp_d = out_rresp_q;
    out_rlast_d = out_rlast_q;
    rd_cnt_mid  = rd_cnt_q;
    for (int i = 0; i < MAX_RD_OUT; i++) rd_mid[i] = rd_q[i];

    if (r_fire) begin
      if (beat_done) begin
        out_rv_d = 1'b1; out_rid_d = cur.id; out_rdata_d = new_buf;
        out_rresp_d = new_resp; out_rlast_d = txn_done;
      end
      if (txn_done) begin
        for (int i = 0; i < MAX_RD_OUT - 1; i++)
          if (RIDX_W'(i) >= r_hit_idx) rd_mid[i] = rd_q[i + 1];
        rd_mid[MAX_RD_OUT - 1] = '0;
        rd_cnt_mid = rd_cnt_q - RCNT_W'(1);
      end else begin
        rd_mid[r_hit_idx].addr = axi4_next_addr(cur.addr, cur.msize, cur.burst, cur.mlen);
        if (beat_done) begin
          rd_mid[r_hit_idx].sub_cnt  = '0;
          rd_mid[r_hit_idx].wide_rem = cur.wide_rem - 8'd1;
          rd_mid[r_hit_idx].resp     = AXI4_RESP_OKAY;
          rd_mid[r_hit_idx].buf_data = '0;
        end else begin
          rd_mid[r_hit_idx].sub_cnt  = cur.sub_cnt + SUB_W'(1);
          rd_mid[r_hit_idx].resp     = new_resp;
          rd_mid[r_hit_idx].buf_data = new_buf;
        end
      end
    end
  end

  // Stage 3: push new AR transaction at tail of FIFO
  always_comb begin
    for (int i = 0; i < MAX_RD_OUT; i++) rd_d[i] = rd_mid[i];
    rd_cnt_d = rd_cnt_mid;
    if (ar_fire) begin
      rd_d[rd_cnt_mid[RIDX_W-1:0]] = '{
        id: s_arid, sub_max: SUB_W'(axi4_ds_sub_max(s_arsize, M_OFF_W)), sub_cnt: '0,
        addr: s_araddr, msize: ar_msize, burst: s_arburst, mlen: ar_mlen,
        wide_rem: s_arlen, resp: AXI4_RESP_OKAY, buf_data: '0
      };
      rd_cnt_d = rd_cnt_mid + RCNT_W'(1);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_cnt_q <= '0; out_rv_q <= 1'b0; out_rid_q <= '0;
      out_rdata_q <= '0; out_rresp_q <= AXI4_RESP_OKAY; out_rlast_q <= 1'b0;
      for (int i = 0; i < MAX_RD_OUT; i++) rd_q[i] <= '0;
    end else begin
      rd_cnt_q <= rd_cnt_d; out_rv_q <= out_rv_d; out_rid_q <= out_rid_d;
      out_rdata_q <= out_rdata_d; out_rresp_q <= out_rresp_d; out_rlast_q <= out_rlast_d;
      for (int i = 0; i < MAX_RD_OUT; i++) rd_q[i] <= rd_d[i];
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk) disable iff (!rst_n) !(m_rvalid && m_rready && !r_hit_v))
    else $error("soc_axi_downsizer_rd: unexpected m_rid=%0d", m_rid);
`endif

endmodule

`default_nettype wire
