// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_stlf: STLF window -> forward/retry/MMIO load/DCache wait/finish)
`default_nettype none

module lsu_stlf
  import lsu_pkg::*;
(
  input  lsu_ring_t        stlf_i,
  input  lsu_ring_t        wdc_i,
  input  lsu_ring_t        finish_i,
  input  logic             unc_valid_i,
  input  logic             rb_head_valid,
  input  logic [6:0]       rb_head_rob_idx,
  input  logic             rb_hi_valid,                // head_incomplete
  input  logic [6:0]       rb_hi_rob_idx,
  input  ld_state_t        ld_st_i      [LQ],
  input  logic [31:0]      ld_paddr     [LQ],
  input  logic [2:0]       ld_func3     [LQ],
  input  logic [SQW-1:0]   ld_snap_idx  [LQ],
  input  logic [LQ-1:0]    ld_snap_flag,
  input  logic [LQ-1:0]    ld_mmio,
  input  logic [6:0]       ld_rob_idx   [LQ],
  input  logic [31:0]      ld_result_i  [LQ],
  input  logic [RIW-1:0]   stq_head,
  input  logic             stq_head_flag,
  input  st_state_t        st_st        [SQ],
  input  logic [SQ-1:0]    st_suppress,
  input  logic [SQ-1:0]    st_paddr_valid,
  input  logic [31:0]      st_paddr     [SQ],
  input  logic [2:0]       st_func3     [SQ],
  input  logic [SQ-1:0]    st_data_valid,
  input  logic [31:0]      st_data      [SQ],
  input  logic [SQ-1:0]    st_is_lrsc,
  input  logic [SQ-1:0]    st_sc_pass,
  output lsu_ring_t        stlf_o,
  output lsu_ring_t        wdc_o,
  output lsu_ring_t        finish_o,
  output ld_state_t        ld_st_o      [LQ],
  output logic [31:0]      ld_result_o  [LQ],
  output logic             unc_set,                    // an MMIO load takes the uncached unit
  output logic [31:0]      unc_addr,
  output logic [2:0]       unc_func3,
  output logic [RIW-1:0]   unc_idx
);

  logic [WIN-1:0] in_win, valid_w;
  logic [RIW-1:0] idx_w [WIN];

  lsu_ring_win u_win (.ring(stlf_i), .valid_w(valid_w), .idx_w(idx_w));

  // ---- per window position: the load's intrinsic classification and its forwarding search ----
  logic [WIN-1:0] is_empty, is_check, is_pre_dc, is_pre_fin, is_mmio, mmio_go, res_retry, res_fwd;
  logic [31:0]    fwd_data [WIN];

  for (genvar p = 0; p < WIN; p++) begin : g_pos
    logic [RCW-1:0] older_cnt;
    logic           oldest;
    assign in_win[p]      = stlf_i.count > RCW'(p);
    assign is_empty[p]    = ld_st_i[idx_w[p]] == LD_EMPTY;
    assign is_check[p]    = ld_st_i[idx_w[p]] == LD_CHECK_STLF;
    assign is_pre_dc[p]   = ld_st_i[idx_w[p]] == LD_WAIT_DCACHE;
    assign is_pre_fin[p]  = ld_st_i[idx_w[p]] == LD_WAIT_FINISH;
    assign is_mmio[p]     = ld_mmio[idx_w[p]];
    // lsu_mmio_is_oldest_unfinished()
    assign oldest         = rb_hi_valid ? rb_hi_rob_idx == ld_rob_idx[idx_w[p]]
                                        : rb_head_valid && rb_head_rob_idx == ld_rob_idx[idx_w[p]];
    assign mmio_go[p]     = older_cnt == '0 && oldest;

    lsu_stlf_match u_match (
      .ld_paddr(ld_paddr[idx_w[p]]), .ld_func3(ld_func3[idx_w[p]]),
      .snap_idx(ld_snap_idx[idx_w[p]]), .snap_flag(ld_snap_flag[idx_w[p]]),
      .stq_head(stq_head), .stq_head_flag(stq_head_flag),
      .st_st(st_st), .st_suppress(st_suppress), .st_paddr_valid(st_paddr_valid), .st_paddr(st_paddr),
      .st_func3(st_func3), .st_data_valid(st_data_valid), .st_data(st_data),
      .st_is_lrsc(st_is_lrsc), .st_sc_pass(st_sc_pass),
      .older_cnt(older_cnt), .res_retry(res_retry[p]), .res_fwd(res_fwd[p]), .fwd_data(fwd_data[p]));
  end

  // ---- sequential scan ----
  logic [WIN-1:0] pop, retry, app_wd, app_fin, unc_start, wr_result, st_chg;
  ld_state_t      st_new [WIN];

  lsu_stlf_chain u_chain (
    .in_win(in_win), .valid(valid_w), .is_empty(is_empty), .is_check(is_check), .is_pre_dc(is_pre_dc),
    .is_pre_fin(is_pre_fin), .is_mmio(is_mmio), .mmio_go(mmio_go), .res_retry(res_retry), .res_fwd(res_fwd),
    .wd_count(wdc_i.count), .fin_count(finish_i.count), .unc_valid(unc_valid_i),
    .pop(pop), .retry(retry), .app_wd(app_wd), .app_fin(app_fin), .unc_start(unc_start), .wr_result(wr_result),
    .st_chg(st_chg), .st_new(st_new));

  // ---- LDQ updates ----
  for (genvar e = 0; e < LQ; e++) begin : g_ld
    logic [WIN-1:0] chg, res;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign chg[p] = st_chg[p]    && idx_w[p] == RIW'(e);
      assign res[p] = wr_result[p] && idx_w[p] == RIW'(e);
    end
    always_comb begin
      ld_st_o[e]     = ld_st_i[e];
      ld_result_o[e] = ld_result_i[e];
      for (int p = WIN - 1; p >= 0; p--) begin
        if (chg[p]) ld_st_o[e]     = st_new[p];
        if (res[p]) ld_result_o[e] = fwd_data[p];
      end
    end
  end

  // ---- uncached unit: the first MMIO load that may go ----
  always_comb begin
    unc_set   = |unc_start;
    unc_addr  = '0;
    unc_func3 = '0;
    unc_idx   = '0;
    for (int p = WIN - 1; p >= 0; p--) begin
      if (unc_start[p]) begin
        unc_addr  = ld_paddr[idx_w[p]];
        unc_func3 = ld_func3[idx_w[p]];
        unc_idx   = idx_w[p];
      end
    end
  end

  // ---- queues: pop the processed entries, then re-enqueue the retries at the tail (only while there is room) ----
  lsu_ring_t      stlf_popped;
  logic [WIN-1:0] retry_en;
  logic [RCW-1:0] rank_retry [WIN];

  lsu_ring_kill_pop u_pop (.ring_i(stlf_i), .keep_w(valid_w & ~pop), .ring_o(stlf_popped));
  lsu_rank #(.N(WIN), .CW(RCW)) u_rank (.bits(retry), .rank(rank_retry));
  for (genvar p = 0; p < WIN; p++) begin : g_retry
    assign retry_en[p] = retry[p] && stlf_popped.count + rank_retry[p] < RCW'(LQ);
  end
  lsu_ring_app #(.NA(WIN)) u_retry (.ring_i(stlf_popped), .app_en(retry_en), .app_idx(idx_w), .ring_o(stlf_o));
  lsu_ring_app #(.NA(WIN)) u_wd    (.ring_i(wdc_i),    .app_en(app_wd),  .app_idx(idx_w), .ring_o(wdc_o));
  lsu_ring_app #(.NA(WIN)) u_fin   (.ring_i(finish_i), .app_en(app_fin), .app_idx(idx_w), .ring_o(finish_o));

endmodule

`default_nettype wire
