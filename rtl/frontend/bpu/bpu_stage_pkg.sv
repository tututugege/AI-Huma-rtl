// Ref: front-end/BPU/BPU_pipe.h  (types and pure functions of the pipelined block-FTB predictor)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */
// Shared stage types and history/RAS functions for the block-based 1-ahead FTB BPU (EXP-050).
package bpu_stage_pkg;
  import ttg_cfg_pkg::*;
  import bpu_pkg::*;

  localparam int UB_SLOT_W = $clog2(FETCH_WIDTH);
  localparam int HSYM_W    = 3;
  localparam int HR_BITS   = 256;
  localparam int HR_PTR_W  = 8;
  localparam int PQ_DEPTH  = 32;
  localparam int NITT      = 3;
  localparam int ITT_TBL [NITT] = '{1, 2, 3};
  localparam int EPOCH_W   = 8;
  localparam int LANE_W    = $clog2(NLANE);

  // ---- history ring + folded histories, RAS ----
  typedef logic [FH_K-1:0][TN-1:0][FH_W-1:0] fh_t;
  typedef struct packed {
    logic [HR_BITS-1:0]  ring;
    logic [HR_PTR_W-1:0] head;
    fh_t                 fh;
  } hist_t;
  typedef struct packed {
    logic [RAS_DEPTH-1:0][XLEN_BITS-1:0] st;
    logic [RAS_PTR_W-1:0]                ptr;
    logic [RAS_CNT_W-1:0]                cnt;
  } rasc_t;
  typedef struct packed { logic [HR_PTR_W-1:0] head; fh_t fh; } hist_ck_t;
  typedef struct packed {
    logic [RASQ_W-1:0]    tosr;
    logic [RASQ_W-1:0]    tosw;
    logic [RAS_CNT_W-1:0] cnt;
    logic [XLEN_BITS-1:0] top;
  } ras_ck_t;
  localparam int RCK_W = 2 * RASQ_W + RAS_CNT_W;
  typedef struct packed { hist_ck_t h; ras_ck_t r; } ck_t;

  // ---- block prediction summary shared by S0 / S1 / S2 ----
  typedef struct packed {
    logic                 hit;
    logic                 taken;
    logic [UB_SLOT_W-1:0] slot;
    logic [2:0]           ty;
    logic                 rvc;
    logic [XLEN_BITS-1:0] next;
    logic [HSYM_W-1:0]    hbits;
    logic [1:0]           ras_op;
    logic [XLEN_BITS-1:0] ras_val;
  } pred_t;

  localparam int HHCK_W = HR_PTR_W + FH_K * TN * FH_W;
  localparam int HCK_W  = RCK_W + HHCK_W;

  // ---- block registers of S1 / S2 stages ----
  typedef struct packed {
    logic                 valid;
    logic                 ah_v;
    logic                 ah_hit;
    logic [XLEN_BITS-1:0] ah_key_base;
    fh_t                  ah_key_fh;
    logic [XLEN_BITS-1:0] base;
    pred_t                g;
    ck_t                  ck;
  } blk_t;

  // ---- helpers ----
  function automatic logic [XLEN_BITS-1:0] block_bnd(input logic [XLEN_BITS-1:0] base);
    logic [XLEN_BITS-1:0] plus;
    plus = base + XLEN_BITS'(FETCH_WIDTH * SLOT_BYTES);
    return ((base & ~XLEN_BITS'(ICACHE_LINE_SIZE - 1)) != (plus & ~XLEN_BITS'(ICACHE_LINE_SIZE - 1))) ?
           (plus & ~XLEN_BITS'(ICACHE_LINE_SIZE - 1)) : plus;
  endfunction

  function automatic logic [HSYM_W-1:0] hsym_of(input logic [XLEN_BITS-1:0] pc, input logic [XLEN_BITS-1:0] tgt);
    logic [31:0] v;
    logic [XLEN_BITS-1:0] w;
    logic [HSYM_W-1:0] r;
    w = pc >> SLOT_SHIFT;
    v = 32'(w ^ (tgt >> SLOT_SHIFT) ^ (w >> 7));
    r = '0;
    for (int i = 0; i < 32; i += HSYM_W) r = r ^ HSYM_W'(v >> i);
    return r;
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic pred_differs(input pred_t a, input pred_t b);
    return (a.next != b.next) || (a.taken != b.taken) || (a.hbits != b.hbits) || (a.ras_op != b.ras_op) ||
           (a.ras_op == 2'd1 && a.ras_val != b.ras_val);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- history ring ----
  function automatic hist_t hist_push(input hist_t h, input logic dir);
    hist_t n;
    logic [FH_W-1:0] v;
    logic [FH_W-1:0] msk;
    logic            hi;
    logic            old_bit;
    n = h;
    for (int k = 0; k < FH_K; k++) begin
      for (int i = 0; i < TN; i++) begin
        msk     = FH_W'((32'd1 << fh_len(k, i)) - 32'd1);
        v       = h.fh[k][i];
        hi      = v[fh_len(k, i) - 1];
        old_bit = h.ring[HR_PTR_W'(h.head - HR_PTR_W'(ghr_len(i)))];
        v       = ((v << 1) & msk) | FH_W'(dir ^ hi);
        v       = v ^ (FH_W'(old_bit) << (ghr_len(i) % fh_len(k, i)));
        n.fh[k][i] = v;
      end
    end
    n.ring[h.head] = dir;
    n.head         = h.head + HR_PTR_W'(1);
    return n;
  endfunction

  function automatic hist_t hist_push_sym(input hist_t h, input logic en, input logic [HSYM_W-1:0] bits);
    hist_t n;
    n = h;
    if (en) for (int i = 0; i < HSYM_W; i++) n = hist_push(n, bits[i]);
    return n;
  endfunction

  function automatic hist_t hist_restore(input hist_t h, input hist_ck_t c);
    hist_t n;
    n      = h;
    n.head = c.head;
    n.fh   = c.fh;
    return n;
  endfunction

  // ---- RAS ----
  function automatic rasc_t ras_push(input rasc_t r, input logic [XLEN_BITS-1:0] v);
    rasc_t n;
    n = r;
    n.ptr = r.ptr + RAS_PTR_W'(1);
    n.st[n.ptr] = v;
    if (r.cnt < RAS_CNT_W'(RAS_DEPTH)) n.cnt = r.cnt + RAS_CNT_W'(1);
    return n;
  endfunction

  function automatic rasc_t ras_pop(input rasc_t r);
    rasc_t n;
    n = r;
    if (r.cnt != '0) begin
      n.ptr = r.ptr - RAS_PTR_W'(1);
      n.cnt = r.cnt - RAS_CNT_W'(1);
    end
    return n;
  endfunction

  typedef struct packed {
    logic [RASQ_W-1:0]    tosr;
    logic [RASQ_W-1:0]    tosw;
    logic [RAS_CNT_W-1:0] cnt;
  } rptr_t;
  typedef struct packed {
    logic                 arch;
    logic                 w1;
    logic [RASQ_W-1:0]    i1;
    logic [XLEN_BITS-1:0] v1;
    logic [RASQ_W-1:0]    n1;
    logic                 w2;
    logic [RASQ_W-1:0]    i2;
    logic [XLEN_BITS-1:0] v2;
    logic [RASQ_W-1:0]    n2;
  } rov_t;
  typedef struct packed { rptr_t p; rov_t o; } rst_t;

endpackage
/* verilator lint_on UNUSEDPARAM */

`default_nettype wire
