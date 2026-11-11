// Ref: front-end/icache/icache_module.cpp  class ICache (eval_state_machine, lookup, seq); icache.cpp
// icache_comb_calc; ICacheTop.cpp comb
`default_nettype none

// I-cache control: request slot, miss FSM, AXI read transaction bookkeeping, DCache probe, refill, and the
// predecode-flush
// merge.  One combinational evaluation and one register update per cycle:
//   N(R0)   : normal step of the FSM (idle / swap steps selected by state), or K(R0) when the pipe is killed
//   R1      : the registers after this cycle's fetch step
//   R2      : invalidate (predecode flush) ? K(R1) : R1       <- the registers latched at the clock edge
// K is the "cancel the pipe" function (icache_kill).  The memory-side outputs (AXI request/ready, DCache probe
// request) are those
// of the last step of the cycle, i.e. of K(R1) in a flush cycle; the front-end outputs and the table write are
// the fetch step's.
module icache_ctl import ttg_cfg_pkg::*; import icache_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  // front-end side
  input  logic                    refetch,
  input  logic                    itlb_flush,
  input  logic                    fence_i,
  input  logic                    invalidate,
  input  logic                    req_valid_in,
  input  logic [XLEN_BITS-1:0]             pc,
  // ITLB answer
  input  logic                    ppn_valid,
  input  logic                    page_fault,
  input  logic [IC_TAG_W-1:0]     ppn,
  // AXI read master view and DCache probe response
  input  logic                    mem_req_ready,
  input  logic                    mem_req_accepted,
  input  logic [IC_TXID_W-1:0]    mem_req_accepted_id,
  input  logic                    mem_resp_valid,
  input  logic [IC_TXID_W-1:0]    mem_resp_id,
  input  logic [IC_LINE_W-1:0]    mem_resp_data,
  input  logic                    dc_resp_valid,
  input  logic                    dc_resp_retry,
  input  logic                    dc_resp_miss,
  input  logic [IC_WORD_W-1:0]    dc_resp_data,
  // arrays
  input  logic                    hit,
  input  logic [IC_LINE_W-1:0]    hit_line,
  input  logic                    has_invalid,
  input  logic [IC_WAY_W-1:0]     first_invalid,
  output logic                    arr_rd_en,
  output logic [IC_IDX_W-1:0]     arr_rd_index,
  output logic                    arr_cmp_valid,
  output logic                    tw_we,
  output logic [IC_IDX_W-1:0]     tw_index,
  output logic [IC_WAY_W-1:0]     tw_way,
  output logic [IC_TAG_W-1:0]     tw_tag,
  output logic [IC_LINE_W-1:0]    tw_line,
  output logic                    inv_all,
  // ITLB request
  output logic                    mmu_req_valid,
  output logic [XLEN_BITS-13:0]   mmu_req_vtag,
  // fetch response
  output logic                    resp_valid,
  output logic [XLEN_BITS-1:0]             resp_pc,
  output logic                    resp_page_fault,
  output logic                    resp_single_word,
  output logic [IC_LINE_W-1:0]    resp_line,
  output logic                    icache_ready,
  // memory-side outputs
  output logic                    mem_req_valid,
  output logic [31:0]             mem_req_addr,
  output logic [7:0]              mem_req_total_size,
  output logic                    mem_req_bypass,
  output logic [IC_TXID_W-1:0]    mem_req_id,
  output logic                    mem_resp_ready,
  output logic                    dc_req_valid,
  output logic [31:0]             dc_req_addr
);

  ic_regs_t r_q, r_d;
  logic [IC_LINE_W-1:0] resp_line_q, probe_line_q;

  logic kill1;
  assign kill1 = refetch || fence_i;

  // ---- shared sub-blocks of the fetch step ----
  logic active_resp, drop_resp;
  logic [IC_TXID_N-1:0] drop_mask;
  icache_txn u_txn (
    .resp_valid(mem_resp_valid), .resp_id(mem_resp_id), .inflight(r_q.inflight), .canceled(r_q.canceled),
    .miss_txv(r_q.miss_txv), .miss_txid(r_q.miss_txid), .state_swap_req(r_q.state == IC_SWAP_REQ),
    .req_accepted(mem_req_accepted), .req_accepted_id(mem_req_accepted_id),
    .active_resp, .drop_resp, .drop_mask
  );

  logic p_dc_req_valid, p_step_done, p_step_hit, p_word_we, p_infl_d, p_done_d, p_hit_d;
  logic [31:0] p_dc_req_addr;
  logic [IC_WORD_IDX_W-1:0] p_word_d;
  icache_probe u_probe (
    .req_valid(r_q.req_valid), .ppn(r_q.ppn), .req_index(r_q.req_pc[11:IC_OFF_W]), .probe_inflight(r_q.probe_inflight),
    .probe_done(r_q.probe_done), .probe_hit(r_q.probe_hit), .probe_word(r_q.probe_word),
    .dc_resp_valid, .dc_resp_retry, .dc_resp_miss, .dc_req_valid(p_dc_req_valid), .dc_req_addr(p_dc_req_addr),
    .step_done(p_step_done), .step_hit(p_step_hit), .word_we(p_word_we), .probe_inflight_d(p_infl_d),
    .probe_done_d(p_done_d), .probe_hit_d(p_hit_d), .probe_word_d(p_word_d)
  );

  logic [IC_LINE_W-1:0] probe_line_eff;
  always_comb begin
    probe_line_eff = probe_line_q;
    if (p_word_we) probe_line_eff[IC_WORD_W * r_q.probe_word +: IC_WORD_W] = dc_resp_data;
  end

  // ---- IDLE step ----
  ic_regs_t idle_r_n;
  logic idle_resp_valid, idle_resp_pf, idle_req_ready, idle_fast_fire;
  logic [XLEN_BITS-1:0] idle_resp_pc;
  logic [IC_LINE_W-1:0] idle_resp_line;
  icache_idle u_idle (
    .r(r_q), .req_valid_in, .pc, .ppn_valid, .page_fault, .ppn, .hit, .hit_line,
    .r_n(idle_r_n), .resp_valid(idle_resp_valid), .resp_pc(idle_resp_pc), .resp_page_fault(idle_resp_pf),
    .resp_line(idle_resp_line), .req_ready(idle_req_ready), .fast_fire(idle_fast_fire)
  );

  // ---- SWAP / WAIT_DC / CANCEL_WAIT step ----
  ic_regs_t swap_r_n;
  logic swap_req_ready, swap_mem_req_valid, swap_mem_resp_ready, swap_resp_valid, swap_single, swap_line_we, swap_tw_we;
  logic [IC_LINE_W-1:0] swap_resp_line, swap_line_d, swap_tw_line;
  logic [IC_WAY_W-1:0] swap_tw_way;
  icache_swap u_swap (
    .r(r_q), .mem_req_ready, .mem_req_accepted, .mem_req_accepted_id, .mem_resp_data, .active_resp, .drop_mask,
    .step_done(p_step_done), .step_hit(p_step_hit), .probe_inflight_d(p_infl_d), .probe_done_d(p_done_d),
    .probe_hit_d(p_hit_d), .probe_word_d(p_word_d), .probe_line_eff, .resp_line_q, .has_invalid, .first_invalid,
    .r_n(swap_r_n), .req_ready(swap_req_ready), .mem_req_valid(swap_mem_req_valid),
    .mem_resp_ready(swap_mem_resp_ready),
    .resp_valid(swap_resp_valid), .resp_single_word(swap_single), .resp_line(swap_resp_line),
    .resp_line_we(swap_line_we),
    .resp_line_d(swap_line_d), .tw_we(swap_tw_we), .tw_way(swap_tw_way), .tw_line(swap_tw_line)
  );

  // ---- request slot / ITLB request ----
  logic is_idle, req_ready_n, fast_fire_n, slot_rv_d, slot_ifu_d;
  logic [XLEN_BITS-1:0] slot_pc_d;
  assign is_idle     = r_q.state == IC_IDLE;
  assign req_ready_n = is_idle ? idle_req_ready : swap_req_ready;
  assign fast_fire_n = is_idle && idle_fast_fire;
  icache_slot u_slot (
    .r_req_valid(r_q.req_valid), .r_req_pc(r_q.req_pc), .r_state(r_q.state), .r_miss_txv(r_q.miss_txv),
    .kill(kill1), .req_valid_in, .pc, .req_ready(req_ready_n), .fast_fire(fast_fire_n),
    .req_valid_d(slot_rv_d), .req_pc_d(slot_pc_d), .ifu_ready_d(slot_ifu_d), .mmu_req_valid, .mmu_req_vtag
  );

  // ---- kill steps: K(R0) in a killed cycle, K(R1) in a predecode-flush cycle ----
  ic_regs_t k0_r_n, k1_r_n, n_regs, r1;
  logic k0_mrr, k0_dc_v, k1_mrr, k1_dc_v;
  logic [31:0] k0_dc_a, k1_dc_a;
  icache_kill u_k0 (
    .r(r_q), .mem_req_ready, .mem_req_accepted, .mem_req_accepted_id, .mem_resp_valid, .mem_resp_id,
    .r_n(k0_r_n), .mem_resp_ready(k0_mrr), .dc_req_valid(k0_dc_v), .dc_req_addr(k0_dc_a)
  );
  icache_kill u_k1 (
    .r(r1), .mem_req_ready, .mem_req_accepted, .mem_req_accepted_id, .mem_resp_valid, .mem_resp_id,
    .r_n(k1_r_n), .mem_resp_ready(k1_mrr), .dc_req_valid(k1_dc_v), .dc_req_addr(k1_dc_a)
  );

  always_comb begin
    n_regs = is_idle ? idle_r_n : swap_r_n;
    if (is_idle) begin   // the idle step only frees ids of dropped (canceled / orphan) responses
      n_regs.inflight = idle_r_n.inflight & ~drop_mask;
      n_regs.canceled = idle_r_n.canceled & ~drop_mask;
    end
    n_regs.req_valid = slot_rv_d;
    n_regs.req_pc    = slot_pc_d;
    n_regs.ifu_ready = slot_ifu_d;
    r1  = kill1 ? k0_r_n : n_regs;
    r_d = invalidate ? k1_r_n : r1;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) r_q <= IC_REGS_RESET;
    else        r_q <= r_d;
  end

  // ---- 512-bit data registers (written like memories, enable per entry) ----
  logic resp_line_we;
  logic probe_we;
  assign resp_line_we = !kill1 && swap_line_we;
  assign probe_we     = !kill1 && p_word_we && r_q.state != IC_IDLE && r_q.state != IC_CANCEL_WAIT;

  always_ff @(posedge clk) begin
    if (resp_line_we) resp_line_q <= swap_line_d;
  end

  for (genvar w = 0; w < IC_WORDS; w++) begin : g_probe_word
    always_ff @(posedge clk) begin
      if (probe_we && r_q.probe_word == IC_WORD_IDX_W'(w)) probe_line_q[IC_WORD_W * w +: IC_WORD_W] <= dc_resp_data;
    end
  end

  // ---- outputs ----
  logic unc;
  assign unc = ic_is_uncache(r_q.ppn[IC_TAG_W-1 -: 2]);

  always_comb begin
    arr_rd_en     = !refetch && (req_valid_in || r_q.req_valid);
    arr_rd_index  = r_q.req_valid ? r_q.req_pc[11:IC_OFF_W] : pc[11:IC_OFF_W];
    arr_cmp_valid = is_idle && !kill1 && ppn_valid && !page_fault && (r_q.req_valid || req_valid_in);
    inv_all       = fence_i;
    tw_we         = !kill1 && swap_tw_we;
    tw_index      = r_q.req_pc[11:IC_OFF_W];
    tw_way        = swap_tw_way;
    tw_tag        = r_q.ppn;
    tw_line       = swap_tw_line;
    resp_valid       = !kill1 && (is_idle ? idle_resp_valid : swap_resp_valid);
    resp_pc          = is_idle ? idle_resp_pc : r_q.req_pc;
    resp_page_fault  = is_idle && idle_resp_pf;
    resp_single_word = !is_idle && swap_single;
    resp_line        = is_idle ? idle_resp_line : swap_resp_line;
    icache_ready     = !(itlb_flush || fence_i) && r_q.ifu_ready && !r_q.req_valid && !r_q.miss_txv && is_idle;
  end

  // memory side: the last step of the cycle wins
  logic n_dc_v;
  always_comb begin
    n_dc_v = (r_q.state == IC_SWAP_REQ || r_q.state == IC_SWAP_WAIT || r_q.state == IC_WAIT_DC) && p_dc_req_valid;
    mem_req_valid      = !invalidate && !kill1 && swap_mem_req_valid;
    mem_req_addr       = ic_req_mem_addr(r_q.ppn, r_q.req_pc[11:0]);
    mem_req_total_size = unc ? 8'd3 : 8'(IC_LINE_W / 8 - 1);
    mem_req_bypass     = unc;
    mem_req_id         = r_q.miss_txid;
    if (invalidate) begin
      mem_resp_ready = k1_mrr;
      dc_req_valid   = k1_dc_v;
      dc_req_addr    = k1_dc_a;
    end else if (kill1) begin
      mem_resp_ready = k0_mrr;
      dc_req_valid   = k0_dc_v;
      dc_req_addr    = k0_dc_a;
    end else begin
      mem_resp_ready = drop_resp || (!is_idle && swap_mem_resp_ready) || r_q.state == IC_CANCEL_WAIT;
      dc_req_valid   = n_dc_v;
      dc_req_addr    = p_dc_req_addr;
    end
  end

endmodule

`default_nettype wire
