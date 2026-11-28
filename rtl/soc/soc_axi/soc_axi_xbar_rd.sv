// Ref: docs/modules/soc_axi.md  Parameterized Full-AXI4 Read Crossbar (NM x NS + DECERR)
`default_nettype none

// Full-AXI4 Read Crossbar (AR + R channels) with:
//   - Per-master AR skid buffers (breaks timing paths, carries pre-decoded slave index)
//   - Multi-outstanding transactions per master (up to MAX_OUT to same slave) + ARM AXI4 A5.3 cross-slave barrier
//   - Per-slave Round-Robin AR arbitration with strict grant lock until ARREADY (100% AR stability)
//   - Upper-bit ID prefixing (s_arid = {m_idx, m_arid}) for collision-free R return routing
//   - Per-master Round-Robin R return arbitration with strict grant lock until RREADY (100% R stability)
//   - Built-in full-burst AXI4 Read DECERR slave for unmapped addresses (m_ar_slv >= NS)
module soc_axi_xbar_rd import soc_axi_pkg::*; #(
  parameter int NM      = 2,
  parameter int NS      = 2,
  parameter int DATA_W  = 64,
  parameter int ADDR_W  = 32,
  parameter int M_ID_W  = 6,
  parameter int M_IDX_W = (NM > 1) ? $clog2(NM) : 1,
  parameter int S_ID_W  = M_ID_W + M_IDX_W,
  parameter int SLV_W   = $clog2(NS + 1),
  parameter int MAX_OUT = 16
) (
  input  logic                clk,
  input  logic                rst_n,
  // NM Master ports (slave interfaces of xbar)
  input  logic [NM-1:0]       m_arvalid,
  output logic [NM-1:0]       m_arready,
  input  logic [SLV_W-1:0]    m_ar_slv    [NM],   // 0..NS-1 = real slave, NS = DECERR
  input  logic [M_ID_W-1:0]   m_arid      [NM],
  input  logic [ADDR_W-1:0]   m_araddr    [NM],
  input  logic [7:0]          m_arlen     [NM],
  input  logic [2:0]          m_arsize    [NM],
  input  logic [1:0]          m_arburst   [NM],
  input  logic [NM-1:0]       m_arlock,
  input  logic [3:0]          m_arcache   [NM],
  input  logic [2:0]          m_arprot    [NM],
  input  logic [3:0]          m_arqos     [NM],
  input  logic [3:0]          m_arregion  [NM],
  output logic [NM-1:0]       m_rvalid,
  input  logic [NM-1:0]       m_rready,
  output logic [M_ID_W-1:0]   m_rid       [NM],
  output logic [DATA_W-1:0]   m_rdata     [NM],
  output logic [1:0]          m_rresp     [NM],
  output logic [NM-1:0]       m_rlast,
  // NS Slave ports (master interfaces of xbar)
  output logic [NS-1:0]       s_arvalid,
  input  logic [NS-1:0]       s_arready,
  output logic [S_ID_W-1:0]   s_arid      [NS],
  output logic [ADDR_W-1:0]   s_araddr    [NS],
  output logic [7:0]          s_arlen     [NS],
  output logic [2:0]          s_arsize    [NS],
  output logic [1:0]          s_arburst   [NS],
  output logic [NS-1:0]       s_arlock,
  output logic [3:0]          s_arcache   [NS],
  output logic [2:0]          s_arprot    [NS],
  output logic [3:0]          s_arqos     [NS],
  output logic [3:0]          s_arregion  [NS],
  input  logic [NS-1:0]       s_rvalid,
  output logic [NS-1:0]       s_rready,
  input  logic [S_ID_W-1:0]   s_rid       [NS],
  input  logic [DATA_W-1:0]   s_rdata     [NS],
  input  logic [1:0]          s_rresp     [NS],
  input  logic [NS-1:0]       s_rlast
);

  localparam int NS_TOT = NS + 1;   // 0..NS-1 real slaves, NS = built-in DECERR
  localparam int CNT_W  = $clog2(MAX_OUT + 1);
  localparam int AR_PW  = SLV_W + M_ID_W + ADDR_W + 8 + 3 + 2 + 1 + 4 + 3 + 4 + 4;

  // ---- Per-master AR skid buffers ----
  logic [NM-1:0]     mar_v, mar_r;
  logic [SLV_W-1:0]  mar_slv    [NM];
  logic [M_ID_W-1:0] mar_id     [NM];
  logic [ADDR_W-1:0] mar_addr   [NM];
  logic [7:0]        mar_len    [NM];
  logic [2:0]        mar_size   [NM];
  logic [1:0]        mar_burst  [NM];
  logic [NM-1:0]     mar_lock;
  logic [3:0]        mar_cache  [NM];
  logic [2:0]        mar_prot   [NM];
  logic [3:0]        mar_qos    [NM];
  logic [3:0]        mar_region [NM];

  for (genvar m = 0; m < NM; m++) begin : g_ar_skid
    soc_axi_skid #(.WIDTH(AR_PW)) u_skid (
      .clk, .rst_n,
      .s_valid(m_arvalid[m]), .s_ready(m_arready[m]),
      .s_data({m_ar_slv[m], m_arid[m], m_araddr[m], m_arlen[m], m_arsize[m], m_arburst[m],
               m_arlock[m], m_arcache[m], m_arprot[m], m_arqos[m], m_arregion[m]}),
      .m_valid(mar_v[m]), .m_ready(mar_r[m]),
      .m_data({mar_slv[m], mar_id[m], mar_addr[m], mar_len[m], mar_size[m], mar_burst[m],
               mar_lock[m], mar_cache[m], mar_prot[m], mar_qos[m], mar_region[m]})
    );
  end

  // ---- Per-master outstanding read tracker (same-slave streaming, cross-slave ordering barrier) ----
  logic [CNT_W-1:0] rd_cnt_q [NM], rd_cnt_d [NM];
  logic [SLV_W-1:0] rd_slv_q [NM], rd_slv_d [NM];
  logic [NM-1:0]    m_ar_elig;

  for (genvar m = 0; m < NM; m++) begin : g_elig
    assign m_ar_elig[m] = mar_v[m] &&
                          ((rd_cnt_q[m] == '0) ||
                           ((rd_slv_q[m] == mar_slv[m]) && (rd_cnt_q[m] < CNT_W'(MAX_OUT))));
  end

  // ---- Virtual slave array (0..NS-1 real + NS DECERR) ----
  logic [NS_TOT-1:0] vs_arvalid, vs_arready, vs_rvalid, vs_rready, vs_rlast;
  logic [S_ID_W-1:0] vs_arid    [NS_TOT], vs_rid   [NS_TOT];
  logic [ADDR_W-1:0] vs_araddr  [NS_TOT];
  logic [7:0]        vs_arlen   [NS_TOT];
  logic [2:0]        vs_arsize  [NS_TOT];
  logic [1:0]        vs_arburst [NS_TOT];
  logic [NS_TOT-1:0] vs_arlock;
  logic [3:0]        vs_arcache [NS_TOT], vs_arqos [NS_TOT], vs_arregion [NS_TOT];
  logic [2:0]        vs_arprot  [NS_TOT];
  logic [DATA_W-1:0] vs_rdata   [NS_TOT];
  logic [1:0]        vs_rresp   [NS_TOT];

  for (genvar s = 0; s < NS; s++) begin : g_s_bind
    assign s_arvalid[s]   = vs_arvalid[s];  assign vs_arready[s] = s_arready[s];
    assign s_arid[s]      = vs_arid[s];     assign s_araddr[s]   = vs_araddr[s];
    assign s_arlen[s]     = vs_arlen[s];    assign s_arsize[s]   = vs_arsize[s];
    assign s_arburst[s]   = vs_arburst[s];  assign s_arlock[s]   = vs_arlock[s];
    assign s_arcache[s]   = vs_arcache[s];  assign s_arprot[s]   = vs_arprot[s];
    assign s_arqos[s]     = vs_arqos[s];    assign s_arregion[s] = vs_arregion[s];
    assign vs_rvalid[s]   = s_rvalid[s];    assign s_rready[s]   = vs_rready[s];
    assign vs_rid[s]      = s_rid[s];       assign vs_rdata[s]   = s_rdata[s];
    assign vs_rresp[s]    = s_rresp[s];     assign vs_rlast[s]   = s_rlast[s];
  end

  // ---- Built-in AXI4 Read DECERR slave (virtual slave NS) ----
  logic              err_v_q, err_v_d;
  logic [S_ID_W-1:0] err_id_q, err_id_d;
  logic [7:0]        err_rem_q, err_rem_d;

  assign vs_arready[NS] = !err_v_q;
  assign vs_rvalid[NS]  = err_v_q;
  assign vs_rid[NS]     = err_id_q;
  assign vs_rdata[NS]   = '0;
  assign vs_rresp[NS]   = AXI4_RESP_DECERR;
  assign vs_rlast[NS]   = (err_rem_q == 8'd0);

  always_comb begin
    err_v_d   = err_v_q;
    err_id_d  = err_id_q;
    err_rem_d = err_rem_q;
    if (err_v_q && vs_rready[NS]) begin
      if (err_rem_q == 8'd0) err_v_d   = 1'b0;
      else                   err_rem_d = err_rem_q - 8'd1;
    end
    if (vs_arvalid[NS] && !err_v_q) begin
      err_v_d   = 1'b1;
      err_id_d  = vs_arid[NS];
      err_rem_d = vs_arlen[NS];
    end
  end

  // ---- Per-slave AR Round-Robin Arbitration with strict grant lock ----
  logic [M_IDX_W-1:0] ar_rr_q [NS_TOT], ar_rr_d [NS_TOT];
  logic [NS_TOT-1:0]  ar_lk_q, ar_lk_d;
  logic [M_IDX_W-1:0] ar_gr_q [NS_TOT], ar_gr_d [NS_TOT];
  logic [NS_TOT-1:0]  ar_grant_mat [NM];

  for (genvar s = 0; s < NS_TOT; s++) begin : g_ar_arb
    logic               win_v;
    logic [M_IDX_W-1:0] win_m;
    always_comb begin
      logic [M_IDX_W-1:0] idx;
      idx   = '0;
      win_v = 1'b0;
      win_m = ar_gr_q[s];
      if (ar_lk_q[s]) begin
        win_v = 1'b1;
        win_m = ar_gr_q[s];
      end else begin
        for (int k = 0; k < NM; k++) begin
          idx = M_IDX_W'((int'(ar_rr_q[s]) + k) % NM);
          if (!win_v && m_ar_elig[idx] && (mar_slv[idx] == SLV_W'(s))) begin
            win_v = 1'b1;
            win_m = idx;
          end
        end
      end

      vs_arvalid[s]  = win_v;
      vs_arid[s]     = {win_m, mar_id[win_m]};
      vs_araddr[s]   = mar_addr[win_m];
      vs_arlen[s]    = mar_len[win_m];
      vs_arsize[s]   = mar_size[win_m];
      vs_arburst[s]  = mar_burst[win_m];
      vs_arlock[s]   = mar_lock[win_m];
      vs_arcache[s]  = mar_cache[win_m];
      vs_arprot[s]   = mar_prot[win_m];
      vs_arqos[s]    = mar_qos[win_m];
      vs_arregion[s] = mar_region[win_m];

      ar_lk_d[s] = win_v && !vs_arready[s];
      ar_gr_d[s] = win_m;
      ar_rr_d[s] = (win_v && vs_arready[s]) ? M_IDX_W'((int'(win_m) + 1) % NM) : ar_rr_q[s];

      for (int m = 0; m < NM; m++) begin
        ar_grant_mat[m][s] = win_v && (win_m == M_IDX_W'(m)) && vs_arready[s];
      end
    end
  end

  for (genvar m = 0; m < NM; m++) begin : g_ar_rdy
    assign mar_r[m] = |ar_grant_mat[m];
  end

  // ---- Per-master R Return Round-Robin Arbitration with strict grant lock ----
  logic [SLV_W-1:0] r_rr_q [NM], r_rr_d [NM];
  logic [NM-1:0]    r_lk_q, r_lk_d;
  logic [SLV_W-1:0] r_gr_q [NM], r_gr_d [NM];
  logic [NM-1:0]    r_rdy_mat [NS_TOT];

  for (genvar m = 0; m < NM; m++) begin : g_r_arb
    logic             rwin_v;
    logic [SLV_W-1:0] rwin_s;
    always_comb begin
      logic [SLV_W-1:0] idx;
      idx    = '0;
      rwin_v = 1'b0;
      rwin_s = r_gr_q[m];
      if (r_lk_q[m]) begin
        rwin_v = 1'b1;
        rwin_s = r_gr_q[m];
      end else begin
        for (int k = 0; k < NS_TOT; k++) begin
          idx = SLV_W'((int'(r_rr_q[m]) + k) % NS_TOT);
          if (!rwin_v && vs_rvalid[idx] && (vs_rid[idx][S_ID_W-1 -: M_IDX_W] == M_IDX_W'(m))) begin
            rwin_v = 1'b1;
            rwin_s = idx;
          end
        end
      end

      m_rvalid[m] = rwin_v;
      m_rid[m]    = vs_rid[rwin_s][M_ID_W-1:0];
      m_rdata[m]  = vs_rdata[rwin_s];
      m_rresp[m]  = vs_rresp[rwin_s];
      m_rlast[m]  = vs_rlast[rwin_s];

      r_lk_d[m] = rwin_v && !m_rready[m];
      r_gr_d[m] = rwin_s;
      r_rr_d[m] = (rwin_v && m_rready[m]) ? SLV_W'((int'(rwin_s) + 1) % NS_TOT) : r_rr_q[m];

      for (int s = 0; s < NS_TOT; s++) begin
        r_rdy_mat[s][m] = rwin_v && (rwin_s == SLV_W'(s)) && m_rready[m];
      end
    end
  end

  for (genvar s = 0; s < NS_TOT; s++) begin : g_r_rdy
    assign vs_rready[s] = |r_rdy_mat[s];
  end

  // ---- Outstanding read counter update ----
  for (genvar m = 0; m < NM; m++) begin : g_cnt
    always_comb begin
      logic inc, dec;
      inc = mar_v[m] && mar_r[m];
      dec = m_rvalid[m] && m_rready[m] && m_rlast[m];
      rd_cnt_d[m] = rd_cnt_q[m] + CNT_W'(inc) - CNT_W'(dec);
      rd_slv_d[m] = inc ? mar_slv[m] : rd_slv_q[m];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      err_v_q   <= 1'b0;
      err_id_q  <= '0;
      err_rem_q <= 8'd0;
      ar_lk_q   <= '0;
      r_lk_q    <= '0;
      for (int m = 0; m < NM; m++) begin
        rd_cnt_q[m] <= '0; rd_slv_q[m] <= '0; r_rr_q[m] <= '0; r_gr_q[m] <= '0;
      end
      for (int s = 0; s < NS_TOT; s++) begin
        ar_rr_q[s] <= '0; ar_gr_q[s] <= '0;
      end
    end else begin
      err_v_q   <= err_v_d;
      err_id_q  <= err_id_d;
      err_rem_q <= err_rem_d;
      ar_lk_q   <= ar_lk_d;
      r_lk_q    <= r_lk_d;
      for (int m = 0; m < NM; m++) begin
        rd_cnt_q[m] <= rd_cnt_d[m]; rd_slv_q[m] <= rd_slv_d[m];
        r_rr_q[m]   <= r_rr_d[m];   r_gr_q[m]   <= r_gr_d[m];
      end
      for (int s = 0; s < NS_TOT; s++) begin
        ar_rr_q[s] <= ar_rr_d[s]; ar_gr_q[s] <= ar_gr_d[s];
      end
    end
  end

  logic unused_err_ax;
  assign unused_err_ax = &{1'b0, vs_araddr[NS], vs_arsize[NS], vs_arburst[NS], vs_arlock[NS],
                           vs_arcache[NS], vs_arprot[NS], vs_arqos[NS], vs_arregion[NS]};

endmodule

`default_nettype wire
