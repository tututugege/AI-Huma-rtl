// Ref: docs/modules/soc_periph.md  Synthesizable RV64 BootROM (0x0000_0000, Native 64-bit Full-AXI4 Burst Slave)
`default_nettype none

// Read-only synthesizable BootROM with real RV64 ZSBL and native 64-bit Full-AXI4 burst support
// (FIXED/INCR/WRAP, 1 beat/cycle streaming, full ARID->RID & RLAST; write bursts cleanly return SLVERR):
//   boot_mode 2'b00 : Direct DDR boot (a0=mhartid, a1=0x83e0_0000 DTB, jump 0x8000_0000)
//   boot_mode 2'b01 : On-Chip SRAM boot (a0=mhartid, jump 0x3000_0000)
//   boot_mode 2'b1x : Park loop (wfi; j -4) reserved for future Flash/JTAG bring-up
module soc_bootrom import soc_axi_pkg::*; #(
  parameter int ID_W = 8
) (
  input  logic            clk,
  input  logic            rst_n,
  input  logic            s_arvalid,
  output logic            s_arready,
  input  logic [ID_W-1:0] s_arid,
  input  logic [31:0]     s_araddr,
  input  logic [7:0]      s_arlen,
  input  logic [2:0]      s_arsize,
  input  logic [1:0]      s_arburst,
  input  logic            s_arlock,
  input  logic [3:0]      s_arcache,
  input  logic [2:0]      s_arprot,
  input  logic [3:0]      s_arqos,
  input  logic [3:0]      s_arregion,
  output logic            s_rvalid,
  input  logic            s_rready,
  output logic [ID_W-1:0] s_rid,
  output logic [63:0]     s_rdata,
  output logic [1:0]      s_rresp,
  output logic            s_rlast,
  input  logic            s_awvalid,
  output logic            s_awready,
  input  logic [ID_W-1:0] s_awid,
  input  logic [31:0]     s_awaddr,
  input  logic [7:0]      s_awlen,
  input  logic [2:0]      s_awsize,
  input  logic [1:0]      s_awburst,
  input  logic            s_awlock,
  input  logic [3:0]      s_awcache,
  input  logic [2:0]      s_awprot,
  input  logic [3:0]      s_awqos,
  input  logic [3:0]      s_awregion,
  input  logic            s_wvalid,
  output logic            s_wready,
  input  logic [63:0]     s_wdata,
  input  logic [7:0]      s_wstrb,
  input  logic            s_wlast,
  output logic            s_bvalid,
  input  logic            s_bready,
  output logic [ID_W-1:0] s_bid,
  output logic [1:0]      s_bresp
);

  function automatic logic [63:0] rom_word64(input logic [8:0] idx);
    case (idx)
      // 0x00: lui t0, 0x1f000 ; lw t1, 8(t0)
      9'h000:  return {32'h0082_A303, 32'h1F00_02B7};
      // 0x08: andi t1, t1, 3 ; csrr a0, mhartid
      9'h001:  return {32'hF140_2573, 32'h0033_7313};
      // 0x10: bne t1, x0, +24 (0x28) ; addi a1, x0, 0x41f
      9'h002:  return {32'h41F0_0593, 32'h0003_1C63};
      // 0x18: slli a1, a1, 21 (0x83e0_0000) ; addi t0, x0, 1
      9'h003:  return {32'h0010_0293, 32'h0155_9593};
      // 0x20: slli t0, t0, 31 (0x8000_0000) ; jalr x0, 0(t0)
      9'h004:  return {32'h0002_8067, 32'h01F2_9293};
      // 0x28: addi t2, x0, 1 ; bne t1, t2, +12 (0x38)
      9'h005:  return {32'h0073_1663, 32'h0010_0393};
      // 0x30: lui t0, 0x30000 ; jalr x0, 0(t0)
      9'h006:  return {32'h0002_8067, 32'h3000_02B7};
      // 0x38: wfi ; jal x0, -4 (0x38)
      9'h007:  return {32'hFFDF_F06F, 32'h1050_0073};
      default: return 64'h0000_0013_0000_0013;   // nop; nop
    endcase
  endfunction

  // ---- Read Burst Engine (1 beat/cycle streaming) ----
  logic            rd_act_q, rd_act_d;
  logic [ID_W-1:0] rd_id_q, rd_id_d;
  logic [31:0]     rd_addr_q, rd_addr_d;
  logic [7:0]      rd_len_q, rd_len_d, rd_rem_q, rd_rem_d;
  logic [2:0]      rd_size_q, rd_size_d;
  logic [1:0]      rd_burst_q, rd_burst_d;
  logic [63:0]     rd_data_q, rd_data_d;

  assign s_arready = !rd_act_q;
  assign s_rvalid  = rd_act_q;
  assign s_rid     = rd_id_q;
  assign s_rdata   = rd_data_q;
  assign s_rresp   = AXI4_RESP_OKAY;
  assign s_rlast   = (rd_rem_q == 8'd0);

  always_comb begin
    logic [31:0] na;
    rd_act_d   = rd_act_q;
    rd_id_d    = rd_id_q;
    rd_addr_d  = rd_addr_q;
    rd_len_d   = rd_len_q;
    rd_rem_d   = rd_rem_q;
    rd_size_d  = rd_size_q;
    rd_burst_d = rd_burst_q;
    rd_data_d  = rd_data_q;
    na         = axi4_next_addr(rd_addr_q, rd_size_q, rd_burst_q, rd_len_q);

    if (rd_act_q) begin
      if (s_rready) begin
        if (rd_rem_q == 8'd0) begin
          rd_act_d = 1'b0;
        end else begin
          rd_rem_d  = rd_rem_q - 8'd1;
          rd_addr_d = na;
          rd_data_d = rom_word64(na[11:3]);
        end
      end
    end else if (s_arvalid) begin
      rd_act_d   = 1'b1;
      rd_id_d    = s_arid;
      rd_addr_d  = s_araddr;
      rd_len_d   = s_arlen;
      rd_rem_d   = s_arlen;
      rd_size_d  = s_arsize;
      rd_burst_d = s_arburst;
      rd_data_d  = rom_word64(s_araddr[11:3]);
    end
  end

  // ---- Write Burst Sink (RO BootROM -> SLVERR after WLAST) ----
  typedef enum logic [1:0] {
    WR_IDLE = 2'd0,
    WR_SINK = 2'd1,
    WR_RESP = 2'd2
  } wr_st_e;

  wr_st_e          wr_st_q, wr_st_d;
  logic [ID_W-1:0] wr_id_q, wr_id_d;

  assign s_awready = (wr_st_q == WR_IDLE);
  assign s_wready  = (wr_st_q == WR_SINK);
  assign s_bvalid  = (wr_st_q == WR_RESP);
  assign s_bid     = wr_id_q;
  assign s_bresp   = AXI4_RESP_SLVERR;

  always_comb begin
    wr_st_d = wr_st_q;
    wr_id_d = wr_id_q;
    case (wr_st_q)
      WR_IDLE: if (s_awvalid)             begin wr_id_d = s_awid; wr_st_d = WR_SINK; end
      WR_SINK: if (s_wvalid && s_wlast)   wr_st_d = WR_RESP;
      default: if (s_bready)              wr_st_d = WR_IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_act_q <= 1'b0; rd_id_q <= '0; rd_addr_q <= 32'd0; rd_len_q <= 8'd0; rd_rem_q <= 8'd0;
      rd_size_q <= 3'd0; rd_burst_q <= 2'd0; rd_data_q <= 64'd0;
      wr_st_q <= WR_IDLE; wr_id_q <= '0;
    end else begin
      rd_act_q <= rd_act_d; rd_id_q <= rd_id_d; rd_addr_q <= rd_addr_d; rd_len_q <= rd_len_d;
      rd_rem_q <= rd_rem_d; rd_size_q <= rd_size_d; rd_burst_q <= rd_burst_d; rd_data_q <= rd_data_d;
      wr_st_q <= wr_st_d; wr_id_q <= wr_id_d;
    end
  end

  logic unused_sig;
  assign unused_sig = &{1'b0, s_arlock, s_arcache, s_arprot, s_arqos, s_arregion,
                        s_awaddr, s_awlen, s_awsize, s_awburst, s_awlock, s_awcache, s_awprot,
                        s_awqos, s_awregion, s_wdata, s_wstrb};

endmodule

`default_nettype wire
