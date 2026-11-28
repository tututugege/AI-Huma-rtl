// Ref: front-end/BPU/BPU_pipe.h & BpuSc.h  (Single-Set 2-Ahead BPU: S0->S1->S2, ex_fh[3][6], HR_BITS=256)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */
package bpu_stage_pkg;
  import ttg_cfg_pkg::*;
  import bpu_pkg::*;

  localparam int UB_SLOT_W = $clog2(FETCH_WIDTH);
  localparam int HSYM_W    = 3;
  localparam int HR_BITS   = 256;
  localparam int HR_PTR_W  = 8;
  localparam int PQ_DEPTH  = 32;
  localparam int NITT      = 4;
  localparam int ITT_EX_MAP [NITT] = '{1, 2, 3, 5};
  localparam int EPOCH_W   = 8;

  // ---- Unified 6-table geometric history engine (shared by 2-Way 2-Ahead ExBlockTage & 4-Table ITT) ----
  localparam int EX_TN   = 6;
  localparam int EX_FH_K = 3;
  localparam int EX_FH_W = 12;

  // ---- Deep-Macro Multi-Bank 1RW geometry & 38-bit Sv39 VA target compression ----
  localparam int BPU_FTB1_BANKS    = 2;  // 2-Bank 1RW (512-deep x 860b -> 24 x 512x72 macros)
  localparam int BPU_AH_TAGE_BANKS = 4;  // 4-Bank 1RW (512-deep x 128b -> 48 x 512x72 macros across 6 tables)
  localparam int BPU_ITT_BANKS     = 2;  // 2-Bank 1RW (256-deep x 52b  ->  8 x 256x64 macros across 4 tables)
  localparam int BPU_WRB_N         = 8;  // 8-entry FF WRBypass CAM+Mem
  localparam int FTB_VA_BITS       = 38; // stores pc[38:1]; sign-extended bit 38 to [63:39], bit 0 = 0

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic s2_bank_of_w(input logic [31:0] w);
    return 1'(w ^ (w >> 10));
  endfunction

  function automatic logic s2_bank_of_pc(input logic [XLEN_BITS-1:0] pc);
    return s2_bank_of_w(32'(pc >> SLOT_SHIFT));
  endfunction

  function automatic logic [FTB_VA_BITS-1:0] sv39_pack(input logic [XLEN_BITS-1:0] pc);
    return pc[FTB_VA_BITS:1];
  endfunction

  function automatic logic [XLEN_BITS-1:0] sv39_unpack(input logic [FTB_VA_BITS-1:0] va);
    return {{(XLEN_BITS - FTB_VA_BITS - 1){va[FTB_VA_BITS-1]}}, va, 1'b0};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic int unsigned ex_ghr_len(input int i);
    case (i)
      0: return 5;
      1: return 11;
      2: return 22;
      3: return 44;
      4: return 89;
      default: return 178;
    endcase
  endfunction

  function automatic int unsigned ex_fh_len(input int k);
    case (k)
      0: return 12;
      1: return 11;
      default: return 10;
    endcase
  endfunction

  // Folded-history rotate left within len bits (bpu_hist_vec SYNTHESIS path and bpu_spec architectural push)
  function automatic logic [EX_FH_W-1:0] rotl_const_ex(input logic [EX_FH_W-1:0] x, input int unsigned a,
                                                       input int unsigned len);
    logic [EX_FH_W-1:0] msk;
    msk = EX_FH_W'((32'd1 << len) - 32'd1);
    return (a == 0) ? x : (((x << a) | (x >> (len - a))) & msk);
  endfunction

  // rotate by 3 * sn bits (sn symbols of 3 bits), sn = 0..8
  function automatic logic [EX_FH_W-1:0] rotl_sym_ex(input logic [EX_FH_W-1:0] x, input logic [3:0] sn,
                                                     input int unsigned len);
    case (sn)
      4'd1:    return rotl_const_ex(x,  3 % len, len);
      4'd2:    return rotl_const_ex(x,  6 % len, len);
      4'd3:    return rotl_const_ex(x,  9 % len, len);
      4'd4:    return rotl_const_ex(x, 12 % len, len);
      4'd5:    return rotl_const_ex(x, 15 % len, len);
      4'd6:    return rotl_const_ex(x, 18 % len, len);
      4'd7:    return rotl_const_ex(x, 21 % len, len);
      4'd8:    return rotl_const_ex(x, 24 % len, len);
      default: return x;
    endcase
  endfunction

  // ---- FTB set index / tag hash (shared by uFTB and FTB1; callers cut to their SET_W / tag width) ----
  function automatic logic [31:0] ftb_set_hash(input logic [XLEN_BITS-1:0] pc, input int unsigned set_w);
    logic [31:0] w;
    w = 32'(pc >> SLOT_SHIFT);
    return w ^ (w >> set_w);
  endfunction

  function automatic logic [31:0] ftb_tag_hash(input logic [XLEN_BITS-1:0] pc, input int unsigned set_w,
                                               input int unsigned tag_w);
    logic [31:0] w, mask;
    w    = 32'(pc >> SLOT_SHIFT);
    mask = (32'd1 << tag_w) - 32'd1;
    return (w >> set_w) & mask;
  endfunction

  // ---- Predecode false-branch clear: slot offset of clr_pc in the entry at clr_base ----
  // vok: clr_pc lies in the block (or is the carried slot just before it); off: slot offset to clear.
  typedef struct packed { logic vok; logic [3:0] off; } ftb_clr_pos_t;

  function automatic ftb_clr_pos_t ftb_clr_pos(input logic [XLEN_BITS-1:0] clr_pc,
                                               input logic [XLEN_BITS-1:0] clr_base);
    ftb_clr_pos_t r;
    logic         car;
    car   = (clr_pc + XLEN_BITS'(SLOT_BYTES) == clr_base);
    r.vok = car || (clr_pc >= clr_base);
    r.off = car ? 4'd0 : 4'((clr_pc - clr_base) >> SLOT_SHIFT);
    return r;
  endfunction

  // ---- Unified history ring + folded histories, RAS ----
  typedef logic [EX_FH_K-1:0][EX_TN-1:0][EX_FH_W-1:0] ex_fh_t;
  // k = 0 slice of ex_fh_t (the index fold): all a 2-Ahead key needs (make_ah_*_index reads only key_ex_fh[0])
  typedef logic [EX_TN-1:0][EX_FH_W-1:0] ex_fh0_t;

  typedef struct packed {
    logic [HR_BITS-1:0]  ring;
    logic [HR_PTR_W-1:0] head;
    ex_fh_t              ex_fh;
  } hist_t;

  typedef struct packed {
    logic [RAS_DEPTH-1:0][XLEN_BITS-1:0] st;
    logic [RAS_PTR_W-1:0]                ptr;
    logic [RAS_CNT_W-1:0]                cnt;
  } rasc_t;

  typedef struct packed {
    logic [HR_PTR_W-1:0] head;
    ex_fh_t              ex_fh;
  } hist_ck_t;

  typedef struct packed {
    logic [RASQ_W-1:0]    tosr;
    logic [RASQ_W-1:0]    tosw;
    logic [RAS_CNT_W-1:0] cnt;
    logic [XLEN_BITS-1:0] top;
  } ras_ck_t;

  typedef struct packed {
    hist_ck_t h;
    ras_ck_t  r;
  } ck_t;

  // ---- Block prediction summary shared by S0 / S1 / S2 ----
  typedef struct packed {
    logic                 hit;
    logic                 taken;
    logic [UB_SLOT_W-1:0] slot;
    logic [2:0]           ty;
    logic                 rvc;
    logic                 carried;
    logic [XLEN_BITS-1:0] next;
    logic [HSYM_W-1:0]    hbits;
    logic [1:0]           ras_op;
    logic [XLEN_BITS-1:0] ras_val;
  } pred_t;

  // ---- 2-Ahead resolved direction/ITT summary carried S0 -> S1 -> S2 ----
  typedef struct packed {
    logic [3:0] pcpn;
    logic       prov_dir;
    logic       alt_is_tagged;
    logic       alt_dir;
    logic       use_alt;
  } ah_slot_tage_t;

  typedef struct packed {
    logic                   valid;
    ah_slot_tage_t [3:0]    s;
    logic                   itt_hit;
    logic [FTB_VA_BITS-1:0] itt_tgt;
  } ah_dir_itt_t;

  // ---- Block registers of S1 / S2 stages (single-block 1-Taken) ----
  typedef struct packed {
    logic                 valid;
    logic                 sq;
    logic                 ah_v;
    logic                 ah_hit;
    logic [XLEN_BITS-1:0] ah_key_base;
    logic [XLEN_BITS-1:0] prev_base;
    ex_fh0_t              ah_key_ex_fh;
    logic [XLEN_BITS-1:0] base;
    pred_t                g;
    ck_t                  ck;
    ah_dir_itt_t          ah_dir_itt;
  } blk_t;

  // ---- Helpers (Same-Page Line-Straddle 2-Fetch: full 32B block, truncates only at 4KB page boundary) ----
  function automatic logic [XLEN_BITS-1:0] block_bnd(input logic [XLEN_BITS-1:0] base);
    logic [XLEN_BITS-1:0] plus;
    plus = base + XLEN_BITS'(FETCH_WIDTH * SLOT_BYTES);
    return (base[XLEN_BITS-1:12] != plus[XLEN_BITS-1:12]) ? {plus[XLEN_BITS-1:12], 12'd0} : plus;
  endfunction

  function automatic logic [HSYM_W-1:0] hsym_of(input logic [XLEN_BITS-1:0] pc, input logic [XLEN_BITS-1:0] tgt);
    logic [31:0]          v;
    logic [XLEN_BITS-1:0] w;
    logic [HSYM_W-1:0]    r;
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

  // ---- Unified history ring ----
  function automatic hist_t hist_restore(input hist_t h, input hist_ck_t c);
    hist_t n;
    n       = h;
    n.head  = c.head;
    n.ex_fh = c.ex_fh;
    return n;
  endfunction

  // ---- RAS ----
  typedef struct packed {
    logic [RASQ_W-1:0]    tosr;
    logic [RASQ_W-1:0]    tosw;
    logic [RAS_CNT_W-1:0] cnt;
  } rptr_t;

  typedef struct packed {
    logic                       arch;
    logic [2:0]                 w;
    logic [2:0][RASQ_W-1:0]     idx;
    logic [2:0][XLEN_BITS-1:0]  val;
    logic [2:0][RASQ_W-1:0]     nos;
  } rov_t;

  typedef struct packed { rptr_t p; rov_t o; } rst_t;

endpackage
/* verilator lint_on UNUSEDPARAM */

`default_nettype wire
