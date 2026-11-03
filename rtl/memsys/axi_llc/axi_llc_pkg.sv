`default_nettype none
// Ref: axi-interconnect-kit/axi_interconnect/include/AXI_LLC.h  (AXI_LLC_Regs_t, AXI_LLC_ExtIn_t/ExtOut_t, table
// interface)
// Types of the LLC state / stage chain and the address helpers.  Geometry from macros (docs/modules/axi_llc.md
// section 6).

`ifndef AXI_LLC_SETS
`define AXI_LLC_SETS 4096
`endif
`ifndef AXI_LLC_WAYS
`define AXI_LLC_WAYS 16
`endif
`ifndef AXI_LLC_MSHR
`define AXI_LLC_MSHR 8
`endif

// lint: address helpers use only part of the address.
/* verilator lint_off UNUSEDSIGNAL */
package axi_llc_pkg;
  /* verilator lint_off UNUSEDPARAM */
  localparam int SETS  = `AXI_LLC_SETS;
  localparam int WAYS  = `AXI_LLC_WAYS;
  localparam int NMSHR = `AXI_LLC_MSHR;   // slot id is 3 bits: only 8 supported
  localparam int NR    = 4;               // read masters
  localparam int NW    = 2;               // write masters
  localparam int SB    = $clog2(SETS);
  localparam int WB    = $clog2(WAYS);
  localparam int TAGW  = 32 - 6 - SB;
  localparam int RQD   = 2;               // read response queue depth per master (C++ 32, observed max 1)
  localparam int WQD   = 2;               // write request queue depth per master (C++ 32, observed 0 at tick end)
  localparam int VQD   = 8;               // read victim write-back queue depth (C++ 32; 68 programs: max 2; random: 5)
  localparam int VQW   = $clog2(VQD);
  localparam logic [3:0] SLOT_INV = 4'hF; // AXI_LLC_INVALID_VICTIM_MSHR_SLOT
  /* verilator lint_on UNUSEDPARAM */

  typedef logic [511:0] line_t;
  typedef logic [31:0]  addr_t;

  // ---------------- registers (AXI_LLC_Regs_t, live fields only) ----------------
  typedef struct packed {
    logic valid, fresh;
    logic [3:0] id;
    line_t data;
    logic [1:0] qcnt;
    logic qhead, qtail;
    logic [RQD-1:0][3:0] qid;
    logic [RQD-1:0][511:0] qdata;
  } rresp_t;

  typedef struct packed {
    logic [3:0] id;
    logic [7:0] size;
    addr_t addr;
    line_t data;
    logic [63:0] strb;
  } wq_ent_t;

  typedef struct packed {
    logic [1:0] cnt;
    logic head, tail;
    wq_ent_t [WQD-1:0] ent;
  } wq_t;

  typedef struct packed {
    logic valid, lpend, cdone, cpend, vmdone, vdirty;
    logic [3:0] id;
    logic [7:0] size;
    addr_t addr, vaddr;
    logic [WB-1:0] way;
    line_t data;
    logic [63:0] strb;
    line_t line;
  } wctx_t;

  typedef struct packed {
    logic valid;
    logic [3:0] id;
    logic [1:0] code;
    addr_t line;
  } wresp_t;

  typedef struct packed {
    logic valid, issued, forw, wm;
    logic [3:0] slot;
    addr_t addr;
    line_t data;
  } vwb_t;

  typedef struct packed {
    logic valid;
    logic [3:0] owner;
    addr_t addr;
    line_t data;
  } rvq_ent_t;

  typedef logic [VQW-1:0] vq_idx_t;
  typedef logic [VQW:0]   vq_cnt_t;

  typedef struct packed {
    vq_cnt_t cnt;
    vq_idx_t head, tail;
    rvq_ent_t [VQD-1:0] ent;
  } rvq_t;

  typedef struct packed {
    logic valid, bypass, mem_issued, rvalid, rcomm, vdirty, vdone;
    addr_t addr, vaddr;
    logic [WB-1:0] way;
    logic [7:0] size;
    logic [1:0] master;
    logic [3:0] id;
    line_t vdata, rdata;
  } mshr_t;

  typedef struct packed {
    logic lv, li, lw, lb;
    addr_t laddr;
    logic [7:0] lsize;
    logic [1:0] lmaster;
    logic [3:0] lid;
    logic [1:0] rr_read;
    logic rr_write;
    rresp_t [NR-1:0] rr;
    wq_t [NW-1:0] wq;
    wctx_t [NW-1:0] wc;
    wresp_t [NW-1:0] wr;
    vwb_t vwb;
    rvq_t rvq;
    mshr_t [NMSHR-1:0] ms;
  } st_t;

  // ---------------- per-tick inputs (AXI_LLC_ExtIn_t + table row) ----------------
  typedef struct packed {
    logic [NR-1:0] rd_v, rd_byp, rd_ready;
    addr_t [NR-1:0] rd_addr;
    logic [NR-1:0][7:0] rd_size;
    logic [NR-1:0][3:0] rd_id;
    logic [NW-1:0] wr_v, wr_byp, wr_ready;
    addr_t [NW-1:0] wr_addr;
    logic [NW-1:0][7:0] wr_size;
    logic [NW-1:0][3:0] wr_id;
    logic [NW-1:0][511:0] wr_data;
    logic [NW-1:0][63:0] wr_strb;
    logic mrd_ready, mrr_v, mwr_ready, mwr_resp_v;
    line_t mrr_data;
    logic [3:0] mrr_id;
    logic [1:0] mwr_resp;
    // table row delivered by the 3-tick read
    logic lk_ok;
    logic [WAYS-1:0] lk_v, lk_d;
    logic [WAYS-1:0][TAGW-1:0] lk_t;
    logic [WAYS-1:0][511:0] lk_line;
    logic [WB-1:0] lk_repl;
  } in_t;

  // ---------------- stage chain: new state + table op + outputs ----------------
  typedef struct packed {
    st_t n;
    logic wd, wm, wv, wr;            // table write enables (data, meta, valid, repl)
    logic [SB-1:0] tset;
    logic [WB-1:0] tway;
    line_t tdata;
    logic [TAGW-1:0] ttag;
    logic tdirty;
    logic [WB-1:0] trepl;
    logic trd;                       // table read request (all four tables)
    logic [SB-1:0] trd_set;
    logic [NR-1:0] rd_rdy;           // ext_out.upstream.read_req[].ready
    logic [NW-1:0] wr_rdy;           // ext_out.upstream.write_req[].ready
    logic mrd_v;
    addr_t mrd_addr;
    logic [7:0] mrd_size;
    logic [3:0] mrd_id;
    logic mwr_v;
    addr_t mwr_addr;
    line_t mwr_data;
    logic bad;                       // a path the analysis proved unreachable was taken (assertion in the top)
  } ch_t;

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
    return (WB'(w) == WB'(WAYS - 1)) ? '0 : w + WB'(1);
  endfunction

  // merge_write_into_line: bytes of `data` selected by `strb` are placed at byte offset addr[5:0] of `base`
  function automatic line_t merge_line(input line_t base, input addr_t a, input line_t data, input logic [63:0] strb,
                                       input logic [7:0] size);
    line_t out;
    logic [6:0] limit;
    out = base;
    limit = 7'(64) - {1'b0, a[5:0]};
    if ({1'b0, size} + 9'd1 < {2'b0, limit}) limit = size[6:0] + 7'd1;
    for (int b = 0; b < 64; b++) begin
      if (7'(b) < limit && strb[b]) out[(32'(a[5:0]) + b) * 8 +: 8] = data[b * 8 +: 8];
    end
    return out;
  endfunction

  // extract_line_response: words start at the word offset of the address
  function automatic line_t resp_of(input addr_t a, input line_t line);
    return line >> {a[5:2], 5'b0};
  endfunction

  function automatic logic is_full_write(input addr_t a, input logic [63:0] strb, input logic [7:0] size);
    return a[5:0] == 6'd0 && size == 8'd63 && (&strb);
  endfunction
  // all-zero constants of the wide vectors (zero replication above Verilator's default limit is intended)
  /* verilator lint_off WIDTHCONCAT */
  /* verilator lint_off UNUSEDPARAM */
  localparam st_t ST_ZERO = '0;
  localparam in_t IN_ZERO = '0;
  localparam ch_t CH_ZERO = '0;
  /* verilator lint_on UNUSEDPARAM */
  /* verilator lint_on WIDTHCONCAT */
endpackage
/* verilator lint_on UNUSEDSIGNAL */

`default_nettype wire
