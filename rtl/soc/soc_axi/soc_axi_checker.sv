// Ref: docs/modules/soc_axi.md  ARM IHI 0022E AXI4 Protocol Assertion Checker (simulation only)
`default_nettype none

// Monitors an AXI4 interface in simulation and verifies key ARM IHI 0022E rules on every clock edge:
//   1. Post-reset VALID == 0 on all 5 channels
//   2. VALID & payload stability while !READY on AR, R, AW, W, B
//   3. Legal ARSIZE/AWSIZE, ARBURST/AWBURST, WRAP burst length/alignment, 4 KiB boundary on INCR
//   4. Exact R beat count == ARLEN + 1 and RLAST placement per outstanding RID (supports interleaving)
//   5. Exact W beat count == AWLEN + 1 and WLAST placement (supports AW-before-W, W-before-AW, simultaneous)
//   6. Exact BID match against outstanding AWIDs (no orphan R or B)
module soc_axi_checker import soc_axi_pkg::*; #(
  parameter int    DATA_W  = 64,
  parameter int    ADDR_W  = 32,
  parameter int    ID_W    = 6,
  parameter int    MAX_OUT = 32,
  parameter string NAME    = "axi4"
) (
  input logic                clk,
  input logic                rst_n,
  input logic                arvalid,
  input logic                arready,
  input logic [ID_W-1:0]     arid,
  input logic [ADDR_W-1:0]   araddr,
  input logic [7:0]          arlen,
  input logic [2:0]          arsize,
  input logic [1:0]          arburst,
  input logic                arlock,
  input logic [3:0]          arcache,
  input logic [2:0]          arprot,
  input logic [3:0]          arqos,
  input logic [3:0]          arregion,
  input logic                rvalid,
  input logic                rready,
  input logic [ID_W-1:0]     rid,
  input logic [DATA_W-1:0]   rdata,
  input logic [1:0]          rresp,
  input logic                rlast,
  input logic                awvalid,
  input logic                awready,
  input logic [ID_W-1:0]     awid,
  input logic [ADDR_W-1:0]   awaddr,
  input logic [7:0]          awlen,
  input logic [2:0]          awsize,
  input logic [1:0]          awburst,
  input logic                awlock,
  input logic [3:0]          awcache,
  input logic [2:0]          awprot,
  input logic [3:0]          awqos,
  input logic [3:0]          awregion,
  input logic                wvalid,
  input logic                wready,
  input logic [DATA_W-1:0]   wdata,
  input logic [DATA_W/8-1:0] wstrb,
  input logic                wlast,
  input logic                bvalid,
  input logic                bready,
  input logic [ID_W-1:0]     bid,
  input logic [1:0]          bresp
);

`ifndef SYNTHESIS
  localparam int STRB_W   = DATA_W / 8;
  localparam int MAX_SIZE = $clog2(STRB_W);
  localparam int IDX_W    = $clog2(MAX_OUT);
  localparam int CNT_W    = $clog2(MAX_OUT + 1);
  localparam int AX_W     = ID_W + ADDR_W + 8 + 3 + 2 + 1 + 4 + 3 + 4 + 4;
  localparam int R_W      = ID_W + DATA_W + 2 + 1;
  localparam int W_W      = DATA_W + STRB_W + 1;
  localparam int B_W      = ID_W + 2;

  logic rst_seen_q;
  logic ar_hold_q, r_hold_q, aw_hold_q, w_hold_q, b_hold_q;
  logic [AX_W-1:0] ar_pay_q, aw_pay_q, ar_pay, aw_pay;
  logic [R_W-1:0]  r_pay_q, r_pay;
  logic [W_W-1:0]  w_pay_q, w_pay;
  logic [B_W-1:0]  b_pay_q, b_pay;

  assign ar_pay = {arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arregion};
  assign aw_pay = {awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awregion};
  assign r_pay  = {rid, rdata, rresp, rlast};
  assign w_pay  = {wdata, wstrb, wlast};
  assign b_pay  = {bid, bresp};

  // Outstanding read / write / B tables
  logic              rd_v_q [MAX_OUT], rd_v_d [MAX_OUT];
  logic [ID_W-1:0]   rd_id_q [MAX_OUT], rd_id_d [MAX_OUT];
  logic [8:0]        rd_rem_q [MAX_OUT], rd_rem_d [MAX_OUT];

  logic [8:0]        aw_wlen_q [MAX_OUT], aw_wlen_d [MAX_OUT];
  logic [CNT_W-1:0]  aw_wcnt_q, aw_wcnt_d;
  logic [8:0]        w_early_q [MAX_OUT], w_early_d [MAX_OUT];
  logic [CNT_W-1:0]  w_early_cnt_q, w_early_cnt_d;
  logic [8:0]        w_cur_beats_q, w_cur_beats_d;

  logic              b_v_q [MAX_OUT], b_v_d [MAX_OUT];
  logic [ID_W-1:0]   b_id_q [MAX_OUT], b_id_d [MAX_OUT];

  // Combinational violation flags (checked cleanly in always_ff)
  logic ar_fire, r_fire, aw_fire, w_fire, b_fire;
  logic err_ar_ovf, err_r_orphan, err_rlast, err_aw_ovf, err_w_cnt, err_we_cnt, err_b_orphan;

  assign ar_fire = arvalid && arready;
  assign r_fire  = rvalid  && rready;
  assign aw_fire = awvalid && awready;
  assign w_fire  = wvalid  && wready;
  assign b_fire  = bvalid  && bready;

  function automatic logic check_burst_legal(
    input logic [ADDR_W-1:0] addr, input logic [7:0] len, input logic [2:0] size, input logic [1:0] burst
  );
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] bytes_total, start_aligned, end_byte;
    /* verilator lint_on UNUSEDSIGNAL */
    if (int'(size) > MAX_SIZE) return 1'b0;
    if (burst == 2'b11)        return 1'b0;
    if (burst == AXI4_BURST_WRAP) begin
      if (!(len == 8'd1 || len == 8'd3 || len == 8'd7 || len == 8'd15)) return 1'b0;
      if ((addr & ((32'd1 << size) - 32'd1)) != 32'd0)                  return 1'b0;
    end
    if (burst == AXI4_BURST_INCR) begin
      bytes_total   = (32'(len) + 32'd1) << size;
      start_aligned = addr & ~((32'd1 << size) - 32'd1);
      end_byte      = start_aligned + bytes_total - 32'd1;
      if (start_aligned[31:12] != end_byte[31:12]) return 1'b0;
    end
    return 1'b1;
  endfunction

  // Next-state for Read tracker
  always_comb begin
    logic             hit_v, slot_v;
    logic [IDX_W-1:0] hit_i, slot_i;
    hit_v = 1'b0; hit_i = '0; slot_v = 1'b0; slot_i = '0;
    err_ar_ovf = 1'b0; err_r_orphan = 1'b0; err_rlast = 1'b0;
    for (int i = 0; i < MAX_OUT; i++) begin
      rd_v_d[i] = rd_v_q[i]; rd_id_d[i] = rd_id_q[i]; rd_rem_d[i] = rd_rem_q[i];
    end
    if (r_fire) begin
      for (int i = 0; i < MAX_OUT; i++)
        if (!hit_v && rd_v_q[i] && rd_id_q[i] == rid) begin hit_v = 1'b1; hit_i = IDX_W'(i); end
      if (!hit_v) err_r_orphan = 1'b1;
      else begin
        err_rlast = ((rd_rem_q[hit_i] == 9'd1) != rlast);
        if (rlast) begin
          for (int i = 0; i < MAX_OUT - 1; i++)
            if (IDX_W'(i) >= hit_i) begin
              rd_v_d[i] = rd_v_q[i+1]; rd_id_d[i] = rd_id_q[i+1]; rd_rem_d[i] = rd_rem_q[i+1];
            end
          rd_v_d[MAX_OUT-1] = 1'b0;
        end else rd_rem_d[hit_i] = rd_rem_q[hit_i] - 9'd1;
      end
    end
    if (ar_fire) begin
      for (int i = 0; i < MAX_OUT; i++)
        if (!slot_v && !rd_v_d[i]) begin slot_v = 1'b1; slot_i = IDX_W'(i); end
      if (!slot_v) err_ar_ovf = 1'b1;
      else begin rd_v_d[slot_i] = 1'b1; rd_id_d[slot_i] = arid; rd_rem_d[slot_i] = 9'(arlen) + 9'd1; end
    end
  end

  // Next-state for Write / B trackers
  always_comb begin
    logic             bs_v, bh_v;
    logic [IDX_W-1:0] bs_i, bh_i;
    logic [CNT_W-1:0] awc, wec;
    logic [8:0]       nb, exp_l;
    bs_v = 1'b0; bs_i = '0; bh_v = 1'b0; bh_i = '0;
    err_aw_ovf = 1'b0; err_w_cnt = 1'b0; err_we_cnt = 1'b0; err_b_orphan = 1'b0;
    awc = aw_wcnt_q; wec = w_early_cnt_q; w_cur_beats_d = w_cur_beats_q;
    nb = w_cur_beats_q + 9'd1; exp_l = 9'd0;
    for (int i = 0; i < MAX_OUT; i++) begin
      aw_wlen_d[i] = aw_wlen_q[i]; w_early_d[i] = w_early_q[i];
      b_v_d[i] = b_v_q[i]; b_id_d[i] = b_id_q[i];
    end
    if (b_fire) begin
      for (int i = 0; i < MAX_OUT; i++)
        if (!bh_v && b_v_q[i] && b_id_q[i] == bid) begin bh_v = 1'b1; bh_i = IDX_W'(i); end
      if (!bh_v) err_b_orphan = 1'b1;
      else       b_v_d[bh_i] = 1'b0;
    end
    if (aw_fire) begin
      for (int i = 0; i < MAX_OUT; i++)
        if (!bs_v && !b_v_d[i]) begin bs_v = 1'b1; bs_i = IDX_W'(i); end
      if (!bs_v) err_aw_ovf = 1'b1;
      else begin b_v_d[bs_i] = 1'b1; b_id_d[bs_i] = awid; end
      if (wec != '0) begin
        err_we_cnt = (w_early_q[0] != (9'(awlen) + 9'd1));
        for (int i = 0; i < MAX_OUT - 1; i++) w_early_d[i] = w_early_q[i+1];
        wec = wec - CNT_W'(1);
      end else if (awc < CNT_W'(MAX_OUT)) begin
        aw_wlen_d[awc[IDX_W-1:0]] = 9'(awlen) + 9'd1;
        awc = awc + CNT_W'(1);
      end
    end
    if (w_fire) begin
      if (wlast) begin
        w_cur_beats_d = 9'd0;
        if (awc != '0) begin
          exp_l = (aw_wcnt_q != '0) ? aw_wlen_q[0] : (9'(awlen) + 9'd1);
          err_w_cnt = (nb != exp_l);
          for (int i = 0; i < MAX_OUT - 1; i++) aw_wlen_d[i] = aw_wlen_d[i+1];
          awc = awc - CNT_W'(1);
        end else if (wec < CNT_W'(MAX_OUT)) begin
          w_early_d[wec[IDX_W-1:0]] = nb;
          wec = wec + CNT_W'(1);
        end
      end else w_cur_beats_d = nb;
    end
    aw_wcnt_d     = awc;
    w_early_cnt_d = wec;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rst_seen_q <= 1'b1;
      ar_hold_q <= 1'b0; r_hold_q <= 1'b0; aw_hold_q <= 1'b0; w_hold_q <= 1'b0; b_hold_q <= 1'b0;
      ar_pay_q <= '0; aw_pay_q <= '0; r_pay_q <= '0; w_pay_q <= '0; b_pay_q <= '0;
      aw_wcnt_q <= '0; w_early_cnt_q <= '0; w_cur_beats_q <= 9'd0;
      for (int i = 0; i < MAX_OUT; i++) begin
        rd_v_q[i] <= 1'b0; rd_id_q[i] <= '0; rd_rem_q[i] <= 9'd0;
        b_v_q[i] <= 1'b0; b_id_q[i] <= '0; aw_wlen_q[i] <= 9'd0; w_early_q[i] <= 9'd0;
      end
    end else begin
      if (rst_seen_q) begin
        rst_seen_q <= 1'b0;
        if (arvalid || awvalid || wvalid || rvalid || bvalid)
          $error("[%s] AXI4 reset rule violated: VALID high after reset", NAME);
      end
      if (ar_hold_q && (!arvalid || ar_pay != ar_pay_q)) $error("[%s] AXI4 AR stability violated", NAME);
      if (r_hold_q  && (!rvalid  || r_pay  != r_pay_q))  $error("[%s] AXI4 R stability violated", NAME);
      if (aw_hold_q && (!awvalid || aw_pay != aw_pay_q)) $error("[%s] AXI4 AW stability violated", NAME);
      if (w_hold_q  && (!wvalid  || w_pay  != w_pay_q))  $error("[%s] AXI4 W stability violated", NAME);
      if (b_hold_q  && (!bvalid  || b_pay  != b_pay_q))  $error("[%s] AXI4 B stability violated", NAME);
      if (ar_fire && !check_burst_legal(araddr, arlen, arsize, arburst))
        $error("[%s] Illegal AR burst addr=%h len=%0d size=%0d burst=%0d", NAME, araddr, arlen, arsize, arburst);
      if (aw_fire && !check_burst_legal(awaddr, awlen, awsize, awburst))
        $error("[%s] Illegal AW burst addr=%h len=%0d size=%0d burst=%0d", NAME, awaddr, awlen, awsize, awburst);
      if (err_ar_ovf)   $error("[%s] AXI4 read tracker overflow", NAME);
      if (err_r_orphan) $error("[%s] Orphan R beat RID=%0d", NAME, rid);
      if (err_rlast)    $error("[%s] RLAST mismatch RID=%0d rlast=%0b", NAME, rid, rlast);
      if (err_aw_ovf)   $error("[%s] AXI4 write tracker overflow", NAME);
      if (err_w_cnt)    $error("[%s] WLAST beat count mismatch", NAME);
      if (err_we_cnt)   $error("[%s] W-before-AW beat count mismatch", NAME);
      if (err_b_orphan) $error("[%s] Orphan B response BID=%0d", NAME, bid);

      ar_hold_q <= arvalid && !arready; if (arvalid) ar_pay_q <= ar_pay;
      r_hold_q  <= rvalid  && !rready;  if (rvalid)  r_pay_q  <= r_pay;
      aw_hold_q <= awvalid && !awready; if (awvalid) aw_pay_q <= aw_pay;
      w_hold_q  <= wvalid  && !wready;  if (wvalid)  w_pay_q  <= w_pay;
      b_hold_q  <= bvalid  && !bready;  if (bvalid)  b_pay_q  <= b_pay;
      aw_wcnt_q <= aw_wcnt_d; w_early_cnt_q <= w_early_cnt_d; w_cur_beats_q <= w_cur_beats_d;
      for (int i = 0; i < MAX_OUT; i++) begin
        rd_v_q[i] <= rd_v_d[i]; rd_id_q[i] <= rd_id_d[i]; rd_rem_q[i] <= rd_rem_d[i];
        b_v_q[i] <= b_v_d[i]; b_id_q[i] <= b_id_d[i];
        aw_wlen_q[i] <= aw_wlen_d[i]; w_early_q[i] <= w_early_d[i];
      end
    end
  end
`else
  logic unused_syn;
  assign unused_syn = &{1'b0, clk, rst_n, arvalid, arready, arid, araddr, arlen, arsize, arburst, arlock,
                        arcache, arprot, arqos, arregion, rvalid, rready, rid, rdata, rresp, rlast,
                        awvalid, awready, awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot,
                        awqos, awregion, wvalid, wready, wdata, wstrb, wlast, bvalid, bready, bid, bresp};
`endif

endmodule

`default_nettype wire
