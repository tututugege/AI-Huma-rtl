// Ref: rtl/memsys/peripheral_axi/peripheral_axi_ctl.sv (Full 64-bit AXI4 MMIO master for SoC mode)
`default_nettype none

// Native 64-bit full-AXI4 MMIO master driven by LSU uncached requests (EXT_MMIO_EN = 1 in chip_top).
// Bypasses LLC completely; drives standard AXI4 Device-nGnRnE single-beat transfers with exact ARSIZE/AWSIZE
// (1/2/4/8B) and preserves exact byte offset on address for side-effect MMIO reads (UART RBR, PLIC Claim).
module mem_mmio_axi import ttg_cfg_pkg::*; (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 cpu_en,
  // LSU MMIO request / response (same handshake as peripheral_axi)
  input  logic                 req_is_mmio,
  input  logic                 req_wen,
  input  logic [31:0]          req_addr,
  input  logic [XLEN_BITS-1:0] req_wdata,
  input  logic [2:0]           req_func3,
  output logic                 resp_ready,
  output logic                 resp_is_mmio,
  output logic [XLEN_BITS-1:0] resp_rdata,
  // Full 64-bit AXI4 Master
  output logic                 m_arvalid,
  input  logic                 m_arready,
  output logic [3:0]           m_arid,
  output logic [31:0]          m_araddr,
  output logic [7:0]           m_arlen,
  output logic [2:0]           m_arsize,
  output logic [1:0]           m_arburst,
  output logic                 m_arlock,
  output logic [3:0]           m_arcache,
  output logic [2:0]           m_arprot,
  output logic [3:0]           m_arqos,
  output logic [3:0]           m_arregion,
  input  logic                 m_rvalid,
  output logic                 m_rready,
  input  logic [3:0]           m_rid,
  input  logic [63:0]          m_rdata,
  input  logic [1:0]           m_rresp,
  input  logic                 m_rlast,
  output logic                 m_awvalid,
  input  logic                 m_awready,
  output logic [3:0]           m_awid,
  output logic [31:0]          m_awaddr,
  output logic [7:0]           m_awlen,
  output logic [2:0]           m_awsize,
  output logic [1:0]           m_awburst,
  output logic                 m_awlock,
  output logic [3:0]           m_awcache,
  output logic [2:0]           m_awprot,
  output logic [3:0]           m_awqos,
  output logic [3:0]           m_awregion,
  output logic                 m_wvalid,
  input  logic                 m_wready,
  output logic [63:0]          m_wdata,
  output logic [7:0]           m_wstrb,
  output logic                 m_wlast,
  input  logic                 m_bvalid,
  output logic                 m_bready,
  input  logic [3:0]           m_bid,
  input  logic [1:0]           m_bresp
);

  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_REQ  = 2'd1,
    ST_RESP = 2'd2
  } st_e;

  st_e                   st_q, st_d;
  logic                  write_q, write_d;
  logic                  aw_done_q, aw_done_d;
  logic                  w_done_q, w_done_d;
  logic                  ar_done_q, ar_done_d;
  logic [31:0]           addr_q, addr_d;
  logic [63:0]           wdata_q, wdata_d;
  logic [2:0]            func3_q, func3_d;
  logic                  resp_v_q, resp_v_d;
  logic [63:0]           rdata_q, rdata_d;

  logic [2:0]            byte_off;
  logic [7:0]            base_strb, shifted_strb;
  logic [63:0]           shifted_wdata, raw_rdata, ext_rdata;

  assign byte_off = addr_q[2:0];

  always_comb begin
    case (func3_q[1:0])
      2'd0:    base_strb = 8'h01;
      2'd1:    base_strb = 8'h03;
      2'd2:    base_strb = 8'h0F;
      default: base_strb = 8'hFF;
    endcase
    shifted_strb  = base_strb << byte_off;
    shifted_wdata = wdata_q << {byte_off, 3'b000};
    raw_rdata     = m_rdata >> {byte_off, 3'b000};
    case (func3_q)
      3'b000:  ext_rdata = {{56{raw_rdata[7]}},  raw_rdata[7:0]};
      3'b001:  ext_rdata = {{48{raw_rdata[15]}}, raw_rdata[15:0]};
      3'b010:  ext_rdata = {{32{raw_rdata[31]}}, raw_rdata[31:0]};
      3'b011:  ext_rdata = raw_rdata;
      3'b100:  ext_rdata = {56'd0, raw_rdata[7:0]};
      3'b101:  ext_rdata = {48'd0, raw_rdata[15:0]};
      3'b110:  ext_rdata = {32'd0, raw_rdata[31:0]};
      default: ext_rdata = raw_rdata;
    endcase
  end

  assign resp_ready   = (st_q == ST_IDLE) && !resp_v_q;
  assign resp_is_mmio = resp_v_q;
  assign resp_rdata   = rdata_q;

  // Full AXI4 AR channel (Device-nGnRnE, single beat, exact access size)
  assign m_arvalid  = (st_q == ST_REQ) && !write_q && !ar_done_q;
  assign m_arid     = 4'd0;
  assign m_araddr   = addr_q;
  assign m_arlen    = 8'd0;
  assign m_arsize   = {1'b0, func3_q[1:0]};
  assign m_arburst  = 2'b01;     // INCR
  assign m_arlock   = 1'b0;
  assign m_arcache  = 4'b0000;   // Device-nGnRnE
  assign m_arprot   = 3'b000;
  assign m_arqos    = 4'd0;
  assign m_arregion = 4'd0;
  assign m_rready   = (st_q == ST_RESP) && !write_q;

  // Full AXI4 AW/W/B channels
  assign m_awvalid  = (st_q == ST_REQ) && write_q && !aw_done_q;
  assign m_awid     = 4'd0;
  assign m_awaddr   = addr_q;
  assign m_awlen    = 8'd0;
  assign m_awsize   = {1'b0, func3_q[1:0]};
  assign m_awburst  = 2'b01;     // INCR
  assign m_awlock   = 1'b0;
  assign m_awcache  = 4'b0000;   // Device-nGnRnE
  assign m_awprot   = 3'b000;
  assign m_awqos    = 4'd0;
  assign m_awregion = 4'd0;
  assign m_wvalid   = (st_q == ST_REQ) && write_q && !w_done_q;
  assign m_wdata    = shifted_wdata;
  assign m_wstrb    = shifted_strb;
  assign m_wlast    = 1'b1;
  assign m_bready   = (st_q == ST_RESP) && write_q;

  always_comb begin
    logic aw_now, w_now;
    aw_now    = 1'b0;
    w_now     = 1'b0;
    st_d      = st_q;
    write_d   = write_q;
    aw_done_d = aw_done_q;
    w_done_d  = w_done_q;
    ar_done_d = ar_done_q;
    addr_d    = addr_q;
    wdata_d   = wdata_q;
    func3_d   = func3_q;
    resp_v_d  = 1'b0;
    rdata_d   = rdata_q;

    if (st_q == ST_IDLE && !resp_v_q) begin
      if (req_is_mmio) begin
        st_d      = ST_REQ;
        write_d   = req_wen;
        aw_done_d = 1'b0;
        w_done_d  = 1'b0;
        ar_done_d = 1'b0;
        addr_d    = req_addr;
        wdata_d   = req_wdata;
        func3_d   = req_func3;
      end
    end else if (st_q == ST_REQ) begin
      if (!write_q) begin
        if (m_arvalid && m_arready) begin
          ar_done_d = 1'b1;
          st_d      = ST_RESP;
        end
      end else begin
        aw_now    = aw_done_q || (m_awvalid && m_awready);
        w_now     = w_done_q  || (m_wvalid  && m_wready);
        aw_done_d = aw_now;
        w_done_d  = w_now;
        if (aw_now && w_now) st_d = ST_RESP;
      end
    end else if (st_q == ST_RESP) begin
      if (!write_q && m_rvalid) begin
        st_d     = ST_IDLE;
        resp_v_d = 1'b1;
        rdata_d  = ext_rdata;
      end else if (write_q && m_bvalid) begin
        st_d     = ST_IDLE;
        resp_v_d = 1'b1;
        rdata_d  = 64'd0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st_q      <= ST_IDLE;
      write_q   <= 1'b0;
      aw_done_q <= 1'b0;
      w_done_q  <= 1'b0;
      ar_done_q <= 1'b0;
      addr_q    <= 32'd0;
      wdata_q   <= 64'd0;
      func3_q   <= 3'd0;
      resp_v_q  <= 1'b0;
      rdata_q   <= 64'd0;
    end else if (cpu_en) begin
      st_q      <= st_d;
      write_q   <= write_d;
      aw_done_q <= aw_done_d;
      w_done_q  <= w_done_d;
      ar_done_q <= ar_done_d;
      addr_q    <= addr_d;
      wdata_q   <= wdata_d;
      func3_q   <= func3_d;
      resp_v_q  <= resp_v_d;
      rdata_q   <= rdata_d;
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk) disable iff (!rst_n)
                   !(m_rvalid && m_rready && (!m_rlast || m_rid != 4'd0)))
    else $error("mem_mmio_axi: R response protocol error (rlast=%0b rid=%0d)", m_rlast, m_rid);
  assert property (@(posedge clk) disable iff (!rst_n)
                   !(m_bvalid && m_bready && (m_bid != 4'd0)))
    else $error("mem_mmio_axi: B response ID mismatch (bid=%0d)", m_bid);
`endif

  /* verilator lint_off UNUSEDSIGNAL */
  logic [12:0] unused_resp;
  assign unused_resp = {m_rid, m_rlast, m_bid, m_rresp, m_bresp};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
