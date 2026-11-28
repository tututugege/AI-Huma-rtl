// Ref: docs/modules/soc_axi.md  Parameterized Full-AXI4 Write Crossbar (NM x NS + DECERR)
`default_nettype none

// Full-AXI4 Write Crossbar (AW + W + B channels):
//   - Independent per-master AW and W skid buffers (zero AW/W deadlock: AW-before-W, W-before-AW, simultaneous)
//   - Multi-outstanding writes per master (up to MAX_OUT to same slave) + ARM AXI4 A5.3 cross-slave barrier
//   - Per-slave RR AW arbiter + per-master RR B arbiter with strict grant lock (100% AW/B stability)
//   - Per-master W-target FIFO & per-slave W-source FIFO for strict AXI4 non-interleaved W routing + DECERR slave
module soc_axi_xbar_wr import soc_axi_pkg::*; #(
  parameter int NM      = 2,
  parameter int NS      = 2,
  parameter int DATA_W  = 64,
  parameter int ADDR_W  = 32,
  parameter int M_ID_W  = 6,
  parameter int M_IDX_W = (NM > 1) ? $clog2(NM) : 1,
  parameter int S_ID_W  = M_ID_W + M_IDX_W,
  parameter int SLV_W   = $clog2(NS + 1),
  parameter int MAX_OUT = 8
) (
  input  logic                  clk,
  input  logic                  rst_n,
  // NM Master ports
  input  logic [NM-1:0]         m_awvalid,
  output logic [NM-1:0]         m_awready,
  input  logic [SLV_W-1:0]      m_aw_slv    [NM],
  input  logic [M_ID_W-1:0]     m_awid      [NM],
  input  logic [ADDR_W-1:0]     m_awaddr    [NM],
  input  logic [7:0]            m_awlen     [NM],
  input  logic [2:0]            m_awsize    [NM],
  input  logic [1:0]            m_awburst   [NM],
  input  logic [NM-1:0]         m_awlock,
  input  logic [3:0]            m_awcache   [NM],
  input  logic [2:0]            m_awprot    [NM],
  input  logic [3:0]            m_awqos     [NM],
  input  logic [3:0]            m_awregion  [NM],
  input  logic [NM-1:0]         m_wvalid,
  output logic [NM-1:0]         m_wready,
  input  logic [DATA_W-1:0]     m_wdata     [NM],
  input  logic [DATA_W/8-1:0]   m_wstrb     [NM],
  input  logic [NM-1:0]         m_wlast,
  output logic [NM-1:0]         m_bvalid,
  input  logic [NM-1:0]         m_bready,
  output logic [M_ID_W-1:0]     m_bid       [NM],
  output logic [1:0]            m_bresp     [NM],
  // NS Slave ports
  output logic [NS-1:0]         s_awvalid,
  input  logic [NS-1:0]         s_awready,
  output logic [S_ID_W-1:0]     s_awid      [NS],
  output logic [ADDR_W-1:0]     s_awaddr    [NS],
  output logic [7:0]            s_awlen     [NS],
  output logic [2:0]            s_awsize    [NS],
  output logic [1:0]            s_awburst   [NS],
  output logic [NS-1:0]         s_awlock,
  output logic [3:0]            s_awcache   [NS],
  output logic [2:0]            s_awprot    [NS],
  output logic [3:0]            s_awqos     [NS],
  output logic [3:0]            s_awregion  [NS],
  output logic [NS-1:0]         s_wvalid,
  input  logic [NS-1:0]         s_wready,
  output logic [DATA_W-1:0]     s_wdata     [NS],
  output logic [DATA_W/8-1:0]   s_wstrb     [NS],
  output logic [NS-1:0]         s_wlast,
  input  logic [NS-1:0]         s_bvalid,
  output logic [NS-1:0]         s_bready,
  input  logic [S_ID_W-1:0]     s_bid       [NS],
  input  logic [1:0]            s_bresp     [NS]
);

  localparam int NS_TOT  = NS + 1;
  localparam int STRB_W  = DATA_W / 8;
  localparam int CNT_W   = $clog2(MAX_OUT + 1);
  localparam int WDEPTH  = 8;
  localparam int WCNT_W  = $clog2(WDEPTH + 1);
  localparam int AW_PW   = SLV_W + M_ID_W + ADDR_W + 8 + 3 + 2 + 1 + 4 + 3 + 4 + 4;
  localparam int W_PW    = DATA_W + STRB_W + 1;

  // ---- Per-master AW and W skid buffers ----
  logic [NM-1:0]     maw_v, maw_r, mw_v, mw_r, mw_last, maw_lock;
  logic [SLV_W-1:0]  maw_slv [NM];
  logic [M_ID_W-1:0] maw_id [NM];
  logic [ADDR_W-1:0] maw_addr [NM];
  logic [7:0]        maw_len [NM];
  logic [2:0]        maw_size [NM], maw_prot [NM];
  logic [1:0]        maw_burst [NM];
  logic [3:0]        maw_cache [NM], maw_qos [NM], maw_region [NM];
  logic [DATA_W-1:0] mw_data [NM];
  logic [STRB_W-1:0] mw_strb [NM];

  for (genvar m = 0; m < NM; m++) begin : g_skids
    soc_axi_skid #(.WIDTH(AW_PW)) u_aw_skid (
      .clk, .rst_n,
      .s_valid(m_awvalid[m]), .s_ready(m_awready[m]),
      .s_data({m_aw_slv[m], m_awid[m], m_awaddr[m], m_awlen[m], m_awsize[m], m_awburst[m],
               m_awlock[m], m_awcache[m], m_awprot[m], m_awqos[m], m_awregion[m]}),
      .m_valid(maw_v[m]), .m_ready(maw_r[m]),
      .m_data({maw_slv[m], maw_id[m], maw_addr[m], maw_len[m], maw_size[m], maw_burst[m],
               maw_lock[m], maw_cache[m], maw_prot[m], maw_qos[m], maw_region[m]})
    );
    soc_axi_skid #(.WIDTH(W_PW)) u_w_skid (
      .clk, .rst_n,
      .s_valid(m_wvalid[m]), .s_ready(m_wready[m]),
      .s_data({m_wdata[m], m_wstrb[m], m_wlast[m]}),
      .m_valid(mw_v[m]), .m_ready(mw_r[m]),
      .m_data({mw_data[m], mw_strb[m], mw_last[m]})
    );
  end

  // ---- Per-master outstanding write tracker + W-target FIFO; Per-slave W-source FIFO ----
  logic [CNT_W-1:0]   wr_cnt_q [NM], wr_cnt_d [NM];
  logic [SLV_W-1:0]   wr_slv_q [NM], wr_slv_d [NM];
  logic [SLV_W-1:0]   mw_fifo_q [NM][WDEPTH], mw_fifo_d [NM][WDEPTH];
  logic [WCNT_W-1:0]  mw_cnt_q  [NM], mw_cnt_d  [NM];
  logic [M_IDX_W-1:0] sw_fifo_q [NS_TOT][WDEPTH], sw_fifo_d [NS_TOT][WDEPTH];
  logic [WCNT_W-1:0]  sw_cnt_q  [NS_TOT], sw_cnt_d  [NS_TOT];

  // ---- Virtual slave array (0..NS-1 real + NS DECERR) ----
  logic [NS_TOT-1:0] vs_awvalid, vs_awready, vs_wvalid, vs_wready, vs_wlast, vs_bvalid, vs_bready;
  logic [S_ID_W-1:0] vs_awid    [NS_TOT], vs_bid [NS_TOT];
  logic [ADDR_W-1:0] vs_awaddr  [NS_TOT];
  logic [7:0]        vs_awlen   [NS_TOT];
  logic [2:0]        vs_awsize  [NS_TOT];
  logic [1:0]        vs_awburst [NS_TOT];
  logic [NS_TOT-1:0] vs_awlock;
  logic [3:0]        vs_awcache [NS_TOT], vs_awqos [NS_TOT], vs_awregion [NS_TOT];
  logic [2:0]        vs_awprot  [NS_TOT];
  logic [DATA_W-1:0] vs_wdata   [NS_TOT];
  logic [STRB_W-1:0] vs_wstrb   [NS_TOT];
  logic [1:0]        vs_bresp   [NS_TOT];

  for (genvar s = 0; s < NS; s++) begin : g_s_bind
    assign s_awvalid[s]   = vs_awvalid[s];  assign vs_awready[s] = s_awready[s];
    assign s_awid[s]      = vs_awid[s];     assign s_awaddr[s]   = vs_awaddr[s];
    assign s_awlen[s]     = vs_awlen[s];    assign s_awsize[s]   = vs_awsize[s];
    assign s_awburst[s]   = vs_awburst[s];  assign s_awlock[s]   = vs_awlock[s];
    assign s_awcache[s]   = vs_awcache[s];  assign s_awprot[s]   = vs_awprot[s];
    assign s_awqos[s]     = vs_awqos[s];    assign s_awregion[s] = vs_awregion[s];
    assign s_wvalid[s]    = vs_wvalid[s];   assign vs_wready[s]  = s_wready[s];
    assign s_wdata[s]     = vs_wdata[s];    assign s_wstrb[s]    = vs_wstrb[s];
    assign s_wlast[s]     = vs_wlast[s];
    assign vs_bvalid[s]   = s_bvalid[s];    assign s_bready[s]   = vs_bready[s];
    assign vs_bid[s]      = s_bid[s];       assign vs_bresp[s]   = s_bresp[s];
  end

  // ---- Built-in AXI4 Write DECERR slave (virtual slave NS) ----
  // Tracks AW IDs in a small FIFO; sinks W beats until WLAST then pops AW ID into B FIFO.
  logic [S_ID_W-1:0] err_aw_q [WDEPTH], err_aw_d [WDEPTH];
  logic [WCNT_W-1:0] err_awc_q, err_awc_d;
  logic [S_ID_W-1:0] err_b_q  [WDEPTH], err_b_d  [WDEPTH];
  logic [WCNT_W-1:0] err_bc_q, err_bc_d;

  assign vs_awready[NS] = (err_awc_q < WCNT_W'(WDEPTH));
  assign vs_wready[NS]  = (err_awc_q != '0) && (err_bc_q < WCNT_W'(WDEPTH));
  assign vs_bvalid[NS]  = (err_bc_q != '0);
  assign vs_bid[NS]     = err_b_q[0];
  assign vs_bresp[NS]   = AXI4_RESP_DECERR;

  always_comb begin
    logic              e_aw_f, e_wl_f, e_b_f;
    logic [WCNT_W-1:0] awc_m, bc_m;
    e_aw_f = vs_awvalid[NS] && vs_awready[NS];
    e_wl_f = vs_wvalid[NS]  && vs_wready[NS] && vs_wlast[NS];
    e_b_f  = vs_bvalid[NS]  && vs_bready[NS];
    for (int i = 0; i < WDEPTH; i++) begin err_aw_d[i] = err_aw_q[i]; err_b_d[i] = err_b_q[i]; end

    awc_m = err_awc_q;
    if (e_wl_f) begin
      for (int i = 0; i < WDEPTH - 1; i++) err_aw_d[i] = err_aw_q[i + 1];
      awc_m = err_awc_q - WCNT_W'(1);
    end
    err_awc_d = awc_m;
    if (e_aw_f) begin
      err_aw_d[awc_m[2:0]] = vs_awid[NS];
      err_awc_d = awc_m + WCNT_W'(1);
    end

    bc_m = err_bc_q;
    if (e_b_f) begin
      for (int i = 0; i < WDEPTH - 1; i++) err_b_d[i] = err_b_q[i + 1];
      bc_m = err_bc_q - WCNT_W'(1);
    end
    err_bc_d = bc_m;
    if (e_wl_f) begin
      err_b_d[bc_m[2:0]] = err_aw_q[0];
      err_bc_d = bc_m + WCNT_W'(1);
    end
  end

  // ---- Per-master AW eligibility ----
  logic [NM-1:0] m_aw_elig;
  for (genvar m = 0; m < NM; m++) begin : g_aw_elig
    assign m_aw_elig[m] = maw_v[m] &&
                          (mw_cnt_q[m] < WCNT_W'(WDEPTH)) &&
                          ((wr_cnt_q[m] == '0) ||
                           ((wr_slv_q[m] == maw_slv[m]) && (wr_cnt_q[m] < CNT_W'(MAX_OUT))));
  end

  // ---- Per-slave AW Round-Robin Arbitration with strict grant lock ----
  logic [M_IDX_W-1:0] aw_rr_q [NS_TOT], aw_rr_d [NS_TOT];
  logic [NS_TOT-1:0]  aw_lk_q, aw_lk_d;
  logic [M_IDX_W-1:0] aw_gr_q [NS_TOT], aw_gr_d [NS_TOT];
  logic [NS_TOT-1:0]  aw_grant_mat [NM];
  logic [NS_TOT-1:0]  sw_aw_fire;
  logic [M_IDX_W-1:0] sw_aw_mst [NS_TOT];

  for (genvar s = 0; s < NS_TOT; s++) begin : g_aw_arb
    logic               win_v;
    logic [M_IDX_W-1:0] win_m;
    always_comb begin
      logic [M_IDX_W-1:0] idx;
      idx   = '0;
      win_v = 1'b0;
      win_m = aw_gr_q[s];
      if (aw_lk_q[s]) begin
        win_v = 1'b1;
        win_m = aw_gr_q[s];
      end else if (sw_cnt_q[s] < WCNT_W'(WDEPTH)) begin
        for (int k = 0; k < NM; k++) begin
          idx = M_IDX_W'((int'(aw_rr_q[s]) + k) % NM);
          if (!win_v && m_aw_elig[idx] && (maw_slv[idx] == SLV_W'(s))) begin
            win_v = 1'b1;
            win_m = idx;
          end
        end
      end

      vs_awvalid[s]  = win_v;          vs_awid[s]     = {win_m, maw_id[win_m]};
      vs_awaddr[s]   = maw_addr[win_m]; vs_awlen[s]    = maw_len[win_m];
      vs_awsize[s]   = maw_size[win_m]; vs_awburst[s]  = maw_burst[win_m];
      vs_awlock[s]   = maw_lock[win_m]; vs_awcache[s]  = maw_cache[win_m];
      vs_awprot[s]   = maw_prot[win_m]; vs_awqos[s]    = maw_qos[win_m];
      vs_awregion[s] = maw_region[win_m];

      aw_lk_d[s]    = win_v && !vs_awready[s];
      aw_gr_d[s]    = win_m;
      aw_rr_d[s]    = (win_v && vs_awready[s]) ? M_IDX_W'((int'(win_m) + 1) % NM) : aw_rr_q[s];
      sw_aw_fire[s] = win_v && vs_awready[s];
      sw_aw_mst[s]  = win_m;

      for (int m = 0; m < NM; m++)
        aw_grant_mat[m][s] = win_v && (win_m == M_IDX_W'(m)) && vs_awready[s];
    end
  end

  for (genvar m = 0; m < NM; m++) begin : g_aw_rdy
    assign maw_r[m] = |aw_grant_mat[m];
  end

  // ---- W channel routing strictly per head of mw_fifo[m] and sw_fifo[s] ----
  for (genvar s = 0; s < NS_TOT; s++) begin : g_w_slv
    logic               s_has_w;
    logic [M_IDX_W-1:0] s_wm;
    logic               m_targets_s;
    assign s_has_w     = (sw_cnt_q[s] != '0);
    assign s_wm        = sw_fifo_q[s][0];
    assign m_targets_s = s_has_w && (mw_cnt_q[s_wm] != '0) && (mw_fifo_q[s_wm][0] == SLV_W'(s));
    assign vs_wvalid[s] = m_targets_s && mw_v[s_wm];
    assign vs_wdata[s]  = mw_data[s_wm];
    assign vs_wstrb[s]  = mw_strb[s_wm];
    assign vs_wlast[s]  = mw_last[s_wm];
  end

  for (genvar m = 0; m < NM; m++) begin : g_w_mst
    logic             m_has_w;
    logic [SLV_W-1:0] m_ws;
    assign m_has_w = (mw_cnt_q[m] != '0);
    assign m_ws    = mw_fifo_q[m][0];
    assign mw_r[m] = m_has_w && (sw_cnt_q[m_ws] != '0) &&
                     (sw_fifo_q[m_ws][0] == M_IDX_W'(m)) && vs_wready[m_ws];
  end

  // ---- Update mw_fifo[m] and sw_fifo[s] ----
  for (genvar m = 0; m < NM; m++) begin : g_mw_fifo
    always_comb begin
      logic              push_w, pop_w;
      logic [WCNT_W-1:0] mid_c;
      push_w = maw_v[m] && maw_r[m];
      pop_w  = mw_v[m]  && mw_r[m] && mw_last[m];
      for (int i = 0; i < WDEPTH; i++) mw_fifo_d[m][i] = mw_fifo_q[m][i];
      mid_c = mw_cnt_q[m];
      if (pop_w) begin
        for (int i = 0; i < WDEPTH - 1; i++) mw_fifo_d[m][i] = mw_fifo_q[m][i + 1];
        mid_c = mw_cnt_q[m] - WCNT_W'(1);
      end
      mw_cnt_d[m] = mid_c;
      if (push_w) begin
        mw_fifo_d[m][mid_c[2:0]] = maw_slv[m];
        mw_cnt_d[m] = mid_c + WCNT_W'(1);
      end
    end
  end

  for (genvar s = 0; s < NS_TOT; s++) begin : g_sw_fifo
    always_comb begin
      logic              push_w, pop_w;
      logic [WCNT_W-1:0] mid_c;
      push_w = sw_aw_fire[s];
      pop_w  = vs_wvalid[s] && vs_wready[s] && vs_wlast[s];
      for (int i = 0; i < WDEPTH; i++) sw_fifo_d[s][i] = sw_fifo_q[s][i];
      mid_c = sw_cnt_q[s];
      if (pop_w) begin
        for (int i = 0; i < WDEPTH - 1; i++) sw_fifo_d[s][i] = sw_fifo_q[s][i + 1];
        mid_c = sw_cnt_q[s] - WCNT_W'(1);
      end
      sw_cnt_d[s] = mid_c;
      if (push_w) begin
        sw_fifo_d[s][mid_c[2:0]] = sw_aw_mst[s];
        sw_cnt_d[s] = mid_c + WCNT_W'(1);
      end
    end
  end

  // ---- Per-master B Return Round-Robin Arbitration with strict grant lock ----
  logic [SLV_W-1:0] b_rr_q [NM], b_rr_d [NM];
  logic [NM-1:0]    b_lk_q, b_lk_d;
  logic [SLV_W-1:0] b_gr_q [NM], b_gr_d [NM];
  logic [NM-1:0]    b_rdy_mat [NS_TOT];

  for (genvar m = 0; m < NM; m++) begin : g_b_arb
    logic             bwin_v;
    logic [SLV_W-1:0] bwin_s;
    always_comb begin
      logic [SLV_W-1:0] idx;
      idx    = '0;
      bwin_v = 1'b0;
      bwin_s = b_gr_q[m];
      if (b_lk_q[m]) begin
        bwin_v = 1'b1;
        bwin_s = b_gr_q[m];
      end else begin
        for (int k = 0; k < NS_TOT; k++) begin
          idx = SLV_W'((int'(b_rr_q[m]) + k) % NS_TOT);
          if (!bwin_v && vs_bvalid[idx] && (vs_bid[idx][S_ID_W-1 -: M_IDX_W] == M_IDX_W'(m))) begin
            bwin_v = 1'b1;
            bwin_s = idx;
          end
        end
      end

      m_bvalid[m] = bwin_v; m_bid[m] = vs_bid[bwin_s][M_ID_W-1:0]; m_bresp[m] = vs_bresp[bwin_s];
      b_lk_d[m]   = bwin_v && !m_bready[m];
      b_gr_d[m]   = bwin_s;
      b_rr_d[m]   = (bwin_v && m_bready[m]) ? SLV_W'((int'(bwin_s) + 1) % NS_TOT) : b_rr_q[m];
      for (int s = 0; s < NS_TOT; s++) b_rdy_mat[s][m] = bwin_v && (bwin_s == SLV_W'(s)) && m_bready[m];
    end
  end

  for (genvar s = 0; s < NS_TOT; s++) begin : g_b_rdy
    assign vs_bready[s] = |b_rdy_mat[s];
  end

  // ---- Outstanding write counter update ----
  for (genvar m = 0; m < NM; m++) begin : g_wcnt
    always_comb begin
      logic inc, dec;
      inc = maw_v[m] && maw_r[m];
      dec = m_bvalid[m] && m_bready[m];
      wr_cnt_d[m] = wr_cnt_q[m] + CNT_W'(inc) - CNT_W'(dec);
      wr_slv_d[m] = inc ? maw_slv[m] : wr_slv_q[m];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      aw_lk_q <= '0; b_lk_q <= '0; err_awc_q <= '0; err_bc_q <= '0;
      for (int i = 0; i < WDEPTH; i++) begin err_aw_q[i] <= '0; err_b_q[i] <= '0; end
      for (int m = 0; m < NM; m++) begin
        wr_cnt_q[m] <= '0; wr_slv_q[m] <= '0; mw_cnt_q[m] <= '0; b_rr_q[m] <= '0; b_gr_q[m] <= '0;
        for (int i = 0; i < WDEPTH; i++) mw_fifo_q[m][i] <= '0;
      end
      for (int s = 0; s < NS_TOT; s++) begin
        aw_rr_q[s] <= '0; aw_gr_q[s] <= '0; sw_cnt_q[s] <= '0;
        for (int i = 0; i < WDEPTH; i++) sw_fifo_q[s][i] <= '0;
      end
    end else begin
      aw_lk_q <= aw_lk_d; b_lk_q <= b_lk_d; err_awc_q <= err_awc_d; err_bc_q <= err_bc_d;
      for (int i = 0; i < WDEPTH; i++) begin err_aw_q[i] <= err_aw_d[i]; err_b_q[i] <= err_b_d[i]; end
      for (int m = 0; m < NM; m++) begin
        wr_cnt_q[m] <= wr_cnt_d[m]; wr_slv_q[m] <= wr_slv_d[m]; mw_cnt_q[m] <= mw_cnt_d[m];
        b_rr_q[m] <= b_rr_d[m]; b_gr_q[m] <= b_gr_d[m];
        for (int i = 0; i < WDEPTH; i++) mw_fifo_q[m][i] <= mw_fifo_d[m][i];
      end
      for (int s = 0; s < NS_TOT; s++) begin
        aw_rr_q[s] <= aw_rr_d[s]; aw_gr_q[s] <= aw_gr_d[s]; sw_cnt_q[s] <= sw_cnt_d[s];
        for (int i = 0; i < WDEPTH; i++) sw_fifo_q[s][i] <= sw_fifo_d[s][i];
      end
    end
  end

  logic unused_err_w;
  assign unused_err_w = &{1'b0, vs_awaddr[NS], vs_awlen[NS], vs_awsize[NS], vs_awburst[NS],
                          vs_awlock[NS], vs_awcache[NS], vs_awprot[NS], vs_awqos[NS], vs_awregion[NS],
                          vs_wdata[NS], vs_wstrb[NS]};

endmodule

`default_nettype wire
