// Ref: docs/modules/soc_periph.md  Standard RISC-V PLIC (0x0C00_0000, 2 contexts: M + S)
`default_nettype none

// Standard RISC-V PLIC supporting PLIC_NUM_SRC (8) level-sensitive IRQ sources (IDs 1..8) and
// 2 target contexts (Context 0 = M-mode meip, Context 1 = S-mode seip).
// Register map (relative to 0x0C00_0000):
//   0x000004..0x000020 : source 1..8 priority (3-bit, 0=disabled, 1..7)
//   0x001000           : pending bitmap (bits 1..8, RO)
//   0x002000           : context 0 enable bitmap (bits 1..8)
//   0x002080           : context 1 enable bitmap (bits 1..8)
//   0x200000 / 0x200004: context 0 threshold / claim-complete
//   0x201000 / 0x201004: context 1 threshold / claim-complete
module soc_plic import soc_axi_pkg::*; import soc_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic [PLIC_NUM_SRC-1:0] irq_src,
  output logic                    meip,
  output logic                    seip,
  // 64-bit AXI4-Lite slave
  input  logic                    s_arvalid,
  output logic                    s_arready,
  input  logic [31:0]             s_araddr,
  output logic                    s_rvalid,
  input  logic                    s_rready,
  output logic [63:0]             s_rdata,
  output logic [1:0]              s_rresp,
  input  logic                    s_awvalid,
  output logic                    s_awready,
  input  logic [31:0]             s_awaddr,
  input  logic                    s_wvalid,
  output logic                    s_wready,
  input  logic [63:0]             s_wdata,
  input  logic [7:0]              s_wstrb,
  output logic                    s_bvalid,
  input  logic                    s_bready,
  output logic [1:0]              s_bresp
);

  localparam int NS = PLIC_NUM_SRC;

  logic [2:0]  prio_q [NS];
  logic [2:0]  prio_d [NS];
  logic [NS:1] claimed_q, claimed_d;
  logic [NS:1] en0_q, en0_d, en1_q, en1_d;
  logic [2:0]  thr0_q, thr0_d, thr1_q, thr1_d;
  logic [NS:1] pending;

  logic        rvalid_q, rvalid_d;
  logic [63:0] rdata_q, rdata_d;
  logic        bvalid_q, bvalid_d;
  logic        aw_v_q, aw_v_d, w_v_q, w_v_d;
  logic [23:3] aw_addr_q, aw_addr_d;
  logic [63:0] w_data_q, w_data_d;
  logic [7:0]  w_strb_q, w_strb_d;

  // Gateway pending = level asserted & not currently claimed
  for (genvar i = 1; i <= NS; i++) begin : g_pend
    assign pending[i] = irq_src[i-1] & ~claimed_q[i];
  end

  // Priority winner selection for Context 0 (M) and Context 1 (S)
  logic [3:0] win0_id, win1_id;
  logic [2:0] win0_prio, win1_prio;
  always_comb begin
    win0_id   = 4'd0;
    win0_prio = thr0_q;
    win1_id   = 4'd0;
    win1_prio = thr1_q;
    for (int i = 1; i <= NS; i++) begin
      if (pending[i] && en0_q[i] && (prio_q[i-1] > win0_prio)) begin
        win0_prio = prio_q[i-1];
        win0_id   = 4'(i);
      end
      if (pending[i] && en1_q[i] && (prio_q[i-1] > win1_prio)) begin
        win1_prio = prio_q[i-1];
        win1_id   = 4'(i);
      end
    end
  end

  assign meip      = (win0_id != 4'd0);
  assign seip      = (win1_id != 4'd0);
  assign s_arready = !rvalid_q;
  assign s_rvalid  = rvalid_q;
  assign s_rdata   = rdata_q;
  assign s_rresp   = AXI4_RESP_OKAY;
  assign s_awready = !aw_v_q && !bvalid_q;
  assign s_wready  = !w_v_q  && !bvalid_q;
  assign s_bvalid  = bvalid_q;
  assign s_bresp   = AXI4_RESP_OKAY;

  // 32-bit word reader helper (returns 32-bit word at byte offset off)
  function automatic logic [31:0] read_word32(input logic [23:0] off);
    if (off >= 24'h000004 && off <= 24'h000020) begin
      return {29'd0, prio_q[3'(off[5:2] - 4'd1)]};
    end else if (off == 24'h001000) begin
      return {{(31-NS){1'b0}}, pending, 1'b0};
    end else if (off == 24'h002000) begin
      return {{(31-NS){1'b0}}, en0_q, 1'b0};
    end else if (off == 24'h002080) begin
      return {{(31-NS){1'b0}}, en1_q, 1'b0};
    end else if (off == 24'h200000) begin
      return {29'd0, thr0_q};
    end else if (off == 24'h200004) begin
      return {28'd0, win0_id};
    end else if (off == 24'h201000) begin
      return {29'd0, thr1_q};
    end else if (off == 24'h201004) begin
      return {28'd0, win1_id};
    end else begin
      return 32'd0;
    end
  endfunction

  // Read channel (note: reading claim at 0x200004 / 0x201004 sets claimed_d)
  logic claim0_fire, claim1_fire;
  always_comb begin
    logic [23:0] lo_off, hi_off;
    rvalid_d    = rvalid_q;
    rdata_d     = rdata_q;
    claim0_fire = 1'b0;
    claim1_fire = 1'b0;
    lo_off      = {s_araddr[23:3], 3'b000};
    hi_off      = {s_araddr[23:3], 3'b100};
    if (rvalid_q && s_rready) rvalid_d = 1'b0;
    if (s_arvalid && s_arready) begin
      rvalid_d = 1'b1;
      rdata_d  = {read_word32(hi_off), read_word32(lo_off)};
      if (s_araddr[23:0] == 24'h200004 && win0_id != 4'd0) claim0_fire = 1'b1;
      if (s_araddr[23:0] == 24'h201004 && win1_id != 4'd0) claim1_fire = 1'b1;
    end
  end

  // Write channel (handles 32-bit writes in either lower or upper half of 64-bit AXI-Lite beat)
  always_comb begin
    logic        aw_fire, w_fire, wr_go;
    logic [23:3] wr_base;
    logic [63:0] wr_data;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0]  wr_strb;
    logic [31:0] w_val;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [23:0] w_off;
    aw_v_d    = aw_v_q;
    w_v_d     = w_v_q;
    aw_addr_d = aw_addr_q;
    w_data_d  = w_data_q;
    w_strb_d  = w_strb_q;
    bvalid_d  = bvalid_q;
    for (int i = 0; i < NS; i++) prio_d[i] = prio_q[i];
    claimed_d = claimed_q;
    en0_d     = en0_q;
    en1_d     = en1_q;
    thr0_d    = thr0_q;
    thr1_d    = thr1_q;

    if (claim0_fire) claimed_d[win0_id] = 1'b1;
    if (claim1_fire) claimed_d[win1_id] = 1'b1;

    if (bvalid_q && s_bready) bvalid_d = 1'b0;
    aw_fire = s_awvalid && s_awready;
    w_fire  = s_wvalid  && s_wready;
    if (aw_fire) begin aw_v_d = 1'b1; aw_addr_d = s_awaddr[23:3]; end
    if (w_fire)  begin w_v_d  = 1'b1; w_data_d  = s_wdata; w_strb_d = s_wstrb; end

    wr_go   = (aw_v_q || aw_fire) && (w_v_q || w_fire) && !bvalid_q;
    wr_base = aw_v_q ? aw_addr_q : s_awaddr[23:3];
    wr_data = w_v_q  ? w_data_q  : s_wdata;
    wr_strb = w_v_q  ? w_strb_q  : s_wstrb;
    w_off   = (|wr_strb[7:4]) ? {wr_base, 3'b100} : {wr_base, 3'b000};
    w_val   = (|wr_strb[7:4]) ? wr_data[63:32]    : wr_data[31:0];

    if (wr_go) begin
      aw_v_d   = 1'b0;
      w_v_d    = 1'b0;
      bvalid_d = 1'b1;
      if (w_off >= 24'h000004 && w_off <= 24'h000020) prio_d[3'(w_off[5:2] - 4'd1)] = w_val[2:0];
      else if (w_off == 24'h002000) en0_d  = w_val[NS:1];
      else if (w_off == 24'h002080) en1_d  = w_val[NS:1];
      else if (w_off == 24'h200000) thr0_d = w_val[2:0];
      else if (w_off == 24'h201000) thr1_d = w_val[2:0];
      else if ((w_off == 24'h200004 || w_off == 24'h201004) && w_val[3:0] >= 4'd1 && w_val[3:0] <= 4'(NS)) begin
        claimed_d[w_val[3:0]] = 1'b0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < NS; i++) prio_q[i] <= 3'd0;
      claimed_q <= '0;
      en0_q     <= '0;
      en1_q     <= '0;
      thr0_q    <= 3'd0;
      thr1_q    <= 3'd0;
      rvalid_q  <= 1'b0;
      rdata_q   <= 64'd0;
      bvalid_q  <= 1'b0;
      aw_v_q    <= 1'b0;
      w_v_q     <= 1'b0;
      aw_addr_q <= '0;
      w_data_q  <= 64'd0;
      w_strb_q  <= 8'd0;
    end else begin
      for (int i = 0; i < NS; i++) prio_q[i] <= prio_d[i];
      claimed_q <= claimed_d;
      en0_q     <= en0_d;
      en1_q     <= en1_d;
      thr0_q    <= thr0_d;
      thr1_q    <= thr1_d;
      rvalid_q  <= rvalid_d;
      rdata_q   <= rdata_d;
      bvalid_q  <= bvalid_d;
      aw_v_q    <= aw_v_d;
      w_v_q     <= w_v_d;
      aw_addr_q <= aw_addr_d;
      w_data_q  <= w_data_d;
      w_strb_q  <= w_strb_d;
    end
  end

  logic [18:0] unused_addr;
  assign unused_addr = {s_araddr[31:24], s_awaddr[31:24], s_awaddr[2:0]};

endmodule

`default_nettype wire
