// Ref: docs/modules/soc_periph.md  RISC-V CLINT / ACLINT MTIMER (0x1FD0_E000 & 0x0200_0000)
`default_nettype none

// Real hardware CLINT supporting both AI-Huma ttg64gc.dts (0x1FD0_E000) and standard SiFive CLINT (0x0200_0000):
//   0x1FD0_E000: +0x00 mtime (64b), +0x08 mtimecmp (64b), +0x10 msip (1b), +0x18 rtc_cfg (bit0=core_clk_tick)
//   0x0200_0000: +0x0000 msip, +0x4000 mtimecmp, +0xBFF8 mtime
module soc_clint import soc_axi_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        rtc_tick,
  output logic        mtip,
  output logic        msip,
  // 64-bit AXI4-Lite slave
  input  logic        s_arvalid,
  output logic        s_arready,
  input  logic [31:0] s_araddr,
  output logic        s_rvalid,
  input  logic        s_rready,
  output logic [63:0] s_rdata,
  output logic [1:0]  s_rresp,
  input  logic        s_awvalid,
  output logic        s_awready,
  input  logic [31:0] s_awaddr,
  input  logic        s_wvalid,
  output logic        s_wready,
  input  logic [63:0] s_wdata,
  input  logic [7:0]  s_wstrb,
  output logic        s_bvalid,
  input  logic        s_bready,
  output logic [1:0]  s_bresp
);

  logic [63:0] mtime_q, mtime_d;
  logic [63:0] mtimecmp_q, mtimecmp_d;
  logic        msip_q, msip_d;
  logic        fast_tick_q, fast_tick_d;

  logic        rvalid_q, rvalid_d;
  logic [63:0] rdata_q, rdata_d;
  logic        bvalid_q, bvalid_d;
  logic        aw_v_q, aw_v_d, w_v_q, w_v_d;
  logic [31:3] aw_addr_q, aw_addr_d;
  logic [63:0] w_data_q, w_data_d;
  logic [7:0]  w_strb_q, w_strb_d;

  // Decode register target: 0=none, 1=mtime, 2=mtimecmp, 3=msip, 4=rtc_cfg
  function automatic logic [2:0] dec_reg(input logic [31:3] addr);
    if (addr[31:12] == 20'h1FD0E) begin
      case (addr[11:3])
        9'h000:  return 3'd1;   // mtime
        9'h001:  return 3'd2;   // mtimecmp
        9'h002:  return 3'd3;   // msip
        9'h003:  return 3'd4;   // rtc_cfg
        default: return 3'd0;
      endcase
    end else begin
      case (addr[15:3])
        13'h0000: return 3'd3;  // 0x0200_0000 msip
        13'h0800: return 3'd2;  // 0x0200_4000 mtimecmp
        13'h17FF: return 3'd1;  // 0x0200_BFF8 mtime
        default:  return 3'd0;
      endcase
    end
  endfunction

  assign s_arready = !rvalid_q;
  assign s_rvalid  = rvalid_q;
  assign s_rdata   = rdata_q;
  assign s_rresp   = AXI4_RESP_OKAY;
  assign s_awready = !aw_v_q && !bvalid_q;
  assign s_wready  = !w_v_q  && !bvalid_q;
  assign s_bvalid  = bvalid_q;
  assign s_bresp   = AXI4_RESP_OKAY;
  assign mtip      = (mtime_q >= mtimecmp_q);
  assign msip      = msip_q;

  always_comb begin
    rvalid_d = rvalid_q;
    rdata_d  = rdata_q;
    if (rvalid_q && s_rready) rvalid_d = 1'b0;
    if (s_arvalid && s_arready) begin
      rvalid_d = 1'b1;
      case (dec_reg(s_araddr[31:3]))
        3'd1:    rdata_d = mtime_q;
        3'd2:    rdata_d = mtimecmp_q;
        3'd3:    rdata_d = {63'd0, msip_q};
        3'd4:    rdata_d = {63'd0, fast_tick_q};
        default: rdata_d = 64'd0;
      endcase
    end
  end

  always_comb begin
    logic        aw_fire, w_fire, wr_go;
    logic [31:3] wr_addr;
    logic [63:0] wr_data;
    logic [7:0]  wr_strb;
    aw_v_d      = aw_v_q;
    w_v_d       = w_v_q;
    aw_addr_d   = aw_addr_q;
    w_data_d    = w_data_q;
    w_strb_d    = w_strb_q;
    bvalid_d    = bvalid_q;
    mtime_d     = mtime_q + ((rtc_tick || fast_tick_q) ? 64'd1 : 64'd0);
    mtimecmp_d  = mtimecmp_q;
    msip_d      = msip_q;
    fast_tick_d = fast_tick_q;

    if (bvalid_q && s_bready) bvalid_d = 1'b0;
    aw_fire = s_awvalid && s_awready;
    w_fire  = s_wvalid  && s_wready;
    if (aw_fire) begin aw_v_d = 1'b1; aw_addr_d = s_awaddr[31:3]; end
    if (w_fire)  begin w_v_d  = 1'b1; w_data_d  = s_wdata; w_strb_d = s_wstrb; end

    wr_go   = (aw_v_q || aw_fire) && (w_v_q || w_fire) && !bvalid_q;
    wr_addr = aw_v_q ? aw_addr_q : s_awaddr[31:3];
    wr_data = w_v_q  ? w_data_q  : s_wdata;
    wr_strb = w_v_q  ? w_strb_q  : s_wstrb;
    if (wr_go) begin
      aw_v_d   = 1'b0;
      w_v_d    = 1'b0;
      bvalid_d = 1'b1;
      case (dec_reg(wr_addr))
        3'd1: mtime_d     = axi4_apply_strb(mtime_q, wr_data, wr_strb);
        3'd2: mtimecmp_d  = axi4_apply_strb(mtimecmp_q, wr_data, wr_strb);
        3'd3: if (wr_strb[0]) msip_d      = wr_data[0];
        3'd4: if (wr_strb[0]) fast_tick_d = wr_data[0];
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mtime_q     <= 64'd0;
      mtimecmp_q  <= 64'hFFFF_FFFF_FFFF_FFFF;
      msip_q      <= 1'b0;
      fast_tick_q <= 1'b0;
      rvalid_q    <= 1'b0;
      rdata_q     <= 64'd0;
      bvalid_q    <= 1'b0;
      aw_v_q      <= 1'b0;
      w_v_q       <= 1'b0;
      aw_addr_q   <= '0;
      w_data_q    <= 64'd0;
      w_strb_q    <= 8'd0;
    end else begin
      mtime_q     <= mtime_d;
      mtimecmp_q  <= mtimecmp_d;
      msip_q      <= msip_d;
      fast_tick_q <= fast_tick_d;
      rvalid_q    <= rvalid_d;
      rdata_q     <= rdata_d;
      bvalid_q    <= bvalid_d;
      aw_v_q      <= aw_v_d;
      w_v_q       <= w_v_d;
      aw_addr_q   <= aw_addr_d;
      w_data_q    <= w_data_d;
      w_strb_q    <= w_strb_d;
    end
  end

  logic [5:0] unused_addr;
  assign unused_addr = {s_araddr[2:0], s_awaddr[2:0]};

endmodule

`default_nettype wire
