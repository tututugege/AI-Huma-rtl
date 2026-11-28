`default_nettype none
// Ref: axi-interconnect-kit/axi_interconnect/include/AXI_LLC.h  (AXI_LLC_Regs_t, table interface)
// Geometry macros, small shared types and the address helpers of the LLC (docs/modules/axi_llc.md section 6).
// No state struct: every unit owns its registers (see the unit list in the design note).

`ifndef AXI_LLC_SETS
`define AXI_LLC_SETS 4096
`endif
`ifndef AXI_LLC_WAYS
`define AXI_LLC_WAYS 16
`endif
`ifndef AXI_LLC_MSHR
`define AXI_LLC_MSHR 16
`endif

// lint: address helpers use only part of the address; constants are used by the units.
/* verilator lint_off UNUSEDSIGNAL */
package axi_llc_pkg;
  localparam int SETS  = `AXI_LLC_SETS;
  localparam int WAYS  = `AXI_LLC_WAYS;
  localparam int NMSHR = `AXI_LLC_MSHR;   // MSHR slot id travels in the 4-bit AXI id (8 or 16 supported)
  localparam int MIDW  = $clog2(NMSHR);
  localparam int NR    = 4;               // read masters
  localparam int NW    = 2;               // write masters
  localparam int SB    = $clog2(SETS);
  localparam int WB    = $clog2(WAYS);
  localparam int RB    = 2 * WAYS;        // replacement state of a set: a 2-bit RRPV per way (SRRIP)
  localparam int TAGW  = 32 - 6 - SB;
  localparam int RQD   = 16;              // read response queue depth (C++ 32; sized for 16 MSHRs)
  localparam int RQC   = RQD + 1;         // response register + queue = capacity of one read response unit
  localparam int WQD   = 2;               // write request queue depth per master (C++ 32, observed 0 at tick end)
  localparam int VQD   = 32;              // read victim write-back queue depth (matches C++ 32; 16 MSHRs + BOP)
  localparam int VQW   = $clog2(VQD);
  localparam int NVL   = 1 + VQD + NW + NMSHR;  // victim-holder list: write-back slot, queue, write contexts, MSHRs
  // EXP-048 LLC Best-Offset prefetcher (LLC_BOP=1) + EXP-058 LLC Bingo 4KB
  localparam int BOP_Q          = 8;
  localparam int BOP_RES        = 2;
  localparam int BOP_INF        = 8;
  localparam int BOP_OFFS       = 26;
  localparam int BOP_RR_BITS    = 8;
  localparam int BOP_RR_SZ      = 1 << BOP_RR_BITS;
  localparam int BOP_ROUNDS     = 100;
  localparam int BOP_SCORE_MAX  = 31;
  localparam int BOP_BAD        = 1;
  localparam int BINGO_FT_N     = 32;
  localparam int BINGO_AGT_N    = 32;
  localparam int BINGO_PHTL_SETS = 256;
  localparam int BINGO_PHTS_SETS = 128;
  localparam int BINGO_PHT_WAYS = 4;
  localparam int BINGO_CMTQ_N   = 4;
  localparam int BINGO_Q        = 16;
  localparam int BINGO_DEG      = 16;
  localparam int BINGO_THR_DEG  = 2;
  localparam int BINGO_MAXDENSE = 48;
  localparam int BINGO_TWIN     = 256;
  localparam int BINGO_TMIN     = 26;

  typedef logic [511:0] line_t;
  typedef logic [31:0]  addr_t;

  // table write request (one per tick at most; all fields are the new row contents)
  typedef struct packed {
    logic line_en;                  // data + tag + dirty + pf + valid of one way
    logic repl_en;                  // replacement state of the set
    logic pf_clr;                   // clear prefetch mark of one way on demand hit
    logic [SB-1:0] set;
    logic [WB-1:0] way;
    line_t data;
    logic [TAGW-1:0] tag;
    logic dirty;
    logic pf;
    logic [RB-1:0] repl;
  } tw_t;

  // ---------------- address helpers ----------------
  function automatic addr_t line_of(input addr_t a);
    return {a[31:6], 6'b0};
  endfunction
  function automatic logic [SB-1:0] set_of(input addr_t a);
    return a[6 +: SB];
  endfunction
  function automatic logic [TAGW-1:0] tag_of(input addr_t a);
    return a[31 -: TAGW];
  endfunction
  function automatic addr_t addr_of(input logic [TAGW-1:0] t, input logic [SB-1:0] s);
    return {t, s, 6'b0};
  endfunction
  // SRRIP (docs/modules/axi_llc.md section 5.2): a hit sets the way's RRPV to 0; an allocation first ages the set so
  // that its largest RRPV is 3, then gives the new line 2.
  function automatic logic [RB-1:0] rrip_hit(input logic [RB-1:0] r, input logic [WB-1:0] w);
    logic [RB-1:0] o;
    o = r;
    o[2 * w +: 2] = 2'd0;
    return o;
  endfunction
  function automatic logic [RB-1:0] rrip_alloc(input logic [RB-1:0] r, input logic [WB-1:0] w);
    logic [RB-1:0] o;
    logic [1:0] mx, add;
    mx = 2'd0;
    for (int i = 0; i < WAYS; i++) if (r[2 * i +: 2] > mx) mx = r[2 * i +: 2];
    add = 2'd3 - mx;
    for (int i = 0; i < WAYS; i++) o[2 * i +: 2] = r[2 * i +: 2] + add;
    o[2 * w +: 2] = 2'd2;
    return o;
  endfunction
  // extract_line_response: words start at the word offset of the address
  function automatic line_t resp_of(input addr_t a, input line_t line);
    return line >> {a[5:2], 5'b0};
  endfunction
  function automatic logic is_full_write(input addr_t a, input logic [63:0] strb, input logic [7:0] size);
    return a[5:0] == 6'd0 && size == 8'd63 && (&strb);
  endfunction
endpackage
/* verilator lint_on UNUSEDSIGNAL */

`default_nettype wire
