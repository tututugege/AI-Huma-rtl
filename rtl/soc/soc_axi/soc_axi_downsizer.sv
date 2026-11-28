// Ref: docs/modules/soc_axi.md  Multi-outstanding Full-AXI4 Data Width Downsizer (S_DATA_W -> M_DATA_W)
`default_nettype none

// Converts a wide AXI4 slave port (e.g. 256-bit) to a narrower AXI4 master port (e.g. 64-bit or 128-bit),
// or acts as a zero-overhead pass-through when S_DATA_W == M_DATA_W.
module soc_axi_downsizer import soc_axi_pkg::*; #(
  parameter int S_DATA_W   = 256,
  parameter int M_DATA_W   = 64,
  parameter int ADDR_W     = 32,
  parameter int ID_W       = 6,
  parameter int MAX_RD_OUT = 16,
  parameter int MAX_WR_OUT = 4
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  s_arvalid,
  output logic                  s_arready,
  input  logic [ID_W-1:0]       s_arid,
  input  logic [ADDR_W-1:0]     s_araddr,
  input  logic [7:0]            s_arlen,
  input  logic [2:0]            s_arsize,
  input  logic [1:0]            s_arburst,
  input  logic                  s_arlock,
  input  logic [3:0]            s_arcache,
  input  logic [2:0]            s_arprot,
  input  logic [3:0]            s_arqos,
  input  logic [3:0]            s_arregion,
  output logic                  s_rvalid,
  input  logic                  s_rready,
  output logic [ID_W-1:0]       s_rid,
  output logic [S_DATA_W-1:0]   s_rdata,
  output logic [1:0]            s_rresp,
  output logic                  s_rlast,
  input  logic                  s_awvalid,
  output logic                  s_awready,
  input  logic [ID_W-1:0]       s_awid,
  input  logic [ADDR_W-1:0]     s_awaddr,
  input  logic [7:0]            s_awlen,
  input  logic [2:0]            s_awsize,
  input  logic [1:0]            s_awburst,
  input  logic                  s_awlock,
  input  logic [3:0]            s_awcache,
  input  logic [2:0]            s_awprot,
  input  logic [3:0]            s_awqos,
  input  logic [3:0]            s_awregion,
  input  logic                  s_wvalid,
  output logic                  s_wready,
  input  logic [S_DATA_W-1:0]   s_wdata,
  input  logic [S_DATA_W/8-1:0] s_wstrb,
  input  logic                  s_wlast,
  output logic                  s_bvalid,
  input  logic                  s_bready,
  output logic [ID_W-1:0]       s_bid,
  output logic [1:0]            s_bresp,
  output logic                  m_arvalid,
  input  logic                  m_arready,
  output logic [ID_W-1:0]       m_arid,
  output logic [ADDR_W-1:0]     m_araddr,
  output logic [7:0]            m_arlen,
  output logic [2:0]            m_arsize,
  output logic [1:0]            m_arburst,
  output logic                  m_arlock,
  output logic [3:0]            m_arcache,
  output logic [2:0]            m_arprot,
  output logic [3:0]            m_arqos,
  output logic [3:0]            m_arregion,
  input  logic                  m_rvalid,
  output logic                  m_rready,
  input  logic [ID_W-1:0]       m_rid,
  input  logic [M_DATA_W-1:0]   m_rdata,
  input  logic [1:0]            m_rresp,
  input  logic                  m_rlast,
  output logic                  m_awvalid,
  input  logic                  m_awready,
  output logic [ID_W-1:0]       m_awid,
  output logic [ADDR_W-1:0]     m_awaddr,
  output logic [7:0]            m_awlen,
  output logic [2:0]            m_awsize,
  output logic [1:0]            m_awburst,
  output logic                  m_awlock,
  output logic [3:0]            m_awcache,
  output logic [2:0]            m_awprot,
  output logic [3:0]            m_awqos,
  output logic [3:0]            m_awregion,
  output logic                  m_wvalid,
  input  logic                  m_wready,
  output logic [M_DATA_W-1:0]   m_wdata,
  output logic [M_DATA_W/8-1:0] m_wstrb,
  output logic                  m_wlast,
  input  logic                  m_bvalid,
  output logic                  m_bready,
  input  logic [ID_W-1:0]       m_bid,
  input  logic [1:0]            m_bresp
);

  localparam int RATIO    = S_DATA_W / M_DATA_W;
  localparam int M_STRB_W = M_DATA_W / 8;
  localparam int S_OFF_W  = $clog2(S_DATA_W / 8);
  localparam int M_OFF_W  = $clog2(M_STRB_W);

  if (RATIO == 1) begin : g_passthru
    assign m_arvalid = s_arvalid; assign s_arready = m_arready; assign m_arid = s_arid;
    assign m_araddr  = s_araddr;  assign m_arlen   = s_arlen;   assign m_arsize = s_arsize;
    assign m_arburst = s_arburst; assign m_arlock  = s_arlock;  assign m_arcache = s_arcache;
    assign m_arprot  = s_arprot;  assign m_arqos   = s_arqos;   assign m_arregion = s_arregion;
    assign s_rvalid  = m_rvalid;  assign m_rready  = s_rready;  assign s_rid = m_rid;
    assign s_rdata   = m_rdata;   assign s_rresp   = m_rresp;   assign s_rlast = m_rlast;
    assign m_awvalid = s_awvalid; assign s_awready = m_awready; assign m_awid = s_awid;
    assign m_awaddr  = s_awaddr;  assign m_awlen   = s_awlen;   assign m_awsize = s_awsize;
    assign m_awburst = s_awburst; assign m_awlock  = s_awlock;  assign m_awcache = s_awcache;
    assign m_awprot  = s_awprot;  assign m_awqos   = s_awqos;   assign m_awregion = s_awregion;
    assign m_wvalid  = s_wvalid;  assign s_wready  = m_wready;  assign m_wdata = s_wdata;
    assign m_wstrb   = s_wstrb;   assign m_wlast   = s_wlast;
    assign s_bvalid  = m_bvalid;  assign m_bready  = s_bready;  assign s_bid = m_bid;
    assign s_bresp   = m_bresp;
    logic [1:0] unused_cr;
    assign unused_cr = {clk, rst_n};
  end else begin : g_down
    localparam int SUB_W  = $clog2(RATIO);
    localparam int WIDX_W = (MAX_WR_OUT > 1) ? $clog2(MAX_WR_OUT) : 1;
    localparam int WCNT_W = $clog2(MAX_WR_OUT + 1);
    localparam int AX_W   = ID_W + ADDR_W + 8 + 3 + 2 + 1 + 4 + 3 + 4 + 4;

    soc_axi_downsizer_rd #(
      .S_DATA_W(S_DATA_W), .M_DATA_W(M_DATA_W), .ADDR_W(ADDR_W), .ID_W(ID_W), .MAX_RD_OUT(MAX_RD_OUT)
    ) u_rd (
      .clk, .rst_n,
      .s_arvalid, .s_arready, .s_arid, .s_araddr, .s_arlen, .s_arsize, .s_arburst,
      .s_arlock, .s_arcache, .s_arprot, .s_arqos, .s_arregion,
      .s_rvalid, .s_rready, .s_rid, .s_rdata, .s_rresp, .s_rlast,
      .m_arvalid, .m_arready, .m_arid, .m_araddr, .m_arlen, .m_arsize, .m_arburst,
      .m_arlock, .m_arcache, .m_arprot, .m_arqos, .m_arregion,
      .m_rvalid, .m_rready, .m_rid, .m_rdata, .m_rresp, .m_rlast
    );

    function automatic logic [SUB_W-1:0] calc_sub_max(input logic [2:0] sz);
      if (int'(sz) <= M_OFF_W) return '0;
      else                     return SUB_W'((32'd1 << (int'(sz) - M_OFF_W)) - 32'd1);
    endfunction

    function automatic logic [7:0] calc_m_len(input logic [7:0] slen, input logic [2:0] sz);
      if (int'(sz) <= M_OFF_W) return slen;
      else                     return 8'(((32'(slen) + 32'd1) << (int'(sz) - M_OFF_W)) - 32'd1);
    endfunction

    function automatic logic [2:0] calc_m_size(input logic [2:0] sz);
      if (int'(sz) <= M_OFF_W) return sz;
      else                     return 3'(M_OFF_W);
    endfunction

    typedef struct packed {
      logic [SUB_W-1:0]  sub_max;
      logic [ADDR_W-1:0] addr;
      logic [2:0]        msize;
      logic [1:0]        burst;
      logic [7:0]        mlen;
    } wr_ent_t;

    wr_ent_t           wr_q [MAX_WR_OUT], wr_d [MAX_WR_OUT];
    logic [WCNT_W-1:0] wr_cnt_q, wr_cnt_d;
    logic [SUB_W-1:0]  w_sub_q, w_sub_d;

    logic              maw_v, maw_r, aw_can_push, aw_fire;
    logic [7:0]        aw_mlen;
    logic [2:0]        aw_msize;
    logic [AX_W-1:0]   maw_pay;

    assign aw_mlen     = calc_m_len(s_awlen, s_awsize);
    assign aw_msize    = calc_m_size(s_awsize);
    assign aw_can_push = (wr_cnt_q < WCNT_W'(MAX_WR_OUT)) && maw_r;
    assign s_awready   = aw_can_push;
    assign aw_fire     = s_awvalid && aw_can_push;
    assign maw_v       = aw_fire;
    assign maw_pay     = {s_awid, s_awaddr, aw_mlen, aw_msize, s_awburst,
                          s_awlock, s_awcache, s_awprot, s_awqos, s_awregion};

    soc_axi_skid #(.WIDTH(AX_W)) u_aw_skid (
      .clk, .rst_n,
      .s_valid(maw_v), .s_ready(maw_r), .s_data(maw_pay),
      .m_valid(m_awvalid), .m_ready(m_awready),
      .m_data({m_awid, m_awaddr, m_awlen, m_awsize, m_awburst,
               m_awlock, m_awcache, m_awprot, m_awqos, m_awregion})
    );

    logic                wr_has_head, w_sub_last, mw_v, mw_r, mw_last;
    logic [SUB_W-1:0]    w_lane;
    logic [M_DATA_W-1:0] mw_data;
    logic [M_STRB_W-1:0] mw_strb;

    assign wr_has_head = (wr_cnt_q != '0);
    assign w_sub_last  = (w_sub_q == wr_q[0].sub_max);
    assign w_lane      = wr_q[0].addr[S_OFF_W-1:M_OFF_W];
    assign mw_v        = wr_has_head && s_wvalid;
    assign mw_data     = s_wdata[M_DATA_W * int'(w_lane) +: M_DATA_W];
    assign mw_strb     = s_wstrb[M_STRB_W * int'(w_lane) +: M_STRB_W];
    assign mw_last     = s_wlast && w_sub_last;
    assign s_wready    = wr_has_head && mw_r && w_sub_last;

    soc_axi_skid #(.WIDTH(M_DATA_W + M_STRB_W + 1)) u_w_skid (
      .clk, .rst_n,
      .s_valid(mw_v), .s_ready(mw_r), .s_data({mw_data, mw_strb, mw_last}),
      .m_valid(m_wvalid), .m_ready(m_wready), .m_data({m_wdata, m_wstrb, m_wlast})
    );

    always_comb begin
      logic              w_beat_fire, w_txn_done;
      logic [WCNT_W-1:0] wcnt_mid;
      w_beat_fire = mw_v && mw_r;
      w_txn_done  = w_beat_fire && mw_last;
      w_sub_d     = w_sub_q;
      wcnt_mid    = wr_cnt_q;
      for (int i = 0; i < MAX_WR_OUT; i++) wr_d[i] = wr_q[i];

      if (w_txn_done) begin
        w_sub_d = '0;
        for (int i = 0; i < MAX_WR_OUT - 1; i++) wr_d[i] = wr_q[i + 1];
        wr_d[MAX_WR_OUT - 1] = '0;
        wcnt_mid = wr_cnt_q - WCNT_W'(1);
      end else if (w_beat_fire) begin
        w_sub_d      = w_sub_last ? '0 : (w_sub_q + SUB_W'(1));
        wr_d[0].addr = axi4_next_addr(wr_q[0].addr, wr_q[0].msize, wr_q[0].burst, wr_q[0].mlen);
      end

      wr_cnt_d = wcnt_mid;
      if (aw_fire) begin
        wr_d[wcnt_mid[WIDX_W-1:0]] = '{
          sub_max: calc_sub_max(s_awsize), addr: s_awaddr,
          msize: aw_msize, burst: s_awburst, mlen: aw_mlen
        };
        wr_cnt_d = wcnt_mid + WCNT_W'(1);
      end
    end

    soc_axi_skid #(.WIDTH(ID_W + 2)) u_b_skid (
      .clk, .rst_n,
      .s_valid(m_bvalid), .s_ready(m_bready), .s_data({m_bid, m_bresp}),
      .m_valid(s_bvalid), .m_ready(s_bready), .m_data({s_bid, s_bresp})
    );

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        wr_cnt_q <= '0;
        w_sub_q  <= '0;
        for (int i = 0; i < MAX_WR_OUT; i++) wr_q[i] <= '0;
      end else begin
        wr_cnt_q <= wr_cnt_d;
        w_sub_q  <= w_sub_d;
        for (int i = 0; i < MAX_WR_OUT; i++) wr_q[i] <= wr_d[i];
      end
    end
  end

endmodule

`default_nettype wire
