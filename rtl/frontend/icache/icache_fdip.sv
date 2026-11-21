// Ref: front-end/icache/icache_top.cpp  ICacheTop (S2-confirmed 2-slot real-AXI FDIP, 8-entry VA queue, 1-pop/cycle)
`default_nettype none

// Fetch-Directed Instruction Prefetcher (FDIP):
//   - 2 in-flight AXI read slots using txids 8..9 on MASTER_ICACHE, strictly lower priority than demand ICache misses.
//   - 8-entry circular 64B-aligned VA queue flushed on fence_i / refetch / bpu_ovr; enqueued by pair Block B miss and
//     S2-confirmed predict_next_fetch_address.
//   - 1-pop/cycle head inspection (zero combinational loop) using ITLB read-only peek port 1 & ICache tag peek.
module icache_fdip import ttg_cfg_pkg::*; import icache_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    refetch,
  input  logic                    fence_i,
  // Demand ICache status (step-0 req & in-flight miss line for arbitration & dedup)
  input  logic                    demand_mem_req_step0,
  input  logic                    demand_miss_txv,
  input  logic [25:0]             demand_miss_line,
  // Raw AXI inputs
  input  logic                    mem_req_accepted,
  input  logic [IC_TXID_W-1:0]    mem_req_accepted_id,
  input  logic                    mem_resp_valid,
  input  logic [IC_TXID_W-1:0]    mem_resp_id,
  input  logic [IC_LINE_W-1:0]    mem_resp_line,
  // ITLB read-only peek port 1 & ICache tag peek
  output logic [XLEN_BITS-1:0]    peek_vaddr,
  input  logic                    peek_ok,
  input  logic [31:0]             peek_paddr,
  output logic [IC_IDX_W-1:0]     arr_peek_index,
  output logic [IC_TAG_W-1:0]     arr_peek_tag,
  input  logic                    arr_peek_hit,
  // Enqueue sources (applied at clock edge in exact model order: pair miss -> s2 clear/enq)
  input  logic                    pair_miss_en,
  input  logic [XLEN_BITS-1:0]    pair_miss_va,
  input  logic                    s2_en,
  input  logic [XLEN_BITS-1:0]    s2_va,
  input  logic                    s2_clear,
  // L1 DCache / WB dirty-line coherency snoop (cycle-start state)
  input  logic                    fdip_snoop_dirty,
  output logic [25:0]             fdip_snoop_line,
  // AXI arbitration & fill outputs
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

  fdip_slot_t         slots_q [FDIP_N];
  fdip_slot_t         slots_d [FDIP_N];
  logic               sending_v_q, sending_v_d;
  logic               sending_id_q, sending_id_d;
  logic [LINE_W-1:0]  q_va_q [FDIP_Q];
  logic [LINE_W-1:0]  q_va_d [FDIP_Q];
  logic [FDIP_QP_W-1:0] qh_q, qh_d;
  logic [FDIP_QN_W-1:0] qn_q, qn_d;

  // Classify AXI events for FDIP txids 8..9 (guard fdip_rsp against 1-cycle stale echo on unissued slot)
  assign fdip_acc        = mem_req_accepted && (mem_req_accepted_id >= FDIP_TX_BASE) &&
                           (mem_req_accepted_id < FDIP_TX_BASE + IC_TXID_W'(FDIP_N));
  assign fdip_rsp_raw    = mem_resp_valid && (mem_resp_id >= FDIP_TX_BASE) &&
                           (mem_resp_id < FDIP_TX_BASE + IC_TXID_W'(FDIP_N));
  assign fdip_rsp        = fdip_rsp_raw && slots_q[mem_resp_id[0]].active && slots_q[mem_resp_id[0]].issued;
  assign fdip_busy_req   = sending_v_q && !fdip_acc;
  assign fdip_snoop_line = {slots_q[mem_resp_id[0]].ptag, slots_q[mem_resp_id[0]].index};

  // Head VA peek wiring (ITLB peek port 1 + ICache tag peek)
  logic [31:0] pk_pa_line;
  assign peek_vaddr     = {q_va_q[qh_q], {IC_OFF_W{1'b0}}};
  assign pk_pa_line     = {peek_paddr[31:IC_OFF_W], {IC_OFF_W{1'b0}}};
  assign arr_peek_index = pk_pa_line[IC_OFF_W +: IC_IDX_W];
  assign arr_peek_tag   = pk_pa_line[31:12];

  logic [LINE_W-1:0]    q_mid [FDIP_Q];
  logic [FDIP_QP_W-1:0] qh_mid;
  logic [FDIP_QN_W-1:0] qn_mid;
  logic                 free_v, free_id, dup_pa;
  logic                 acc_s, rsp_s;

  // Stage 1: fence_i cancel, AXI accept/resp, and 1-pop/cycle head inspection & issue
  always_comb begin
    for (int s = 0; s < FDIP_N; s++) slots_d[s] = slots_q[s];
    sending_v_d  = sending_v_q;
    sending_id_d = sending_id_q;
    for (int k = 0; k < FDIP_Q; k++) q_mid[k] = q_va_q[k];
    qh_mid = qh_q;
    qn_mid = qn_q;

    fdip_fill_we    = 1'b0;
    fdip_fill_index = '0;
    fdip_fill_tag   = '0;
    fdip_fill_line  = mem_resp_line;

    acc_s = mem_req_accepted_id[0];
    rsp_s = mem_resp_id[0];
    if (fence_i) begin
      qh_mid = '0;
      qn_mid = '0;
      for (int s = 0; s < FDIP_N; s++) begin
        if (slots_d[s].active) begin
          if (slots_d[s].issued || (sending_v_d && (sending_id_d == 1'(s)))) slots_d[s].canceled = 1'b1;
          else                                                                slots_d[s].active   = 1'b0;
        end
      end
    end
    if (fdip_acc) begin
      slots_d[acc_s].issued = 1'b1;
      if (sending_v_d && (sending_id_d == acc_s)) sending_v_d = 1'b0;
    end
    if (fdip_rsp) begin
      if (slots_d[rsp_s].active && !slots_d[rsp_s].canceled && !fence_i && !fdip_snoop_dirty) begin
        fdip_fill_we    = 1'b1;
        fdip_fill_index = slots_d[rsp_s].index;
        fdip_fill_tag   = slots_d[rsp_s].ptag;
      end
      slots_d[rsp_s] = '0;
      if (sending_v_d && (sending_id_d == rsp_s)) sending_v_d = 1'b0;
    end
    free_v  = !slots_d[0].active || !slots_d[1].active;
    free_id = !slots_d[0].active ? 1'b0 : 1'b1;
    dup_pa  = (demand_miss_txv && (demand_miss_line == pk_pa_line[31:IC_OFF_W])) ||
              (slots_d[0].active && (slots_d[0].paddr == pk_pa_line)) ||
              (slots_d[1].active && (slots_d[1].paddr == pk_pa_line));
    if (!sending_v_d && !demand_mem_req_step0 && !refetch && !fence_i && free_v && (qn_mid != '0)) begin
      qh_mid = qh_mid + FDIP_QP_W'(1);
      qn_mid = qn_mid - FDIP_QN_W'(1);
      if (peek_ok && pk_pa_line[31] && !dup_pa && !arr_peek_hit) begin
        slots_d[free_id] = '{
          active: 1'b1, issued: 1'b0, canceled: 1'b0,
          paddr: pk_pa_line, index: pk_pa_line[IC_OFF_W +: IC_IDX_W], ptag: pk_pa_line[31:12]
        };
        sending_v_d  = 1'b1;
        sending_id_d = free_id;
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
    qh_tmp = qh_mid;
    qn_tmp = qn_mid;
    lva_pm = pair_miss_va[XLEN_BITS-1:IC_OFF_W];
    lva_s2 = s2_va[XLEN_BITS-1:IC_OFF_W];
    dup_tmp = 1'b0;
    idx_tmp = '0;

    if (pair_miss_en) begin
      dup_tmp = 1'b0;
      for (int k = 0; k < FDIP_Q; k++) begin
        idx_tmp = qh_tmp + FDIP_QP_W'(k);
        if ((FDIP_QN_W'(k) < qn_tmp) && (q_tmp[idx_tmp] == lva_pm)) dup_tmp = 1'b1;
      end
      if (!dup_tmp) begin
        if (qn_tmp >= FDIP_QN_W'(FDIP_Q)) begin
          qh_tmp = qh_tmp + FDIP_QP_W'(1);
          qn_tmp = qn_tmp - FDIP_QN_W'(1);
        end
        idx_tmp        = qh_tmp + FDIP_QP_W'(qn_tmp[FDIP_QP_W-1:0]);
        q_tmp[idx_tmp] = lva_pm;
        qn_tmp         = qn_tmp + FDIP_QN_W'(1);
      end
    end
    if (s2_clear) begin
      qh_tmp = '0;
      qn_tmp = '0;
    end
    if (s2_en) begin
      dup_tmp = 1'b0;
      for (int k = 0; k < FDIP_Q; k++) begin
        idx_tmp = qh_tmp + FDIP_QP_W'(k);
        if ((FDIP_QN_W'(k) < qn_tmp) && (q_tmp[idx_tmp] == lva_s2)) dup_tmp = 1'b1;
      end
      if (!dup_tmp) begin
        if (qn_tmp >= FDIP_QN_W'(FDIP_Q)) begin
          qh_tmp = qh_tmp + FDIP_QP_W'(1);
          qn_tmp = qn_tmp - FDIP_QN_W'(1);
        end
        idx_tmp        = qh_tmp + FDIP_QP_W'(qn_tmp[FDIP_QP_W-1:0]);
        q_tmp[idx_tmp] = lva_s2;
        qn_tmp         = qn_tmp + FDIP_QN_W'(1);
      end
    end

    for (int k = 0; k < FDIP_Q; k++) q_va_d[k] = q_tmp[k];
    qh_d = qh_tmp;
    qn_d = qn_tmp;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int s = 0; s < FDIP_N; s++) slots_q[s] <= '0;
      sending_v_q  <= 1'b0;
      sending_id_q <= 1'b0;
      for (int k = 0; k < FDIP_Q; k++) q_va_q[k] <= '0;
      qh_q <= '0;
      qn_q <= '0;
    end else begin
      for (int s = 0; s < FDIP_N; s++) slots_q[s] <= slots_d[s];
      sending_v_q  <= sending_v_d;
      sending_id_q <= sending_id_d;
      for (int k = 0; k < FDIP_Q; k++) q_va_q[k] <= q_va_d[k];
      qh_q <= qh_d;
      qn_q <= qn_d;
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_fdip;
  assign unused_fdip = ^{peek_paddr[IC_OFF_W-1:0], pair_miss_va[IC_OFF_W-1:0], s2_va[IC_OFF_W-1:0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
