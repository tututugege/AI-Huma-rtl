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
`define AXI_LLC_MSHR 8
`endif

// lint: address helpers use only part of the address; constants are used by the units.
/* verilator lint_off UNUSEDSIGNAL */
package axi_llc_pkg;
  /* verilator lint_off UNUSEDPARAM */
  localparam int SETS  = `AXI_LLC_SETS;
  localparam int WAYS  = `AXI_LLC_WAYS;
  localparam int NMSHR = `AXI_LLC_MSHR;   // MSHR slot id travels in the 4-bit AXI id (bit 3 = 0): only 8 supported
  localparam int MIDW  = $clog2(NMSHR);
  localparam int NR    = 4;               // read masters
  localparam int NW    = 2;               // write masters
  localparam int SB    = $clog2(SETS);
  localparam int WB    = $clog2(WAYS);
  localparam int TAGW  = 32 - 6 - SB;
  localparam int RQD   = 2;               // read response queue depth behind the response register (C++ 32, max 1)
  localparam int RQC   = RQD + 1;         // response register + queue = capacity of one read response unit
  localparam int WQD   = 2;               // write request queue depth per master (C++ 32, observed 0 at tick end)
  localparam int VQD   = 8;               // read victim write-back queue depth (C++ 32; programs: 2, random: 7)
  localparam int VQW   = $clog2(VQD);
  localparam int NVL   = 1 + VQD + NW + NMSHR;  // victim-holder list: write-back slot, queue, write contexts, MSHRs
  /* verilator lint_on UNUSEDPARAM */

  typedef logic [511:0] line_t;
  typedef logic [31:0]  addr_t;

  // table write request (one per tick at most; all fields are the new row contents)
  typedef struct packed {
    logic line_en;                  // data + tag + dirty + valid of one way
    logic repl_en;                  // replacement pointer of the set
    logic [SB-1:0] set;
    logic [WB-1:0] way;
    line_t data;
    logic [TAGW-1:0] tag;
    logic dirty;
    logic [WB-1:0] repl;
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
  function automatic logic [WB-1:0] next_way(input logic [WB-1:0] w);
    return w + WB'(1);               // WAYS is a power of two (checked in axi_llc)
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
