// Ref: docs/modules/soc_periph.md  NS16550A UART with 16B TX/RX FIFOs & loopback (0x1000_0000)
`default_nettype none

// Real synthesizable NS16550A UART (1-byte register spacing, compatible with Linux ns16550a/earlycon):
//   +0 RBR (RO) / THR (WO) / DLL (DLAB=1)    +4 MCR (bit4 = internal serial loopback)
//   +1 IER (RW) / DLM (DLAB=1)               +5 LSR (bit0 DR, bit5 THRE, bit6 TEMT)
//   +2 IIR (RO) / FCR (WO, FIFO reset)       +6 MSR (0xB0: CTS/DSR/DCD)
//   +3 LCR (bit7 DLAB, reset 0x03 = 8N1)     +7 SCR (RW scratch)
module soc_uart import soc_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        uart_rxd,
  output logic        uart_txd,
  output logic        irq_out,
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

  localparam int FDEPTH = 16;

  // Registers
  logic [7:0]  dll_q, dll_d, dlm_q, dlm_d;
  logic [7:0]  ier_q, ier_d, lcr_q, lcr_d, mcr_q, mcr_d, scr_q, scr_d;
  // TX FIFO
  logic [7:0]  tx_mem_q [FDEPTH];
  logic [3:0]  tx_hd_q, tx_hd_d, tx_tl_q, tx_tl_d;
  logic [4:0]  tx_cnt_q, tx_cnt_d;
  // RX FIFO
  logic [7:0]  rx_mem_q [FDEPTH];
  logic [3:0]  rx_hd_q, rx_hd_d, rx_tl_q, rx_tl_d;
  logic [4:0]  rx_cnt_q, rx_cnt_d;

  // AXI-Lite state
  logic        rvalid_q, rvalid_d;
  logic [63:0] rdata_q, rdata_d;
  logic        bvalid_q, bvalid_d;
  logic        aw_v_q, aw_v_d, w_v_q, w_v_d;
  logic [63:0] w_data_q, w_data_d;
  logic [7:0]  w_strb_q, w_strb_d;

  // Serial engines
  logic        tx_ready, tx_busy, tx_line, rx_in, rx_valid;
  logic [7:0]  rx_byte;
  logic        tx_pop, rx_push, tx_push, rx_pop;
  logic [7:0]  tx_push_byte;
  logic        clr_rx_fifo, clr_tx_fifo;

  assign tx_pop   = (tx_cnt_q != 5'd0) && tx_ready;
  assign rx_in    = mcr_q[4] ? tx_line : uart_rxd;
  assign uart_txd = mcr_q[4] ? 1'b1 : tx_line;

  soc_uart_tx u_tx (
    .clk, .rst_n, .divisor({dlm_q, dll_q}),
    .tx_valid(tx_cnt_q != 5'd0), .tx_data(tx_mem_q[tx_hd_q]),
    .tx_ready(tx_ready), .tx_busy(tx_busy), .txd(tx_line)
  );
  soc_uart_rx u_rx (
    .clk, .rst_n, .divisor({dlm_q, dll_q}),
    .rxd(rx_in), .rx_valid(rx_valid), .rx_data(rx_byte)
  );

  // Status & interrupts
  logic        lsr_dr, lsr_thre, lsr_temt, irq_rx, irq_tx;
  logic [7:0]  lsr_val, iir_val, r0_val, r1_val;
  assign lsr_dr   = (rx_cnt_q != 5'd0);
  assign lsr_thre = (tx_cnt_q == 5'd0);
  assign lsr_temt = (tx_cnt_q == 5'd0) && !tx_busy;
  assign lsr_val  = {1'b0, lsr_temt, lsr_thre, 4'b0000, lsr_dr};
  assign irq_rx   = ier_q[0] && lsr_dr;
  assign irq_tx   = ier_q[1] && lsr_thre;
  assign irq_out  = irq_rx || irq_tx;
  assign iir_val  = irq_rx ? 8'hC4 : (irq_tx ? 8'hC2 : 8'hC1);
  assign r0_val   = lcr_q[7] ? dll_q : (lsr_dr ? rx_mem_q[rx_hd_q] : 8'd0);
  assign r1_val   = lcr_q[7] ? dlm_q : ier_q;

  assign s_arready = !rvalid_q;
  assign s_rvalid  = rvalid_q;
  assign s_rdata   = rdata_q;
  assign s_rresp   = AXI_RESP_OKAY;
  assign s_awready = !aw_v_q && !bvalid_q;
  assign s_wready  = !w_v_q  && !bvalid_q;
  assign s_bvalid  = bvalid_q;
  assign s_bresp   = AXI_RESP_OKAY;

  // Read channel (exact offset 0 with DLAB=0 pops RX FIFO)
  always_comb begin
    rvalid_d = rvalid_q;
    rdata_d  = rdata_q;
    rx_pop   = 1'b0;
    if (rvalid_q && s_rready) rvalid_d = 1'b0;
    if (s_arvalid && s_arready) begin
      rvalid_d = 1'b1;
      rdata_d  = {scr_q, 8'hB0, lsr_val, mcr_q, lcr_q, iir_val, r1_val, r0_val};
      if (s_araddr[2:0] == 3'd0 && !lcr_q[7] && lsr_dr) rx_pop = 1'b1;
    end
  end

  // Write channel (byte-lane addressed via wstrb[7:0] matching offsets 0..7)
  always_comb begin
    logic        aw_fire, w_fire, wr_go;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] wr_data;
    logic [7:0]  wr_strb;
    /* verilator lint_on UNUSEDSIGNAL */
    aw_v_d       = aw_v_q;
    w_v_d        = w_v_q;
    w_data_d     = w_data_q;
    w_strb_d     = w_strb_q;
    bvalid_d     = bvalid_q;
    dll_d        = dll_q;
    dlm_d        = dlm_q;
    ier_d        = ier_q;
    lcr_d        = lcr_q;
    mcr_d        = mcr_q;
    scr_d        = scr_q;
    tx_push      = 1'b0;
    tx_push_byte = 8'd0;
    clr_rx_fifo  = 1'b0;
    clr_tx_fifo  = 1'b0;

    if (bvalid_q && s_bready) bvalid_d = 1'b0;
    aw_fire = s_awvalid && s_awready;
    w_fire  = s_wvalid  && s_wready;
    if (aw_fire) aw_v_d = 1'b1;
    if (w_fire) begin w_v_d = 1'b1; w_data_d = s_wdata; w_strb_d = s_wstrb; end

    wr_go   = (aw_v_q || aw_fire) && (w_v_q || w_fire) && !bvalid_q;
    wr_data = w_v_q ? w_data_q : s_wdata;
    wr_strb = w_v_q ? w_strb_q : s_wstrb;
    if (wr_go) begin
      aw_v_d   = 1'b0;
      w_v_d    = 1'b0;
      bvalid_d = 1'b1;
      if (wr_strb[0]) begin
        if (lcr_q[7]) dll_d = wr_data[7:0];
        else if (tx_cnt_q < 5'(FDEPTH)) begin tx_push = 1'b1; tx_push_byte = wr_data[7:0]; end
      end
      if (wr_strb[1]) begin
        if (lcr_q[7]) dlm_d = wr_data[15:8];
        else          ier_d = {4'd0, wr_data[11:8]};
      end
      if (wr_strb[2]) begin clr_rx_fifo = wr_data[17]; clr_tx_fifo = wr_data[18]; end
      if (wr_strb[3]) lcr_d = wr_data[31:24];
      if (wr_strb[4]) mcr_d = {3'd0, wr_data[36:32]};
      if (wr_strb[7]) scr_d = wr_data[63:56];
    end
  end

  // FIFO pointers
  always_comb begin
    tx_hd_d  = tx_hd_q;
    tx_tl_d  = tx_tl_q;
    tx_cnt_d = tx_cnt_q;
    if (clr_tx_fifo) begin
      tx_hd_d = 4'd0; tx_tl_d = 4'd0; tx_cnt_d = 5'd0;
    end else begin
      if (tx_push) tx_tl_d = tx_tl_q + 4'd1;
      if (tx_pop)  tx_hd_d = tx_hd_q + 4'd1;
      tx_cnt_d = tx_cnt_q + 5'(tx_push) - 5'(tx_pop);
    end

    rx_push  = rx_valid && (rx_cnt_q < 5'(FDEPTH));
    rx_hd_d  = rx_hd_q;
    rx_tl_d  = rx_tl_q;
    rx_cnt_d = rx_cnt_q;
    if (clr_rx_fifo) begin
      rx_hd_d = 4'd0; rx_tl_d = 4'd0; rx_cnt_d = 5'd0;
    end else begin
      if (rx_push) rx_tl_d = rx_tl_q + 4'd1;
      if (rx_pop)  rx_hd_d = rx_hd_q + 4'd1;
      rx_cnt_d = rx_cnt_q + 5'(rx_push) - 5'(rx_pop);
    end
  end

  always_ff @(posedge clk) begin
    if (tx_push && !clr_tx_fifo) tx_mem_q[tx_tl_q] <= tx_push_byte;
    if (rx_push && !clr_rx_fifo) rx_mem_q[rx_tl_q] <= rx_byte;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dll_q <= 8'd1; dlm_q <= 8'd0; ier_q <= 8'd0; lcr_q <= 8'h03; mcr_q <= 8'd0; scr_q <= 8'd0;
      tx_hd_q <= 4'd0; tx_tl_q <= 4'd0; tx_cnt_q <= 5'd0;
      rx_hd_q <= 4'd0; rx_tl_q <= 4'd0; rx_cnt_q <= 5'd0;
      rvalid_q <= 1'b0; rdata_q <= 64'd0; bvalid_q <= 1'b0;
      aw_v_q <= 1'b0; w_v_q <= 1'b0; w_data_q <= 64'd0; w_strb_q <= 8'd0;
    end else begin
      dll_q <= dll_d; dlm_q <= dlm_d; ier_q <= ier_d; lcr_q <= lcr_d; mcr_q <= mcr_d; scr_q <= scr_d;
      tx_hd_q <= tx_hd_d; tx_tl_q <= tx_tl_d; tx_cnt_q <= tx_cnt_d;
      rx_hd_q <= rx_hd_d; rx_tl_q <= rx_tl_d; rx_cnt_q <= rx_cnt_d;
      rvalid_q <= rvalid_d; rdata_q <= rdata_d; bvalid_q <= bvalid_d;
      aw_v_q <= aw_v_d; w_v_q <= w_v_d; w_data_q <= w_data_d; w_strb_q <= w_strb_d;
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic [60:0] unused_addr;
  assign unused_addr = {s_araddr[31:3], s_awaddr};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
