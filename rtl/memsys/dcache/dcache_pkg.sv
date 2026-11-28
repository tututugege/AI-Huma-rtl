`default_nettype none
// Ref: RealDcache.h  decode() (tree PLRU: ttg_util_pkg::ttg_plru4_*, ReplayType: memcpu_pkg::REPLAY_*)
// Shared constants and small functions of the DCache domain (docs/modules/dcache.md).
package dcache_pkg;
  import ttg_cfg_pkg::*;

  localparam int NLD       = LSU_LDU_COUNT;                // load ports            (slots 0..NLD-1)
  localparam int NST       = LSU_STA_COUNT;                // store ports           (slots NLD..NSLOT-1)
  localparam int NSLOT     = NLD + NST;
  localparam int WAYS      = DCACHE_WAYS_NUM;
  localparam int WORDS     = DCACHE_WORD_NUM;
  // data word of the core side (LSU <-> dcache): XLEN bits; the line (and the AXI side) stays a vector of 32-bit words
  localparam int DW        = XLEN_BITS;
  localparam int SBW       = DW / 8;                       // byte-strobe width of one data word
  localparam int SB_OFF    = $clog2(SBW);                  // address bits inside a data word
  localparam int LINE_BITS = WORDS * 32;
  localparam int DWORDS    = LINE_BITS / DW;               // data words per line
  localparam int WORD_W    = $clog2(DWORDS);               // index of a data word inside a line
  localparam int SET_W     = DCACHE_SET_BITS;
  localparam int TAG_W     = DCACHE_TAG_BITS;
  localparam int LINE_W    = SET_W + TAG_W;                // line address = addr[31:6]
  localparam int OFF_W     = DCACHE_OFFSET_BITS;
  localparam int BANKS     = DCACHE_BANK_NUM;
  localparam int BANK_W    = DCACHE_BANK_BITS;
  localparam int ROW_W     = SET_W - BANK_W;               // set = {row, bank}
  localparam int ROWS      = 1 << ROW_W;
  localparam int MSHR_N    = DCACHE_MSHR_ENTRIES;
  localparam int MSHR_IDW  = DCACHE_MSHR_BITS;
  localparam int WB_N      = DCACHE_WB_ENTRIES;
  localparam int WB_IDW    = DCACHE_WB_BITS;
  localparam int CNT_W     = DCACHE_MSHR_COUNT_BITS;       // free counts 0..MSHR_N (16) and 0..WB_N

  // second store word of a merged store request (EXP-024, model LSU_PIPE_MERGE): same line as the first word of
  // its port; strb == 0 means no second word, so every consumer can apply it unconditionally after the first
  typedef struct packed {
    logic [SBW-1:0]    strb;
    logic [WORD_W-1:0] word;
    logic [DW-1:0]     data;
  } st2_t;

  // address fields (C++ decode()): line = addr[31:6], set = addr[13:6], bank = addr[9:6], word = addr[5:3]

  function automatic logic [DW-1:0] line_word(input logic [LINE_BITS-1:0] l, input logic [WORD_W-1:0] w);
    return l[(32'(w) * DW) +: DW];
  endfunction

  // All store words of one tick merged into a line in one parallel step per byte (EXP-024: two words per port).
  // Priority (later wins): port order, lane 1 before lane 2.
  function automatic logic [LINE_BITS-1:0] line_merge_n(
    input logic [LINE_BITS-1:0]       l,
    input logic [NST-1:0]             en,
    input logic [NST-1:0][WORD_W-1:0] w1, input logic [NST-1:0][DW-1:0] d1, input logic [NST-1:0][SBW-1:0] s1,
    input logic [NST-1:0][WORD_W-1:0] w2, input logic [NST-1:0][DW-1:0] d2, input logic [NST-1:0][SBW-1:0] s2);
    logic [LINE_BITS-1:0] r;
    r = l;
    for (int bi = 0; bi < LINE_BITS / 8; bi++) begin
      for (int k = 0; k < NST; k++) begin
        if (en[k] && w1[k] == WORD_W'(bi / SBW) && s1[k][bi % SBW]) r[8*bi +: 8] = d1[k][8*(bi % SBW) +: 8];
        if (en[k] && w2[k] == WORD_W'(bi / SBW) && s2[k][bi % SBW]) r[8*bi +: 8] = d2[k][8*(bi % SBW) +: 8];
      end
    end
    return r;
  endfunction
endpackage
`default_nettype wire
