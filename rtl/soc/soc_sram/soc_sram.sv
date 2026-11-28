// Ref: docs/modules/soc_periph.md  64 KiB On-Chip Boot/Scratch SRAM (0x3000_0000, Native 64-bit Full-AXI4 Burst Slave)
`default_nettype none

// 64 KiB synchronous 1RW SRAM (8192 x 64-bit, 8-bit byte-write mask) with native 64-bit Full-AXI4 burst slave:
//   - Supports FIXED, INCR, and WRAP bursts up to 256 beats at 1 beat/cycle peak streaming throughput
//   - Independent AW and W capture (AW skid + W skid -> zero AW/W deadlock)
//   - Preserves ARID->RID and AWID->BID; full RLAST & OKAY responses
module soc_sram import soc_axi_pkg::*; #(
  parameter int WORDS = 8192,   // 8192 * 8B = 64 KiB
  parameter int ID_W  = 8
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

  localparam int AW    = $clog2(WORDS);
  localparam int AR_PW = ID_W + 32 + 8 + 3 + 2;
  localparam int W_PW  = 64 + 8 + 1;

  // Input skids decouple AW, W, and AR from internal 1RW SRAM arbitration
  logic            ar_v, ar_r, aw_v, aw_r, w_v, w_r, w_last;
  logic [ID_W-1:0] ar_id, aw_id;
  logic [31:0]     ar_addr, aw_addr;
  logic [7:0]      ar_len, aw_len, w_strb;
  logic [2:0]      ar_size, aw_size;
  logic [1:0]      ar_burst, aw_burst;
  logic [63:0]     w_data;

  soc_axi_skid #(.WIDTH(AR_PW)) u_ar_skid (
    .clk, .rst_n,
    .s_valid(s_arvalid), .s_ready(s_arready), .s_data({s_arid, s_araddr, s_arlen, s_arsize, s_arburst}),
    .m_valid(ar_v),      .m_ready(ar_r),      .m_data({ar_id, ar_addr, ar_len, ar_size, ar_burst})
  );
  soc_axi_skid #(.WIDTH(AR_PW)) u_aw_skid (
    .clk, .rst_n,
    .s_valid(s_awvalid), .s_ready(s_awready), .s_data({s_awid, s_awaddr, s_awlen, s_awsize, s_awburst}),
    .m_valid(aw_v),      .m_ready(aw_r),      .m_data({aw_id, aw_addr, aw_len, aw_size, aw_burst})
  );
  soc_axi_skid #(.WIDTH(W_PW)) u_w_skid (
    .clk, .rst_n,
    .s_valid(s_wvalid),  .s_ready(s_wready),  .s_data({s_wdata, s_wstrb, s_wlast}),
    .m_valid(w_v),       .m_ready(w_r),       .m_data({w_data, w_strb, w_last})
  );

  // Active Read & Write burst engines sharing 1RW SRAM macro (write beat has priority over read launch)
  logic            rd_act_q, rd_act_d, rd_v_q, rd_v_d, rd_last_q, rd_last_d;
  logic [ID_W-1:0] rd_id_q, rd_id_d, rd_oid_q, rd_oid_d;
  logic [31:0]     rd_addr_q, rd_addr_d;
  logic [7:0]      rd_len_q, rd_len_d, rd_rem_q, rd_rem_d;
  logic [2:0]      rd_size_q, rd_size_d;
  logic [1:0]      rd_burst_q, rd_burst_d;
  logic [63:0]     sram_rdata;

  logic            wr_act_q, wr_act_d, b_v_q, b_v_d;
  logic [ID_W-1:0] wr_id_q, wr_id_d, b_id_q, b_id_d;
  logic [31:0]     wr_addr_q, wr_addr_d;
  logic [7:0]      wr_len_q, wr_len_d;
  logic [2:0]      wr_size_q, wr_size_d;
  logic [1:0]      wr_burst_q, wr_burst_d;

  logic            sram_wr_en, sram_rd_en;
  logic [AW-1:0]   sram_wr_idx, sram_rd_idx;
  logic            r_can_load;

  // Write side: accept AW into wr_act whenever idle & B slot free (or draining)
  assign aw_r       = !wr_act_q && (!b_v_q || s_bready);
  assign w_r        = wr_act_q;
  assign sram_wr_en = wr_act_q && w_v;
  assign sram_wr_idx = wr_addr_q[AW+2:3];

  // Read side: launch next read beat when output R reg can accept & SRAM not busy writing
  assign r_can_load  = !rd_v_q || s_rready;
  assign ar_r        = !rd_act_q && !sram_wr_en && r_can_load;
  assign sram_rd_en  = !sram_wr_en && r_can_load && (rd_act_q || ar_v);
  assign sram_rd_idx = rd_act_q ? rd_addr_q[AW+2:3] : ar_addr[AW+2:3];

  assign s_rvalid = rd_v_q;
  assign s_rid    = rd_oid_q;
  assign s_rdata  = sram_rdata;
  assign s_rresp  = AXI4_RESP_OKAY;
  assign s_rlast  = rd_last_q;

  assign s_bvalid = b_v_q;
  assign s_bid    = b_id_q;
  assign s_bresp  = AXI4_RESP_OKAY;

  // Write burst next-state
  always_comb begin
    wr_act_d   = wr_act_q;
    wr_id_d    = wr_id_q;
    wr_addr_d  = wr_addr_q;
    wr_len_d   = wr_len_q;
    wr_size_d  = wr_size_q;
    wr_burst_d = wr_burst_q;
    b_v_d      = (b_v_q && !s_bready) ? 1'b1 : 1'b0;
    b_id_d     = b_id_q;

    if (sram_wr_en) begin
      if (w_last) begin
        wr_act_d = 1'b0;
        b_v_d    = 1'b1;
        b_id_d   = wr_id_q;
      end else begin
        wr_addr_d = axi4_next_addr(wr_addr_q, wr_size_q, wr_burst_q, wr_len_q);
      end
    end else if (aw_v && aw_r) begin
      wr_act_d   = 1'b1;
      wr_id_d    = aw_id;
      wr_addr_d  = aw_addr;
      wr_len_d   = aw_len;
      wr_size_d  = aw_size;
      wr_burst_d = aw_burst;
    end
  end

  // Read burst next-state (1-cycle SRAM read latency, 1 beat/cycle streaming)
  always_comb begin
    rd_act_d   = rd_act_q;
    rd_id_d    = rd_id_q;
    rd_addr_d  = rd_addr_q;
    rd_len_d   = rd_len_q;
    rd_rem_d   = rd_rem_q;
    rd_size_d  = rd_size_q;
    rd_burst_d = rd_burst_q;
    rd_v_d     = (rd_v_q && !s_rready) ? 1'b1 : 1'b0;
    rd_oid_d   = rd_oid_q;
    rd_last_d  = rd_last_q;

    if (sram_rd_en) begin
      rd_v_d = 1'b1;
      if (rd_act_q) begin
        rd_oid_d  = rd_id_q;
        rd_last_d = (rd_rem_q == 8'd0);
        if (rd_rem_q == 8'd0) begin
          rd_act_d = 1'b0;
        end else begin
          rd_rem_d  = rd_rem_q - 8'd1;
          rd_addr_d = axi4_next_addr(rd_addr_q, rd_size_q, rd_burst_q, rd_len_q);
        end
      end else begin
        rd_oid_d  = ar_id;
        rd_last_d = (ar_len == 8'd0);
        if (ar_len != 8'd0) begin
          rd_act_d   = 1'b1;
          rd_id_d    = ar_id;
          rd_len_d   = ar_len;
          rd_rem_d   = ar_len - 8'd1;
          rd_size_d  = ar_size;
          rd_burst_d = ar_burst;
          rd_addr_d  = axi4_next_addr(ar_addr, ar_size, ar_burst, ar_len);
        end
      end
    end
  end

  ttg_sram_1rw #(
    .DEPTH(WORDS), .WIDTH(64), .MASK_W(8), .INIT_SWEEP(1'b0), .TAG("SOC_SRAM_64KB")   // software RAM: not cleared
  ) u_sram_mem (
    .clk(clk), .rst_n(rst_n),
    .en(sram_wr_en || sram_rd_en),
    .we(sram_wr_en),
    .addr(sram_wr_en ? sram_wr_idx : sram_rd_idx),
    .wdata(w_data),
    .wmask(w_strb),
    .rdata(sram_rdata)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_act_q <= 1'b0; rd_v_q <= 1'b0; rd_last_q <= 1'b0;
      rd_id_q <= '0; rd_oid_q <= '0; rd_addr_q <= 32'd0; rd_len_q <= 8'd0; rd_rem_q <= 8'd0;
      rd_size_q <= 3'd0; rd_burst_q <= 2'd0;
      wr_act_q <= 1'b0; b_v_q <= 1'b0;
      wr_id_q <= '0; b_id_q <= '0; wr_addr_q <= 32'd0; wr_len_q <= 8'd0;
      wr_size_q <= 3'd0; wr_burst_q <= 2'd0;
    end else begin
      rd_act_q <= rd_act_d; rd_v_q <= rd_v_d; rd_last_q <= rd_last_d;
      rd_id_q <= rd_id_d; rd_oid_q <= rd_oid_d; rd_addr_q <= rd_addr_d;
      rd_len_q <= rd_len_d; rd_rem_q <= rd_rem_d; rd_size_q <= rd_size_d; rd_burst_q <= rd_burst_d;
      wr_act_q <= wr_act_d; b_v_q <= b_v_d;
      wr_id_q <= wr_id_d; b_id_q <= b_id_d; wr_addr_q <= wr_addr_d;
      wr_len_q <= wr_len_d; wr_size_q <= wr_size_d; wr_burst_q <= wr_burst_d;
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_attr;
  assign unused_attr = &{1'b0, s_arlock, s_arcache, s_arprot, s_arqos, s_arregion,
                         s_awlock, s_awcache, s_awprot, s_awqos, s_awregion};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
