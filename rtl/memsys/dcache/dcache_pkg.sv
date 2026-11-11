`default_nettype none
// Ref: MemSubSystem/DcacheConfig.cpp  apply_strobe/plru_touch_way/choose_plru_tree_victim; RealDcache.h  S1S2Reg
// Shared constants and small functions of the DCache domain (docs/modules/dcache.md).
/* verilator lint_off UNUSEDPARAM */
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
  localparam int CNT_W     = DCACHE_MSHR_COUNT_BITS;       // 4: counts 0..8 (MSHR and WB have the same size)

  // second store word of a merged store request (EXP-024, model LSU_PIPE_MERGE): same line as the first word of
  // its port; strb == 0 means no second word, so every consumer can apply it unconditionally after the first
  typedef struct packed {
    logic [SBW-1:0]    strb;
    logic [WORD_W-1:0] word;
    logic [DW-1:0]     data;
  } st2_t;

  // ReplayType
  localparam logic [1:0] RP_HIT       = 2'd0;
  localparam logic [1:0] RP_CONFLICT  = 2'd1;
  localparam logic [1:0] RP_MSHR_HIT  = 2'd2;
  localparam logic [1:0] RP_MSHR_FULL = 2'd3;

  // address fields (C++ decode()): line = addr[31:6], set = addr[13:6], bank = addr[9:6], word = addr[5:2]

  // apply_strobe(): byte lanes of `nw` selected by strb replace `old`
  function automatic logic [DW-1:0] apply_strobe(input logic [DW-1:0] old, input logic [DW-1:0] nw,
                                                  input logic [SBW-1:0] strb);
    logic [DW-1:0] r;
    r = old;
    for (int b = 0; b < SBW; b++) if (strb[b]) r[8*b +: 8] = nw[8*b +: 8];
    return r;
  endfunction

  function automatic logic [DW-1:0] line_word(input logic [LINE_BITS-1:0] l, input logic [WORD_W-1:0] w);
    return l[(32'(w) * DW) +: DW];
  endfunction

  // one word of a 512-bit line is replaced under a byte strobe
  function automatic logic [LINE_BITS-1:0] line_merge(input logic [LINE_BITS-1:0] l, input logic [WORD_W-1:0] w,
                                                      input logic [DW-1:0] d, input logic [SBW-1:0] s);
    logic [LINE_BITS-1:0] r;
    r = l;
    r[(32'(w) * DW) +: DW] = apply_strobe(line_word(l, w), d, s);
    return r;
  endfunction

  // All store words of one tick merged into a line in one parallel step per byte (EXP-024: two words per port).
  // Priority (later wins): port order, lane 1 before lane 2.  Replaces a chain of line_merge() calls.
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

  // byte mask of the bytes written by the same set of store words
  function automatic logic [LINE_BITS/8-1:0] line_strb_n(
    input logic [NST-1:0]             en,
    input logic [NST-1:0][WORD_W-1:0] w1, input logic [NST-1:0][SBW-1:0] s1,
    input logic [NST-1:0][WORD_W-1:0] w2, input logic [NST-1:0][SBW-1:0] s2);
    logic [LINE_BITS/8-1:0] m;
    m = '0;
    for (int bi = 0; bi < LINE_BITS / 8; bi++) begin
      for (int k = 0; k < NST; k++) begin
        if (en[k] && w1[k] == WORD_W'(bi / SBW) && s1[k][bi % SBW]) m[bi] = 1'b1;
        if (en[k] && w2[k] == WORD_W'(bi / SBW) && s2[k][bi % SBW]) m[bi] = 1'b1;
      end
    end
    return m;
  endfunction

  // tree-PLRU (4 ways): bit0 root (1 = victim on the right), bit1 = left pair, bit2 = right pair
  function automatic logic [2:0] plru_touch(input logic [2:0] bits, input logic [1:0] way);
    logic [2:0] n;
    n = bits;
    n[0] = ~way[1];
    if (way[1]) n[2] = ~way[0];
    else        n[1] = ~way[0];
    return n;
  endfunction

  function automatic logic [1:0] plru_victim(input logic [2:0] bits);
    return {bits[0], bits[0] ? bits[2] : bits[1]};
  endfunction
endpackage
`default_nettype wire
