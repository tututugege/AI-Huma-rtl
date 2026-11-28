// Ref: front-end/icache/icache_top.cpp  ICacheTop (S2 FDIP + 1-entry fill buffer for strict 1RW ICache)
`default_nettype none

module icache_fdip import ttg_cfg_pkg::*; import icache_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    refetch,
  input  logic                    fence_i,
  input  logic                    demand_mem_req_step0,
  input  logic                    demand_dc_busy,
  input  logic                    demand_miss_txv,
  input  logic [25:0]             demand_miss_line,
  input  logic                    demand_tw_we,
  input  logic                    demand_idle_req,
  input  logic                    mem_req_accepted,
  input  logic [IC_TXID_W-1:0]    mem_req_accepted_id,
  input  logic                    mem_resp_valid,
  input  logic [IC_TXID_W-1:0]    mem_resp_id,
  input  logic [IC_LINE_W-1:0]    mem_resp_line,
  input  logic                    dc_resp_valid,
  input  logic                    dc_resp_retry,
  input  logic                    dc_resp_miss,
  output logic                    fdip_probe_busy,
  output logic                    fdip_fb_busy,
  output logic                    fdip_dc_req_valid,
  output logic [31:0]             fdip_dc_req_addr,
  output logic [XLEN_BITS-1:0]    peek_vaddr,
  input  logic                    peek_ok,
  input  logic [31:0]             peek_paddr,
  output logic [IC_IDX_W-1:0]     arr_peek_index,
  output logic [IC_TAG_W-1:0]     arr_peek_tag,
  input  logic                    arr_peek_hit,
  input  logic                    pair_miss_en,
  input  logic [XLEN_BITS-1:0]    pair_miss_va,
  input  logic                    s2_en,
  input  logic [XLEN_BITS-1:0]    s2_va,
  input  logic                    s2_clear,
  output logic                    fdip_acc,
  output logic                    fdip_rsp,
  output logic                    fdip_rsp_raw,
  output logic                    fdip_busy_req,
  output logic                    fdip_req_valid,
  output logic [31:0]             fdip_req_addr,
  output logic [IC_TXID_W-1:0]    fdip_req_id,
  output logic                    fdip_fill_we,
  output logic [IC_IDX_W-1:0]     fdip_fill_index,
  output logic [IC_TAG_W-1:0]     fdip_fill_tag,
  output logic [IC_LINE_W-1:0]    fdip_fill_line
);

  localparam int FDIP_N    = 2;
  localparam int FDIP_Q    = 8;
  localparam int FDIP_QP_W = $clog2(FDIP_Q);
  localparam int FDIP_QN_W = $clog2(FDIP_Q + 1);
  localparam int LINE_W    = XLEN_BITS - IC_OFF_W;
  localparam logic [IC_TXID_W-1:0] FDIP_TX_BASE = 4'd8;

  typedef struct packed {
    logic                 active;
    logic                 issued;
    logic                 canceled;
    logic [31:0]          paddr;
    logic [IC_IDX_W-1:0]  index;
    logic [IC_TAG_W-1:0]  ptag;
  } fdip_slot_t;

  fdip_slot_t           slots_q [FDIP_N], slots_d [FDIP_N], slots_m [FDIP_N];
  logic                 sending_v_q, sending_v_d, sending_v_m;
  logic                 sending_id_q, sending_id_d, sending_id_m;
  logic [LINE_W-1:0]    q_va_q [FDIP_Q], q_va_d [FDIP_Q], q_mid [FDIP_Q];
  logic [FDIP_QP_W-1:0] qh_q, qh_d, qh_mid;
  logic [FDIP_QN_W-1:0] qn_q, qn_d, qn_mid;
  logic                 probe_v_q, probe_v_d;
  logic                 probe_retry_q, probe_retry_d, probe_retry_m;
  logic                 probe_cancel_q, probe_cancel_d, probe_cancel_m;
  logic [31:0]          probe_pa_q, probe_pa_d;
  logic [IC_IDX_W-1:0]  probe_idx_q, probe_idx_d;
  logic                 fb_v_q, fb_v_d;
  logic [IC_IDX_W-1:0]  fb_idx_q, fb_idx_d;
  logic [IC_TAG_W-1:0]  fb_tag_q, fb_tag_d;
  logic [IC_LINE_W-1:0] fb_line_q, fb_line_d;

  assign fdip_acc        = mem_req_accepted && (mem_req_accepted_id >= FDIP_TX_BASE) &&
                           (mem_req_accepted_id < FDIP_TX_BASE + IC_TXID_W'(FDIP_N));
  assign fdip_rsp_raw    = mem_resp_valid && (mem_resp_id >= FDIP_TX_BASE) &&
                           (mem_resp_id < FDIP_TX_BASE + IC_TXID_W'(FDIP_N));
  assign fdip_rsp        = fdip_rsp_raw && slots_q[mem_resp_id[0]].active &&
                           slots_q[mem_resp_id[0]].issued && !fb_v_q;
  assign fdip_busy_req   = sending_v_q && !fdip_acc;
  assign fdip_probe_busy = probe_v_q;
  assign fdip_fb_busy    = fb_v_q;

  logic [31:0]         pk_pa_line, peek_arr_pa;
  logic [IC_IDX_W-1:0] pk_vidx;
  assign peek_vaddr     = {q_va_q[qh_q], {IC_OFF_W{1'b0}}};
  assign pk_vidx        = q_va_q[qh_q][IC_IDX_W-1:0];
  assign pk_pa_line     = {peek_paddr[31:IC_OFF_W], {IC_OFF_W{1'b0}}};
  assign peek_arr_pa    = probe_v_q ? probe_pa_q : pk_pa_line;
  assign arr_peek_index = probe_v_q ? probe_idx_q : pk_vidx;
  assign arr_peek_tag   = peek_arr_pa[31:12];

  // Stage 1a: fill buffer drain, fence cancel, AXI accept & resp into fill buffer
  always_comb begin
    logic fb_drain, acc_s, rsp_s;
    for (int s = 0; s < FDIP_N; s++) slots_m[s] = slots_q[s];
    sending_v_m    = sending_v_q;
    sending_id_m   = sending_id_q;
    probe_retry_m  = probe_retry_q;
    probe_cancel_m = probe_cancel_q;
    fb_v_d         = fb_v_q;
    fb_idx_d       = fb_idx_q;
    fb_tag_d       = fb_tag_q;
    fb_line_d      = fb_line_q;
    fdip_fill_we    = 1'b0;
    fdip_fill_index = fb_idx_q;
    fdip_fill_tag   = fb_tag_q;
    fdip_fill_line  = fb_line_q;
    fb_drain       = fb_v_q && !fence_i && !demand_tw_we && !demand_idle_req;
    acc_s          = mem_req_accepted_id[0];
    rsp_s          = mem_resp_id[0];
    if (fence_i) begin
      fb_v_d         = 1'b0;
      probe_retry_m  = 1'b0;
      if (probe_v_q) probe_cancel_m = 1'b1;
      for (int s = 0; s < FDIP_N; s++) begin
        if (slots_m[s].active) begin
          if (slots_m[s].issued || (sending_v_m && (sending_id_m == 1'(s)))) slots_m[s].canceled = 1'b1;
          else                                                                slots_m[s].active   = 1'b0;
        end
      end
    end else if (fb_drain) begin
      fdip_fill_we = 1'b1;
      fb_v_d       = 1'b0;
    end
    if (fdip_acc) begin
      slots_m[acc_s].issued = 1'b1;
      if (sending_v_m && (sending_id_m == acc_s)) sending_v_m = 1'b0;
    end
    if (fdip_rsp) begin
      if (slots_m[rsp_s].active && !slots_m[rsp_s].canceled && !fence_i) begin
        fb_v_d    = 1'b1;
        fb_idx_d  = slots_m[rsp_s].index;
        fb_tag_d  = slots_m[rsp_s].ptag;
        fb_line_d = mem_resp_line;
      end
      slots_m[rsp_s] = '0;
      if (sending_v_m && (sending_id_m == rsp_s)) sending_v_m = 1'b0;
    end
  end

  // Stage 1b: 1-beat DCache probe completion & 1-pop/cycle probe launch
  always_comb begin
    logic free_v, free_id, dup_probe_pa, dup_pk_pa, canc;
    for (int s = 0; s < FDIP_N; s++) slots_d[s] = slots_m[s];
    sending_v_d       = sending_v_m;
    sending_id_d      = sending_id_m;
    probe_v_d         = probe_v_q;
    probe_retry_d     = probe_retry_m;
    probe_cancel_d    = probe_cancel_m;
    probe_pa_d        = probe_pa_q;
    probe_idx_d       = probe_idx_q;
    for (int k = 0; k < FDIP_Q; k++) q_mid[k] = q_va_q[k];
    qh_mid            = fence_i ? '0 : qh_q;
    qn_mid            = fence_i ? '0 : qn_q;
    fdip_dc_req_valid = 1'b0;
    fdip_dc_req_addr  = 32'd0;
    canc              = 1'b0;
    dup_pk_pa         = 1'b0;
    free_v       = !slots_d[0].active || !slots_d[1].active;
    free_id      = !slots_d[0].active ? 1'b0 : 1'b1;
    dup_probe_pa = (demand_miss_txv && (demand_miss_line == probe_pa_q[31:IC_OFF_W])) ||
                   (slots_d[0].active && (slots_d[0].paddr == probe_pa_q)) ||
                   (slots_d[1].active && (slots_d[1].paddr == probe_pa_q)) ||
                   (fb_v_q && ({fb_tag_q, fb_idx_q[5:0]} == probe_pa_q[31:IC_OFF_W]));
    if (probe_v_d) begin
      if (refetch || fence_i) probe_cancel_d = 1'b1;
      if (dc_resp_valid) begin
        canc           = probe_cancel_d || refetch || fence_i;
        probe_v_d      = 1'b0;
        probe_cancel_d = 1'b0;
        if (!canc && dc_resp_retry && !demand_dc_busy) probe_retry_d = 1'b1;
        else if (!canc && !dc_resp_retry && dc_resp_miss &&
                 !sending_v_d && !demand_mem_req_step0 && free_v && !dup_probe_pa && !arr_peek_hit) begin
          slots_d[free_id] = '{
            active: 1'b1, issued: 1'b0, canceled: 1'b0,
            paddr: probe_pa_q, index: probe_idx_q, ptag: probe_pa_q[31:12]
          };
          sending_v_d  = 1'b1;
          sending_id_d = free_id;
        end
      end
    end
    free_v    = !slots_d[0].active || !slots_d[1].active;
    dup_pk_pa = (demand_miss_txv && (demand_miss_line == pk_pa_line[31:IC_OFF_W])) ||
                (slots_d[0].active && (slots_d[0].paddr == pk_pa_line)) ||
                (slots_d[1].active && (slots_d[1].paddr == pk_pa_line)) ||
                (fb_v_q && ({fb_tag_q, fb_idx_q[5:0]} == pk_pa_line[31:IC_OFF_W]));
    if (refetch || fence_i || demand_dc_busy) begin
      probe_retry_d = 1'b0;
    end else if (!probe_v_q && probe_retry_d) begin
      probe_retry_d = 1'b0; probe_v_d = 1'b1; probe_cancel_d = 1'b0;
      fdip_dc_req_valid = 1'b1; fdip_dc_req_addr = probe_pa_q;
    end else if (!probe_v_q && !sending_v_d && !demand_mem_req_step0 && free_v && (qn_mid != '0)) begin
      qh_mid = qh_mid + FDIP_QP_W'(1);
      qn_mid = qn_mid - FDIP_QN_W'(1);
      if (peek_ok && pk_pa_line[31] && !dup_pk_pa && !arr_peek_hit) begin
        probe_v_d = 1'b1; probe_cancel_d = 1'b0; probe_pa_d = pk_pa_line; probe_idx_d = pk_vidx;
        fdip_dc_req_valid = 1'b1; fdip_dc_req_addr = pk_pa_line;
      end
    end
  end

  // Stage 2: AXI req outputs & clock-edge queue enqueues (pair Block B miss -> S2 clear & S2 next PC)
  always_comb begin
    logic [LINE_W-1:0]    q_tmp [FDIP_Q];
    logic [FDIP_QP_W-1:0] qh_tmp, idx_tmp;
    logic [FDIP_QN_W-1:0] qn_tmp;
    logic                 dup_tmp;
    logic [LINE_W-1:0]    lva_pm, lva_s2;

    fdip_req_valid = sending_v_d;
    fdip_req_addr  = slots_d[sending_id_d].paddr;
    fdip_req_id    = FDIP_TX_BASE + IC_TXID_W'(sending_id_d);
    for (int k = 0; k < FDIP_Q; k++) q_tmp[k] = q_mid[k];
    qh_tmp = qh_mid; qn_tmp = qn_mid;
    lva_pm = pair_miss_va[XLEN_BITS-1:IC_OFF_W];
    lva_s2 = s2_va[XLEN_BITS-1:IC_OFF_W];
    dup_tmp = 1'b0; idx_tmp = '0;
    if (pair_miss_en) begin
      for (int k = 0; k < FDIP_Q; k++) begin
        idx_tmp = qh_tmp + FDIP_QP_W'(k);
        if ((FDIP_QN_W'(k) < qn_tmp) && (q_tmp[idx_tmp] == lva_pm)) dup_tmp = 1'b1;
      end
      if (!dup_tmp) begin
        if (qn_tmp >= FDIP_QN_W'(FDIP_Q)) begin qh_tmp = qh_tmp + FDIP_QP_W'(1); qn_tmp = qn_tmp - FDIP_QN_W'(1); end
        q_tmp[qh_tmp + FDIP_QP_W'(qn_tmp[FDIP_QP_W-1:0])] = lva_pm;
        qn_tmp = qn_tmp + FDIP_QN_W'(1);
      end
    end
    if (s2_clear) begin qh_tmp = '0; qn_tmp = '0; end
    if (s2_en) begin
      dup_tmp = 1'b0;
      for (int k = 0; k < FDIP_Q; k++) begin
        idx_tmp = qh_tmp + FDIP_QP_W'(k);
        if ((FDIP_QN_W'(k) < qn_tmp) && (q_tmp[idx_tmp] == lva_s2)) dup_tmp = 1'b1;
      end
      if (!dup_tmp) begin
        if (qn_tmp >= FDIP_QN_W'(FDIP_Q)) begin qh_tmp = qh_tmp + FDIP_QP_W'(1); qn_tmp = qn_tmp - FDIP_QN_W'(1); end
        q_tmp[qh_tmp + FDIP_QP_W'(qn_tmp[FDIP_QP_W-1:0])] = lva_s2;
        qn_tmp = qn_tmp + FDIP_QN_W'(1);
      end
    end
    for (int k = 0; k < FDIP_Q; k++) q_va_d[k] = q_tmp[k];
    qh_d = qh_tmp; qn_d = qn_tmp;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int s = 0; s < FDIP_N; s++) slots_q[s] <= '0;
      sending_v_q <= 1'b0; sending_id_q <= 1'b0;
      probe_v_q <= 1'b0; probe_retry_q <= 1'b0; probe_cancel_q <= 1'b0;
      probe_pa_q <= 32'd0; probe_idx_q <= '0;
      fb_v_q <= 1'b0; fb_idx_q <= '0; fb_tag_q <= '0; fb_line_q <= '0;
      for (int k = 0; k < FDIP_Q; k++) q_va_q[k] <= '0;
      qh_q <= '0; qn_q <= '0;
    end else begin
      for (int s = 0; s < FDIP_N; s++) slots_q[s] <= slots_d[s];
      sending_v_q <= sending_v_d; sending_id_q <= sending_id_d;
      probe_v_q <= probe_v_d; probe_retry_q <= probe_retry_d; probe_cancel_q <= probe_cancel_d;
      probe_pa_q <= probe_pa_d; probe_idx_q <= probe_idx_d;
      fb_v_q <= fb_v_d; fb_idx_q <= fb_idx_d; fb_tag_q <= fb_tag_d; fb_line_q <= fb_line_d;
      for (int k = 0; k < FDIP_Q; k++) q_va_q[k] <= q_va_d[k];
      qh_q <= qh_d; qn_q <= qn_d;
    end
  end

  logic unused_fdip;
  assign unused_fdip = ^{peek_paddr[IC_OFF_W-1:0], peek_arr_pa[11:0], pair_miss_va[IC_OFF_W-1:0],
                         s2_va[IC_OFF_W-1:0], probe_pa_q[IC_OFF_W-1:0]};

endmodule
`default_nettype wire
