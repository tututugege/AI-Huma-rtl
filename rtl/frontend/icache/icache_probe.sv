// Ref: front-end/icache/icache_module.cpp  ICache::eval_state_machine step_dcache_probe / reset_dcache_probe_regs
`default_nettype none

// One step of the DCache coherent word probe: while a line is being fetched from memory the I-cache asks the
// D-cache for
// the 16 words of the same line, one word at a time (request has no ready, it is a one-cycle pulse; the response
// arrives in a later cycle and may ask for a retry).  If all 16 words hit, the probed line replaces the memory line
// (self-modifying code).  An uncached fetch has nothing to probe: done immediately, no hit.
module icache_probe import icache_pkg::*; (
  input  logic                    req_valid,        // a request is registered (req_valid_r)
  input  logic [IC_TAG_W-1:0]     ppn,
  input  logic [IC_IDX_W-1:0]     req_index,        // set of the request (req_pc[11:6])
  input  logic                    probe_inflight,
  input  logic                    probe_done,
  input  logic                    probe_hit,
  input  logic [IC_WORD_IDX_W-1:0] probe_word,
  input  logic                    dc_resp_valid,
  input  logic                    dc_resp_retry,
  input  logic                    dc_resp_miss,
  output logic                    dc_req_valid,
  output logic [31:0]             dc_req_addr,
  output logic                    step_done,
  output logic                    step_hit,
  output logic                    word_we,          // probe_line[probe_word] <= dc_resp_data
  output logic                    probe_inflight_d,
  output logic                    probe_done_d,
  output logic                    probe_hit_d,
  output logic [IC_WORD_IDX_W-1:0] probe_word_d
);

  logic early_done, issue, take, got_miss, got_hit, last_word;

  always_comb begin
    early_done = req_valid && ic_is_uncache(ppn[IC_TAG_W-1 -: 2]);
    issue      = !early_done && !probe_done && !probe_inflight && req_valid;
    take       = !early_done && probe_inflight && dc_resp_valid;
    got_miss   = take && !dc_resp_retry && dc_resp_miss;
    got_hit    = take && !dc_resp_retry && !dc_resp_miss;
    last_word  = probe_word == IC_WORD_IDX_W'(IC_WORDS - 1);
    dc_req_valid = issue;
    dc_req_addr  = ic_probe_addr(ppn, req_index, probe_word);
    word_we      = got_hit;
  end

  always_comb begin
    step_done        = probe_done;
    step_hit         = probe_hit;
    probe_inflight_d = probe_inflight;
    probe_done_d     = probe_done;
    probe_hit_d      = probe_hit;
    probe_word_d     = probe_word;
    if (early_done) begin
      step_done = 1'b1;  step_hit = 1'b0;
      probe_inflight_d = 1'b0;  probe_done_d = 1'b1;  probe_hit_d = 1'b0;  probe_word_d = '0;
    end else begin
      if (issue) probe_inflight_d = 1'b1;
      if (take)  probe_inflight_d = 1'b0;
      if (got_miss) begin
        step_done = 1'b1;  step_hit = 1'b0;  probe_done_d = 1'b1;  probe_hit_d = 1'b0;
      end
      if (got_hit) begin
        step_hit = 1'b1;  probe_hit_d = 1'b1;
        if (last_word) begin step_done = 1'b1;  probe_done_d = 1'b1; end
        else           probe_word_d = probe_word + IC_WORD_IDX_W'(1);
      end
    end
  end

endmodule

`default_nettype wire
