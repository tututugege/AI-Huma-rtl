// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (comb_stlf: STLF window -> forward/retry/MMIO load/DCache wait/finish)
`default_nettype none

module lsu_stlf
  import lsu_pkg::*;
(
  input  lsu_ring_t        stlf_i,                  // stlf queue after the I-stage appends
  input  logic [RCW-1:0]   wdc_count,               // wait_dcache count after the D-stage pops
  input  logic [RCW-1:0]   stlf_pk_count,           // stlf queue count after this stage's pops (retry limit)
  input  logic [RCW-1:0]   fin_count,               // finish queue count after the I-stage appends
  input  logic             unc_valid_i,
  input  logic             rb_head_valid,
  input  logic [ROBW-1:0]  rb_head_rob_idx,
  input  logic             rb_hi_valid,             // head_incomplete
  input  logic [ROBW-1:0]  rb_hi_rob_idx,
  input  ld_state_t        ld_st_win    [LQ],
  input  ldq_fld_t         ld_fld       [LQ],       // fields after this cycle's writes
  input  logic [RIW-1:0]   stq_head,
  input  logic             stq_head_flag,
  input  st_state_t        st_st        [SQ],
  input  stq_fld_t         st_fld       [SQ],
  output ldq_sf_t          ev           [LQ],
  output lsu_rop_t         stlf_pop_op,
  output lsu_rop_t         stlf_app_op,
  output lsu_rop_t         wdc_op,
  output lsu_rop_t         fin_op,
  output logic             unc_set,                 // an MMIO load takes the uncached unit
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
    assign is_empty[p]    = ld_st_win[idx_w[p]] == LD_EMPTY;
    assign is_check[p]    = ld_st_win[idx_w[p]] == LD_CHECK_STLF;
    assign is_pre_dc[p]   = ld_st_win[idx_w[p]] == LD_WAIT_DCACHE;
    assign is_pre_fin[p]  = ld_st_win[idx_w[p]] == LD_WAIT_FINISH;
    assign is_mmio[p]     = ld_fld[idx_w[p]].mmio;
    // lsu_mmio_is_oldest_unfinished()
    assign oldest         = rb_hi_valid ? rb_hi_rob_idx == ld_fld[idx_w[p]].rob_idx
                                        : rb_head_valid && rb_head_rob_idx == ld_fld[idx_w[p]].rob_idx;
    assign mmio_go[p]     = older_cnt == '0 && oldest;

    lsu_stlf_match u_match (
      .ld_paddr(ld_fld[idx_w[p]].paddr), .ld_func3(ld_fld[idx_w[p]].func3),
      .snap_idx(ld_fld[idx_w[p]].snap_idx), .snap_flag(ld_fld[idx_w[p]].snap_flag),
      .stq_head(stq_head), .stq_head_flag(stq_head_flag), .st_st(st_st), .st_fld(st_fld),
      .older_cnt(older_cnt), .res_retry(res_retry[p]), .res_fwd(res_fwd[p]), .fwd_data(fwd_data[p]));
  end

  // ---- sequential scan ----
  logic [WIN-1:0] pop, retry, app_wd, app_fin, unc_start, wr_result, st_chg;
  ld_state_t      st_new [WIN];

  lsu_stlf_chain u_chain (
    .in_win(in_win), .valid(valid_w), .is_empty(is_empty), .is_check(is_check), .is_pre_dc(is_pre_dc),
    .is_pre_fin(is_pre_fin), .is_mmio(is_mmio), .mmio_go(mmio_go), .res_retry(res_retry), .res_fwd(res_fwd),
    .wd_count(wdc_count), .fin_count(fin_count), .unc_valid(unc_valid_i),
    .pop(pop), .retry(retry), .app_wd(app_wd), .app_fin(app_fin), .unc_start(unc_start), .wr_result(wr_result),
    .st_chg(st_chg), .st_new(st_new));

  // ---- LDQ events ----
  for (genvar e = 0; e < LQ; e++) begin : g_ld
    logic [WIN-1:0] chg, res;
    for (genvar p = 0; p < WIN; p++) begin : g_p
      assign chg[p] = st_chg[p]    && idx_w[p] == RIW'(e);
      assign res[p] = wr_result[p] && idx_w[p] == RIW'(e);
    end
    always_comb begin
      ev[e] = '0;
      for (int p = WIN - 1; p >= 0; p--) begin
        if (chg[p]) begin
          ev[e].chg    = 1'b1;
          ev[e].new_st = st_new[p];
        end
        if (res[p]) begin
          ev[e].res_we = 1'b1;
          ev[e].res    = fwd_data[p];
        end
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
        unc_addr  = ld_fld[idx_w[p]].paddr;
        unc_func3 = ld_fld[idx_w[p]].func3;
        unc_idx   = idx_w[p];
      end
    end
  end

  // ---- queues: pop the processed entries, then re-enqueue the retries at the tail (only while there is room) ----
  logic [WIN-1:0] retry_en;
  logic [RCW-1:0] rank_retry [WIN];
  logic [WIN-1:0][RIW-1:0] idx_pk;

  lsu_rank #(.N(WIN), .CW(RCW)) u_rank (.bits(retry), .rank(rank_retry));
  for (genvar p = 0; p < WIN; p++) begin : g_retry
    assign idx_pk[p]   = idx_w[p];
    assign retry_en[p] = retry[p] && stlf_pk_count + rank_retry[p] < RCW'(LQ);
  end
  assign stlf_pop_op = rop_kp(valid_w & ~pop);
  assign stlf_app_op = rop_app(retry_en, idx_pk);
  assign wdc_op      = rop_app(app_wd, idx_pk);
  assign fin_op      = rop_app(app_fin, idx_pk);

endmodule

`default_nettype wire
