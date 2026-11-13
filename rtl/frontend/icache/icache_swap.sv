// Ref: front-end/icache/icache_module.cpp  ICache::eval_state_machine  cases SWAP_IN / WAIT_DCACHE_AFTER_MEM /
// CANCEL_WAIT_ACCEPT,
//      latch_mem_refill, finish_refill
`default_nettype none

// Miss service step (no kill): issue the AXI read of the line (or one word if uncached), wait for the response,
// wait for the
// DCache probe to finish, then refill (write one way of the set, answer the fetch).  Also the CANCEL_WAIT cycle.
module icache_swap import ttg_cfg_pkg::*; import icache_pkg::*; (
  input  ic_regs_t                r,
  // port values
  input  logic                    mem_req_ready,
  input  logic                    mem_req_accepted,
  input  logic [IC_TXID_W-1:0]    mem_req_accepted_id,
  input  logic [IC_LINE_W-1:0]    mem_resp_data,
  // response classification and probe step (shared sub-blocks of icache_ctl)
  input  logic                    active_resp,
  input  logic [IC_TXID_N-1:0]    drop_mask,
  input  logic                    step_done,
  input  logic                    step_hit,
  input  logic                    probe_inflight_d,
  input  logic                    probe_done_d,
  input  logic                    probe_hit_d,
  input  logic [IC_WORD_IDX_W-1:0] probe_word_d,
  input  logic [IC_LINE_W-1:0]    probe_line_eff,   // probed line incl. the word arriving this cycle
  input  logic [IC_LINE_W-1:0]    resp_line_q,      // memory line latched earlier (mem_resp_data_r)
  // set status (meta of the request's set)
  input  logic                    has_invalid,
  input  logic [IC_WAY_W-1:0]     first_invalid,
  input  logic                    hit2,             // RVC=1: the second line (set + 1, tag ppn_r) is present
  output ic_regs_t                r_n,
  output logic                    req_ready,
  output logic                    mem_req_valid,
  output logic                    mem_resp_ready,   // excluding the canceled/orphan drop (OR-ed by the caller)
  output logic                    resp_valid,
  output logic                    resp_single_word,
  output logic [IC_LINE_W-1:0]    resp_line,
  output logic                    resp_line_we,     // latch mem_resp_data_r
  output logic [IC_LINE_W-1:0]    resp_line_d,
  output logic                    tw_we,
  output logic [IC_WAY_W-1:0]     tw_way,
  output logic [IC_LINE_W-1:0]    tw_line,
  output logic                    pc_ovr_valid,     // RVC=1: the registered request pc is replaced (second line replay)
  output logic [XLEN_BITS-1:0]             pc_ovr
);

  logic sw_req, sw_wait, wdc, cw, unc, accepted_sel, ready_seen_now, gnt, to_wdc;
  logic finish_swap, finish_wdc, finish, cw_acc;
  logic xl_fill, xl_after_fill, xl_quiet;
  logic [IC_WAY_W-1:0] replace_next;
  logic [IC_LINE_W-1:0] mem_line_w;
  logic [IC_TXID_N-1:0] txid_mask;

  always_comb begin
    sw_req = r.state == IC_SWAP_REQ;  sw_wait = r.state == IC_SWAP_WAIT;
    wdc = r.state == IC_WAIT_DC;      cw = r.state == IC_CANCEL_WAIT;
    unc = ic_is_uncache(r.ppn[IC_TAG_W-1 -: 2]);
    accepted_sel   = mem_req_accepted && mem_req_accepted_id == r.miss_txid;
    ready_seen_now = sw_req && mem_req_ready && r.miss_txv;
    gnt            = (sw_req && accepted_sel && active_resp) || (sw_wait && active_resp);
    to_wdc         = gnt && !step_done;
    finish_swap    = gnt && step_done;
    finish_wdc     = wdc && step_done;
    finish         = finish_swap || finish_wdc;
    cw_acc         = cw && mem_req_accepted && r.miss_txv && accepted_sel;
    txid_mask      = ic_txid_onehot(r.miss_txid);
    mem_req_valid  = sw_req && !accepted_sel;
    mem_resp_ready = gnt;
  end

  // refill data: an uncached read returns one word, placed at its position in an otherwise empty line
  always_comb begin
    mem_line_w = '0;
    if (unc) mem_line_w[IC_WORD_W * r.req_pc[IC_OFF_W-1:2] +: IC_WORD_W] = mem_resp_data[IC_WORD_W-1:0];
    else     mem_line_w = mem_resp_data;
    replace_next = unc ? r.replace_idx : (has_invalid ? first_invalid : r.replace_idx + IC_WAY_W'(1));
    resp_line_we = gnt;
    resp_line_d  = mem_line_w;
    resp_single_word = finish && unc;
    resp_line        = step_hit ? probe_line_eff : (wdc ? resp_line_q : mem_line_w);
    // RVC=1 second line: a fill of the second line is not an answer (the original request is replayed); a fill of a
    // line whose request needs its second line, which is not present, is not answered either (the replay starts the
    // second-line fetch)
    xl_fill       = finish && r.xl_phase;
    xl_after_fill = finish && !unc && !r.xl_phase && !r.xl_done &&
                    ic_xl_cand(r.req_pc[5:0], r.ppn[IC_TAG_W-1 -: 2], resp_line[IC_WORD_W * 15 + 16 +: 2]) &&
                    (r.req_pc[11:IC_OFF_W] == '1 || !hit2);
    xl_quiet      = xl_fill || xl_after_fill;
    resp_valid       = finish && !xl_quiet;
    tw_we   = finish && !unc;
    tw_way  = wdc ? r.replace_idx : replace_next;
    tw_line = resp_line;
  end

  always_comb begin
    r_n = r;
    if (sw_req || sw_wait || wdc) begin
      r_n.probe_inflight = probe_inflight_d;  r_n.probe_done = probe_done_d;
      r_n.probe_hit = probe_hit_d;            r_n.probe_word = probe_word_d;
    end
    if (ready_seen_now) r_n.ready_seen = 1'b1;
    r_n.inflight = r.inflight & ~drop_mask;
    r_n.canceled = r.canceled & ~drop_mask;
    req_ready = 1'b0;
    pc_ovr_valid = finish && r.xl_phase;
    pc_ovr       = r.xl_pc;
    if (sw_req && accepted_sel && !active_resp) begin
      r_n.state = IC_SWAP_WAIT;
      r_n.inflight = (r.inflight & ~drop_mask) | txid_mask;
    end
    if (gnt) r_n.replace_idx = replace_next;
    if (to_wdc) begin
      r_n.state = IC_WAIT_DC;  r_n.miss_txv = 1'b0;  r_n.ready_seen = 1'b0;
      r_n.inflight = (r.inflight & ~drop_mask) & ~txid_mask;
    end
    if (finish) begin
      r_n.state = IC_IDLE;  r_n.miss_txv = 1'b0;  r_n.ready_seen = 1'b0;
      r_n.probe_inflight = 1'b0;  r_n.probe_done = 1'b0;  r_n.probe_hit = 1'b0;  r_n.probe_word = '0;
      if (r.miss_txv) r_n.inflight = (r.inflight & ~drop_mask) & ~txid_mask;
      req_ready = !xl_quiet;
      if (!xl_quiet) r_n.xl_done = 1'b0;
      if (xl_fill) begin
        r_n.xl_phase = 1'b0;  r_n.xl_done = 1'b1;  r_n.xl_fault = 1'b0;  r_n.xl_ppn = r.ppn;
      end
    end
    if (cw) begin
      r_n.state = IC_IDLE;  r_n.miss_txv = 1'b0;  r_n.ready_seen = 1'b0;
      r_n.probe_inflight = 1'b0;  r_n.probe_done = 1'b0;  r_n.probe_hit = 1'b0;  r_n.probe_word = '0;
      if (cw_acc) begin
        r_n.inflight = (r.inflight & ~drop_mask) | txid_mask;
        r_n.canceled = (r.canceled & ~drop_mask) | txid_mask;
      end
      req_ready = 1'b1;
    end
  end

endmodule

`default_nettype wire
