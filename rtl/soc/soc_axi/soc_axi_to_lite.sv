// Ref: docs/modules/soc_axi.md  Full-AXI4 to AXI4-Lite Peripheral Bridge & Decoder (4 peripherals)
`default_nettype none

// Converts a 64-bit full-AXI4 slave port (arbitrary bursts FIXED/INCR/WRAP, full ID preservation)
// into NP (4) 64-bit AXI4-Lite peripheral ports: 0=CLINT, 1=PLIC, 2=UART, 3=SysCtrl (unmapped -> DECERR).
// Read and Write channels operate completely independently with zero AW/W deadlock.
module soc_axi_to_lite import soc_axi_pkg::*; import soc_pkg::*; #(
  parameter int ID_W = 8,
  parameter int NP   = 4
) (
  input  logic              clk,
  input  logic              rst_n,
  // Full 64-bit AXI4 Slave
  input  logic              s_arvalid,
  output logic              s_arready,
  input  logic [ID_W-1:0]   s_arid,
  input  logic [31:0]       s_araddr,
  input  logic [7:0]        s_arlen,
  input  logic [2:0]        s_arsize,
  input  logic [1:0]        s_arburst,
  input  logic              s_arlock,
  input  logic [3:0]        s_arcache,
  input  logic [2:0]        s_arprot,
  input  logic [3:0]        s_arqos,
  input  logic [3:0]        s_arregion,
  output logic              s_rvalid,
  input  logic              s_rready,
  output logic [ID_W-1:0]   s_rid,
  output logic [63:0]       s_rdata,
  output logic [1:0]        s_rresp,
  output logic              s_rlast,
  input  logic              s_awvalid,
  output logic              s_awready,
  input  logic [ID_W-1:0]   s_awid,
  input  logic [31:0]       s_awaddr,
  input  logic [7:0]        s_awlen,
  input  logic [2:0]        s_awsize,
  input  logic [1:0]        s_awburst,
  input  logic              s_awlock,
  input  logic [3:0]        s_awcache,
  input  logic [2:0]        s_awprot,
  input  logic [3:0]        s_awqos,
  input  logic [3:0]        s_awregion,
  input  logic              s_wvalid,
  output logic              s_wready,
  input  logic [63:0]       s_wdata,
  input  logic [7:0]        s_wstrb,
  input  logic              s_wlast,
  output logic              s_bvalid,
  input  logic              s_bready,
  output logic [ID_W-1:0]   s_bid,
  output logic [1:0]        s_bresp,
  // NP (4) 64-bit AXI4-Lite Master ports: 0=CLINT, 1=PLIC, 2=UART, 3=SysCtrl
  output logic [NP-1:0]     p_arvalid,
  input  logic [NP-1:0]     p_arready,
  output logic [31:0]       p_araddr  [NP],
  input  logic [NP-1:0]     p_rvalid,
  output logic [NP-1:0]     p_rready,
  input  logic [63:0]       p_rdata   [NP],
  input  logic [1:0]        p_rresp   [NP],
  output logic [NP-1:0]     p_awvalid,
  input  logic [NP-1:0]     p_awready,
  output logic [31:0]       p_awaddr  [NP],
  output logic [NP-1:0]     p_wvalid,
  input  logic [NP-1:0]     p_wready,
  output logic [63:0]       p_wdata   [NP],
  output logic [7:0]        p_wstrb   [NP],
  input  logic [NP-1:0]     p_bvalid,
  output logic [NP-1:0]     p_bready,
  input  logic [1:0]        p_bresp   [NP]
);

  // Decode peripheral index: 0=CLINT, 1=PLIC, 2=UART, 3=SysCtrl, 4=DECERR
  function automatic logic [2:0] dec_periph(input logic [31:0] addr);
    logic [2:0] s;
    s = soc_decode_slave(addr);
    case (s)
      3'(SLV_CLINT):   return 3'd0;
      3'(SLV_PLIC):    return 3'd1;
      3'(SLV_UART):    return 3'd2;
      3'(SLV_SYSCTRL): return 3'd3;
      default:         return 3'd4;
    endcase
  endfunction

  // ==================== READ FSM (independent) ====================
  typedef enum logic [1:0] {
    RD_IDLE = 2'd0,
    RD_AR   = 2'd1,
    RD_R    = 2'd2,
    RD_SEND = 2'd3
  } rd_st_e;

  rd_st_e          rd_st_q, rd_st_d;
  logic [ID_W-1:0] rd_id_q, rd_id_d;
  logic [31:0]     rd_addr_q, rd_addr_d;
  logic [7:0]      rd_len_q, rd_len_d, rd_rem_q, rd_rem_d;
  logic [2:0]      rd_size_q, rd_size_d, rd_sel_q, rd_sel_d;
  logic [1:0]      rd_burst_q, rd_burst_d, rd_resp_q, rd_resp_d;
  logic [63:0]     rd_data_q, rd_data_d;

  assign s_arready = (rd_st_q == RD_IDLE);
  assign s_rvalid  = (rd_st_q == RD_SEND);
  assign s_rid     = rd_id_q;
  assign s_rdata   = rd_data_q;
  assign s_rresp   = rd_resp_q;
  assign s_rlast   = (rd_rem_q == 8'd0);

  always_comb begin
    p_arvalid = '0;
    p_rready  = '0;
    for (int i = 0; i < NP; i++) p_araddr[i] = rd_addr_q;
    if (rd_st_q == RD_AR && rd_sel_q < 3'(NP)) p_arvalid[rd_sel_q[1:0]] = 1'b1;
    if (rd_st_q == RD_R  && rd_sel_q < 3'(NP)) p_rready[rd_sel_q[1:0]]  = 1'b1;
  end

  always_comb begin
    logic [31:0] na;
    rd_st_d    = rd_st_q;
    rd_id_d    = rd_id_q;
    rd_addr_d  = rd_addr_q;
    rd_len_d   = rd_len_q;
    rd_rem_d   = rd_rem_q;
    rd_size_d  = rd_size_q;
    rd_burst_d = rd_burst_q;
    rd_sel_d   = rd_sel_q;
    rd_data_d  = rd_data_q;
    rd_resp_d  = rd_resp_q;
    na         = axi4_next_addr(rd_addr_q, rd_size_q, rd_burst_q, rd_len_q);

    case (rd_st_q)
      RD_IDLE: begin
        if (s_arvalid) begin
          rd_id_d    = s_arid;
          rd_addr_d  = s_araddr;
          rd_len_d   = s_arlen;
          rd_rem_d   = s_arlen;
          rd_size_d  = s_arsize;
          rd_burst_d = s_arburst;
          rd_sel_d   = dec_periph(s_araddr);
          rd_st_d    = RD_AR;
        end
      end
      RD_AR: begin
        if (rd_sel_q >= 3'(NP)) begin
          rd_data_d = 64'd0;
          rd_resp_d = AXI4_RESP_DECERR;
          rd_st_d   = RD_SEND;
        end else if (p_arready[rd_sel_q[1:0]]) begin
          rd_st_d = RD_R;
        end
      end
      RD_R: begin
        if (p_rvalid[rd_sel_q[1:0]]) begin
          rd_data_d = p_rdata[rd_sel_q[1:0]];
          rd_resp_d = p_rresp[rd_sel_q[1:0]];
          rd_st_d   = RD_SEND;
        end
      end
      default: begin
        if (s_rready) begin
          if (rd_rem_q == 8'd0) begin
            rd_st_d = RD_IDLE;
          end else begin
            rd_rem_d  = rd_rem_q - 8'd1;
            rd_addr_d = na;
            rd_sel_d  = dec_periph(na);
            rd_st_d   = RD_AR;
          end
        end
      end
    endcase
  end

  // ==================== WRITE FSM (independent, AW decoupled from W) ====================
  typedef enum logic [2:0] {
    WR_IDLE = 3'd0,
    WR_W    = 3'd1,
    WR_REQ  = 3'd2,
    WR_BRSP = 3'd3,
    WR_SEND = 3'd4
  } wr_st_e;

  wr_st_e          wr_st_q, wr_st_d;
  logic [ID_W-1:0] wr_id_q, wr_id_d;
  logic [31:0]     wr_addr_q, wr_addr_d;
  logic [7:0]      wr_len_q, wr_len_d;
  logic [2:0]      wr_size_q, wr_size_d, wr_sel_q, wr_sel_d;
  logic [1:0]      wr_burst_q, wr_burst_d, wr_resp_q, wr_resp_d;
  logic [63:0]     wr_data_q, wr_data_d;
  logic [7:0]      wr_strb_q, wr_strb_d;
  logic            wr_last_q, wr_last_d;
  logic            aw_done_q, aw_done_d, w_done_q, w_done_d;

  assign s_awready = (wr_st_q == WR_IDLE);
  assign s_wready  = (wr_st_q == WR_W);
  assign s_bvalid  = (wr_st_q == WR_SEND);
  assign s_bid     = wr_id_q;
  assign s_bresp   = wr_resp_q;

  always_comb begin
    p_awvalid = '0;
    p_wvalid  = '0;
    p_bready  = '0;
    for (int i = 0; i < NP; i++) begin
      p_awaddr[i] = wr_addr_q;
      p_wdata[i]  = wr_data_q;
      p_wstrb[i]  = wr_strb_q;
    end
    if (wr_st_q == WR_REQ && wr_sel_q < 3'(NP)) begin
      p_awvalid[wr_sel_q[1:0]] = !aw_done_q;
      p_wvalid[wr_sel_q[1:0]]  = !w_done_q;
    end
    if (wr_st_q == WR_BRSP && wr_sel_q < 3'(NP)) p_bready[wr_sel_q[1:0]] = 1'b1;
  end

  logic        wr_beat_done, wr_adv_addr;
  logic [1:0]  wr_beat_resp;

  always_comb begin
    logic aw_now, w_now;
    aw_now       = 1'b0;
    w_now        = 1'b0;
    wr_st_d      = wr_st_q;
    aw_done_d    = aw_done_q;
    w_done_d     = w_done_q;
    wr_beat_done = 1'b0;
    wr_adv_addr  = 1'b0;
    wr_beat_resp = AXI4_RESP_OKAY;

    case (wr_st_q)
      WR_IDLE: if (s_awvalid) wr_st_d = WR_W;
      WR_W:    if (s_wvalid)  begin aw_done_d = 1'b0; w_done_d = 1'b0; wr_st_d = WR_REQ; end
      WR_REQ: begin
        if (wr_sel_q >= 3'(NP)) begin
          wr_beat_done = 1'b1;
          wr_beat_resp = AXI4_RESP_DECERR;
          wr_adv_addr  = !wr_last_q;
          wr_st_d      = wr_last_q ? WR_SEND : WR_W;
        end else begin
          aw_now    = aw_done_q || p_awready[wr_sel_q[1:0]];
          w_now     = w_done_q  || p_wready[wr_sel_q[1:0]];
          aw_done_d = aw_now;
          w_done_d  = w_now;
          if (aw_now && w_now) wr_st_d = WR_BRSP;
        end
      end
      WR_BRSP: begin
        if (p_bvalid[wr_sel_q[1:0]]) begin
          wr_beat_done = 1'b1;
          wr_beat_resp = p_bresp[wr_sel_q[1:0]];
          wr_adv_addr  = !wr_last_q;
          wr_st_d      = wr_last_q ? WR_SEND : WR_W;
        end
      end
      default: if (s_bready) wr_st_d = WR_IDLE;
    endcase
  end

  always_comb begin
    logic [31:0] na;
    wr_id_d    = wr_id_q;
    wr_addr_d  = wr_addr_q;
    wr_len_d   = wr_len_q;
    wr_size_d  = wr_size_q;
    wr_burst_d = wr_burst_q;
    wr_sel_d   = wr_sel_q;
    wr_resp_d  = wr_resp_q;
    wr_data_d  = wr_data_q;
    wr_strb_d  = wr_strb_q;
    wr_last_d  = wr_last_q;
    na         = axi4_next_addr(wr_addr_q, wr_size_q, wr_burst_q, wr_len_q);

    if (wr_st_q == WR_IDLE && s_awvalid) begin
      wr_id_d    = s_awid;    wr_addr_d  = s_awaddr;  wr_len_d  = s_awlen;
      wr_size_d  = s_awsize;  wr_burst_d = s_awburst; wr_sel_d  = dec_periph(s_awaddr);
      wr_resp_d  = AXI4_RESP_OKAY;
    end
    if (wr_st_q == WR_W && s_wvalid) begin
      wr_data_d = s_wdata; wr_strb_d = s_wstrb; wr_last_d = s_wlast;
    end
    if (wr_beat_done) wr_resp_d = axi4_merge_resp(wr_resp_q, wr_beat_resp);
    if (wr_adv_addr) begin
      wr_addr_d = na;
      wr_sel_d  = dec_periph(na);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_st_q <= RD_IDLE; rd_id_q <= '0; rd_addr_q <= 32'd0; rd_len_q <= 8'd0; rd_rem_q <= 8'd0;
      rd_size_q <= 3'd0; rd_burst_q <= 2'd0; rd_sel_q <= 3'd0; rd_data_q <= 64'd0; rd_resp_q <= 2'd0;
      wr_st_q <= WR_IDLE; wr_id_q <= '0; wr_addr_q <= 32'd0; wr_len_q <= 8'd0;
      wr_size_q <= 3'd0; wr_burst_q <= 2'd0; wr_sel_q <= 3'd0; wr_resp_q <= 2'd0;
      wr_data_q <= 64'd0; wr_strb_q <= 8'd0; wr_last_q <= 1'b0; aw_done_q <= 1'b0; w_done_q <= 1'b0;
    end else begin
      rd_st_q <= rd_st_d; rd_id_q <= rd_id_d; rd_addr_q <= rd_addr_d; rd_len_q <= rd_len_d;
      rd_rem_q <= rd_rem_d; rd_size_q <= rd_size_d; rd_burst_q <= rd_burst_d; rd_sel_q <= rd_sel_d;
      rd_data_q <= rd_data_d; rd_resp_q <= rd_resp_d;
      wr_st_q <= wr_st_d; wr_id_q <= wr_id_d; wr_addr_q <= wr_addr_d; wr_len_q <= wr_len_d;
      wr_size_q <= wr_size_d; wr_burst_q <= wr_burst_d; wr_sel_q <= wr_sel_d; wr_resp_q <= wr_resp_d;
      wr_data_q <= wr_data_d; wr_strb_q <= wr_strb_d; wr_last_q <= wr_last_d;
      aw_done_q <= aw_done_d; w_done_q <= w_done_d;
    end
  end

  logic unused_attr;
  assign unused_attr = &{1'b0, s_arlock, s_arcache, s_arprot, s_arqos, s_arregion,
                         s_awlock, s_awcache, s_awprot, s_awqos, s_awregion};

endmodule

`default_nettype wire
