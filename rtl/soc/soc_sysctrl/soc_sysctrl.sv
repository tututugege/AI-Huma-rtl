// Ref: docs/modules/soc_periph.md  SoC System Control registers (0x1F00_0000)
`default_nettype none

// SysCtrl 64-bit AXI4-Lite slave:
//   +0x00 CHIP_ID    (RO): 64'h0001_0000_4855_4D41 ("HUMA", rev 1.0)
//   +0x08 BOOT_STAT  (RO): {62'd0, boot_mode}
//   +0x10 RST_CTL    (WO): write 32'h5A5A_0001 triggers 4-cycle sw_rst_req pulse
//   +0x18 CORE_CTL   (RW): bring-up control register (reset 64'd1: pf_en=1)
//   +0x20 SCRATCH0   (RW): 64-bit scratchpad
//   +0x28 SCRATCH1   (RW): 64-bit scratchpad
//   +0x30 UPTIME     (RO): 64-bit free-running cycle counter
module soc_sysctrl import soc_axi_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [1:0]  boot_mode,
  output logic        sw_rst_req,
  output logic [63:0] core_ctl_out,
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

  localparam logic [63:0] CHIP_ID_VAL = 64'h0001_0000_4855_4D41;
  localparam logic [31:0] RST_MAGIC   = 32'h5A5A_0001;

  logic [63:0] core_ctl_q, core_ctl_d;
  logic [63:0] scratch0_q, scratch0_d;
  logic [63:0] scratch1_q, scratch1_d;
  logic [63:0] uptime_q, uptime_d;
  logic [2:0]  rst_cnt_q, rst_cnt_d;

  logic        rvalid_q, rvalid_d;
  logic [63:0] rdata_q, rdata_d;
  logic        bvalid_q, bvalid_d;
  logic        aw_v_q, aw_v_d, w_v_q, w_v_d;
  logic [4:0]  aw_reg_q, aw_reg_d;
  logic [63:0] w_data_q, w_data_d;
  logic [7:0]  w_strb_q, w_strb_d;

  function automatic logic [63:0] apply_strb(
    input logic [63:0] old_v, input logic [63:0] new_v, input logic [7:0] strb
  );
    logic [63:0] res;
    for (int b = 0; b < 8; b++) res[8*b +: 8] = strb[b] ? new_v[8*b +: 8] : old_v[8*b +: 8];
    return res;
  endfunction

  assign s_arready    = !rvalid_q;
  assign s_rvalid     = rvalid_q;
  assign s_rdata      = rdata_q;
  assign s_rresp      = AXI4_RESP_OKAY;
  assign s_awready    = !aw_v_q && !bvalid_q;
  assign s_wready     = !w_v_q  && !bvalid_q;
  assign s_bvalid     = bvalid_q;
  assign s_bresp      = AXI4_RESP_OKAY;
  assign sw_rst_req   = (rst_cnt_q != 3'd0);
  assign core_ctl_out = core_ctl_q;

  // Read channel + uptime
  always_comb begin
    rvalid_d = rvalid_q;
    rdata_d  = rdata_q;
    uptime_d = uptime_q + 64'd1;
    if (rvalid_q && s_rready) rvalid_d = 1'b0;
    if (s_arvalid && s_arready) begin
      rvalid_d = 1'b1;
      case (s_araddr[7:3])
        5'h00:   rdata_d = CHIP_ID_VAL;
        5'h01:   rdata_d = {62'd0, boot_mode};
        5'h02:   rdata_d = 64'd0;
        5'h03:   rdata_d = core_ctl_q;
        5'h04:   rdata_d = scratch0_q;
        5'h05:   rdata_d = scratch1_q;
        5'h06:   rdata_d = uptime_q;
        default: rdata_d = 64'd0;
      endcase
    end
  end

  // Write channel + register update
  always_comb begin
    logic        aw_fire, w_fire, wr_go;
    logic [4:0]  wr_reg;
    logic [63:0] wr_data;
    logic [7:0]  wr_strb;
    aw_v_d     = aw_v_q;
    w_v_d      = w_v_q;
    aw_reg_d   = aw_reg_q;
    w_data_d   = w_data_q;
    w_strb_d   = w_strb_q;
    bvalid_d   = bvalid_q;
    core_ctl_d = core_ctl_q;
    scratch0_d = scratch0_q;
    scratch1_d = scratch1_q;
    rst_cnt_d  = (rst_cnt_q != 3'd0) ? (rst_cnt_q - 3'd1) : 3'd0;

    if (bvalid_q && s_bready) bvalid_d = 1'b0;
    aw_fire = s_awvalid && s_awready;
    w_fire  = s_wvalid  && s_wready;
    if (aw_fire) begin aw_v_d = 1'b1; aw_reg_d = s_awaddr[7:3]; end
    if (w_fire)  begin w_v_d  = 1'b1; w_data_d = s_wdata; w_strb_d = s_wstrb; end

    wr_go   = (aw_v_q || aw_fire) && (w_v_q || w_fire) && !bvalid_q;
    wr_reg  = aw_v_q ? aw_reg_q : s_awaddr[7:3];
    wr_data = w_v_q  ? w_data_q : s_wdata;
    wr_strb = w_v_q  ? w_strb_q : s_wstrb;
    if (wr_go) begin
      aw_v_d   = 1'b0;
      w_v_d    = 1'b0;
      bvalid_d = 1'b1;
      case (wr_reg)
        5'h02: if (wr_strb[3:0] == 4'hF && wr_data[31:0] == RST_MAGIC) rst_cnt_d = 3'd4;
        5'h03: core_ctl_d = apply_strb(core_ctl_q, wr_data, wr_strb);
        5'h04: scratch0_d = apply_strb(scratch0_q, wr_data, wr_strb);
        5'h05: scratch1_d = apply_strb(scratch1_q, wr_data, wr_strb);
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      core_ctl_q <= 64'd1;
      scratch0_q <= 64'd0;
      scratch1_q <= 64'd0;
      uptime_q   <= 64'd0;
      rst_cnt_q  <= 3'd0;
      rvalid_q   <= 1'b0;
      rdata_q    <= 64'd0;
      bvalid_q   <= 1'b0;
      aw_v_q     <= 1'b0;
      w_v_q      <= 1'b0;
      aw_reg_q   <= 5'd0;
      w_data_q   <= 64'd0;
      w_strb_q   <= 8'd0;
    end else begin
      core_ctl_q <= core_ctl_d;
      scratch0_q <= scratch0_d;
      scratch1_q <= scratch1_d;
      uptime_q   <= uptime_d;
      rst_cnt_q  <= rst_cnt_d;
      rvalid_q   <= rvalid_d;
      rdata_q    <= rdata_d;
      bvalid_q   <= bvalid_d;
      aw_v_q     <= aw_v_d;
      w_v_q      <= w_v_d;
      aw_reg_q   <= aw_reg_d;
      w_data_q   <= w_data_d;
      w_strb_q   <= w_strb_d;
    end
  end

  logic [53:0] unused_addr;
  assign unused_addr = {s_araddr[31:8], s_araddr[2:0], s_awaddr[31:8], s_awaddr[2:0]};

endmodule

`default_nettype wire
