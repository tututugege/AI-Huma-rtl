// Ref: front-end/icache/include/icache_module.h  ICache_regs_t / ICacheState;  icache_module.cpp (address helpers)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */  // constants package: not every constant is used by every module
package icache_pkg;
  import ttg_cfg_pkg::*;

  localparam int IC_WAYS     = ICACHE_WAY_NUM;      // 8
  localparam int IC_SETS     = ICACHE_SET_NUM;      // 64
  localparam int IC_IDX_W    = ICACHE_INDEX_BITS;   // 6
  localparam int IC_OFF_W    = ICACHE_OFFSET_BITS;  // 6
  localparam int IC_WORDS    = ICACHE_WORD_NUM;     // 16 words of 32 bits per line
  localparam int IC_WORD_W   = 32;
  localparam int IC_LINE_W   = IC_WORDS * IC_WORD_W;
  localparam int IC_TAG_W    = ICACHE_TAG_BITS;     // 20 = ppn
  localparam int IC_WAY_W    = $clog2(IC_WAYS);
  localparam int IC_WORD_IDX_W = $clog2(IC_WORDS);
  localparam int IC_TXID_N   = 16;                  // AXI transaction ids tracked
  localparam int IC_TXID_W   = 4;

  // FSM state.  The C++ keeps (state, mem_axi_state); mem_axi_state==BUSY only ever occurs in SWAP_IN (every exit from
  // SWAP_IN resets it), so the pair is one 5-state encoding.  DRAIN is unreachable (nothing enters it) and not encoded.
  typedef enum logic [2:0] {
    IC_IDLE        = 3'd0,
    IC_SWAP_REQ    = 3'd1,   // SWAP_IN, request not yet accepted by the AXI master port
    IC_SWAP_WAIT   = 3'd2,   // SWAP_IN, request accepted, waiting for the response
    IC_WAIT_DC     = 3'd3,   // WAIT_DCACHE_AFTER_MEM
    IC_CANCEL_WAIT = 3'd4    // CANCEL_WAIT_ACCEPT
  } ic_state_e;

  // all registers of the control FSM except the two 512-bit data registers (resp_line_q, probe_line_q)
  typedef struct packed {
    logic                   req_valid;      // req_valid_r
    logic [31:0]            req_pc;         // req_pc_r (req_index_r = req_pc[11:6])
    logic                   ifu_ready;      // ifu_req_ready_r
    ic_state_e              state;
    logic                   miss_txv;       // miss_txid_valid_r
    logic [IC_TXID_W-1:0]   miss_txid;
    logic                   ready_seen;     // miss_ready_seen_r
    logic [IC_TXID_N-1:0]   inflight;       // txid_inflight_r
    logic [IC_TXID_N-1:0]   canceled;       // txid_canceled_r
    logic                   probe_inflight; // dcache_probe_inflight_r
    logic                   probe_done;     // dcache_probe_done_r
    logic                   probe_hit;      // dcache_probe_hit_r
    logic [IC_WORD_IDX_W-1:0] probe_word;   // dcache_probe_word_r
    logic [IC_TAG_W-1:0]    ppn;            // ppn_r
    logic [IC_WAY_W-1:0]    replace_idx;    // replace_idx (round-robin pointer, global)
  } ic_regs_t;

  localparam ic_regs_t IC_REGS_RESET = '{
    req_valid: 1'b0, req_pc: 32'd0,
    // see docs/modules/icache.md 4.1 item 5 (C++ holds 1 but the first peek also sees a false module output)
    ifu_ready: 1'b0,
    state: IC_IDLE, miss_txv: 1'b0, miss_txid: '0, ready_seen: 1'b0, inflight: '0, canceled: '0,
    probe_inflight: 1'b0, probe_done: 1'b0, probe_hit: 1'b0, probe_word: '0, ppn: '0, replace_idx: '0
  };

  // non-cacheable fetch: physical address below 0x40000000 (CONFIG_ICACHE_MMIO_UNCACHE_LIMIT) <=> ppn[19:18]==0
  function automatic logic ic_is_uncache(input logic [1:0] ppn_hi);
    return ppn_hi == 2'b00;
  endfunction

  // icache_req_mem_addr(): one word for an uncached request, otherwise the line base
  function automatic logic [31:0] ic_req_mem_addr(input logic [IC_TAG_W-1:0] ppn, input logic [11:0] pc_low);
    return ic_is_uncache(ppn[IC_TAG_W-1 -: 2]) ? {ppn, pc_low} : {ppn, pc_low[11:IC_OFF_W], {IC_OFF_W{1'b0}}};
  endfunction

  // DCache probe address of word `word` of the line being fetched
  function automatic logic [31:0] ic_probe_addr(input logic [IC_TAG_W-1:0] ppn, input logic [IC_IDX_W-1:0] idx,
                                                input logic [IC_WORD_IDX_W-1:0] word);
    return {ppn, idx, word, 2'b00};
  endfunction

  function automatic logic [IC_TXID_N-1:0] ic_txid_onehot(input logic [IC_TXID_W-1:0] id);
    return IC_TXID_N'(1) << id;
  endfunction

endpackage
`default_nettype wire
