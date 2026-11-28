// Ref: docs/modules/soc_axi.md  ARM IHI 0022E AXI4 constants and burst address helpers
`default_nettype none
/* verilator lint_off UNUSEDPARAM */
package soc_axi_pkg;

  // ---- AXI4 Burst types ----
  localparam logic [1:0] AXI4_BURST_FIXED = 2'b00;
  localparam logic [1:0] AXI4_BURST_INCR  = 2'b01;
  localparam logic [1:0] AXI4_BURST_WRAP  = 2'b10;

  // ---- AXI4 Response codes ----
  localparam logic [1:0] AXI4_RESP_OKAY   = 2'b00;
  localparam logic [1:0] AXI4_RESP_SLVERR = 2'b10;
  localparam logic [1:0] AXI4_RESP_DECERR = 2'b11;

  // ---- AXI4 Cache encodings (ARM IHI 0022E Table A4-5) ----
  localparam logic [3:0] AXI4_CACHE_NORM_NC_BUF = 4'b0011;  // Normal Non-cacheable Bufferable (post-LLC DDR)

  // ---- AXI4 Prot encodings ----
  localparam logic [2:0] AXI4_PROT_DATA_NONSEC  = 3'b000;

  // ---- AXI4 next-beat address calculation (FIXED / INCR / WRAP) ----
  // ARM IHI 0022E Section A3.4.1: aligns unaligned start address to transfer size after beat 0.
  function automatic logic [31:0] axi4_next_addr(
    input logic [31:0] cur_addr,
    input logic [2:0]  size,
    input logic [1:0]  burst,
    input logic [7:0]  len
  );
    logic [31:0] step;
    logic [31:0] aligned_cur;
    logic [31:0] incr_addr;
    logic [31:0] wrap_bytes;
    logic [31:0] wrap_mask;
    step        = 32'd1 << size;
    aligned_cur = cur_addr & ~(step - 32'd1);
    incr_addr   = aligned_cur + step;
    if (burst == AXI4_BURST_FIXED) begin
      return cur_addr;
    end else if (burst == AXI4_BURST_WRAP) begin
      // WRAP bursts have len in {1, 3, 7, 15} => (len + 1) is a power of 2
      wrap_bytes = (32'(len) + 32'd1) << size;
      wrap_mask  = wrap_bytes - 32'd1;
      return (aligned_cur & ~wrap_mask) | (incr_addr & wrap_mask);
    end else begin
      return incr_addr;
    end
  endfunction

  // ---- Worst-case response combiner (DECERR > SLVERR > OKAY) ----
  function automatic logic [1:0] axi4_merge_resp(
    input logic [1:0] a,
    input logic [1:0] b
  );
    if (a == AXI4_RESP_DECERR || b == AXI4_RESP_DECERR)      return AXI4_RESP_DECERR;
    else if (a == AXI4_RESP_SLVERR || b == AXI4_RESP_SLVERR) return AXI4_RESP_SLVERR;
    else                                                     return AXI4_RESP_OKAY;
  endfunction

  // ---- 64-bit register write with byte strobes (CLINT / SYSCTRL) ----
  function automatic logic [63:0] axi4_apply_strb(
    input logic [63:0] old_v, input logic [63:0] new_v, input logic [7:0] strb
  );
    logic [63:0] res;
    for (int b = 0; b < 8; b++) res[8*b +: 8] = strb[b] ? new_v[8*b +: 8] : old_v[8*b +: 8];
    return res;
  endfunction

  // ---- Width downsizer burst split (soc_axi_downsizer write side, soc_axi_downsizer_rd) ----
  // m_off_w = log2(master bytes per beat). A slave beat of size sz > m_off_w becomes 2^(sz - m_off_w) master beats.
  // sub-beat counter max (callers cut to their SUB_W)
  function automatic logic [31:0] axi4_ds_sub_max(input logic [2:0] sz, input int m_off_w);
    if (int'(sz) <= m_off_w) return '0;
    else                     return (32'd1 << (int'(sz) - m_off_w)) - 32'd1;
  endfunction

  function automatic logic [7:0] axi4_ds_m_len(input logic [7:0] slen, input logic [2:0] sz, input int m_off_w);
    if (int'(sz) <= m_off_w) return slen;
    else                     return 8'(((32'(slen) + 32'd1) << (int'(sz) - m_off_w)) - 32'd1);
  endfunction

  function automatic logic [2:0] axi4_ds_m_size(input logic [2:0] sz, input int m_off_w);
    if (int'(sz) <= m_off_w) return sz;
    else                     return 3'(m_off_w);
  endfunction

endpackage
/* verilator lint_on UNUSEDPARAM */
`default_nettype wire
