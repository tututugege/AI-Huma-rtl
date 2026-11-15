// Ref: front-end/BPU/BPU_pipe.h  (types and pure functions of the pipelined predictor)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */
// Types and functions of the pipelined BPU (BPU_PIPE=3, taken-path history, ITT).  Everything here is pure hardware:
// packed state types, history / RAS push functions that the top level chains, and the index functions of the two
// small tables (uBTB at S0, L1 at S1).
package bpu_stage_pkg;
  import ttg_cfg_pkg::*;
  import bpu_pkg::*;
  import bpu_btb_pkg::btb_ent_t;

  // ---- configuration of the implemented design (trace-model: BPU_PIPE=3 BPO_HIST=1 BPO_HSYM=3 BPO_BANKBLK=4 ...) ----
  localparam int UB_WAYS   = 4;                // S0 table (uBTB): 128 entries, 4 ways
  localparam int UB_SET_W  = 5;
  localparam int UB_SETS   = 1 << UB_SET_W;
  localparam int L1_WAYS   = 2;                // S1 table (L1): 512 entries, 2 ways
  localparam int L1_SET_W  = 8;
  localparam int L1_SETS   = 1 << L1_SET_W;
  localparam int UB_TAG_W  = 10;
  localparam int UB_TGT_W  = XLEN_BITS - SLOT_SHIFT;    // target slot address
  localparam int UB_WA_W   = 32 - SLOT_SHIFT;  // block start slot address (set / tag hash: low bits only)
  localparam int UB_SLOT_W = $clog2(FETCH_WIDTH);   // slot offset of the taken branch in the block
  localparam int HSYM_W    = 3;                // history bits pushed by a taken branch (BPO_HSYM)
  localparam int HR_BITS   = 256;              // circular history buffer
  localparam int HR_PTR_W  = 8;
  localparam int NBB       = 4;                // block banks of the update path (BPO_BANKBLK)
  localparam int UQ_DEPTH  = 8;                // update queue
  localparam int UQ_PORTS  = 2;                // leader writes per cycle
  localparam int TQ_DEPTH  = 4;                // uBTB / L1 train queue
  localparam int PQ_DEPTH  = 32;               // PDCKPT records (blocks between the end of S2 and the predecode check)
  localparam int NITT      = 3;                // ITT tables per bank (trace-model CFG_ITT_H = "1,2,3")
  localparam int ITT_IDX_W = 6;                // ITT: 64 entries per table and bank (CFG_ITT_SIZE)
  localparam int ITT_TBL [NITT] = '{1, 2, 3};  // TAGE tables (history 13 / 32 / 119) whose index / tag the ITT reuses
  localparam int EPOCH_W   = 8;
  localparam int LANE_W    = $clog2(NLANE);    // log2(NLANE)

  // ---- history ring + folded histories, RAS ----
  typedef logic [FH_K-1:0][TN-1:0][FH_W-1:0] fh_t;
  typedef struct packed {
    logic [HR_BITS-1:0]  ring;
    logic [HR_PTR_W-1:0] head;
    fh_t                 fh;
  } hist_t;
  typedef struct packed {
    logic [RAS_DEPTH-1:0][XLEN_BITS-1:0] st;
    logic [RAS_PTR_W-1:0]       ptr;
    logic [RAS_CNT_W-1:0]       cnt;
  } rasc_t;   // the committed RAS: a circular stack
  // checkpoints (state before a block)
  typedef struct packed { logic [HR_PTR_W-1:0] head; fh_t fh; } hist_ck_t;
  typedef struct packed {
    logic [RASQ_W-1:0] tosr; logic [RASQ_W-1:0] tosw; logic [RAS_CNT_W-1:0] cnt; logic [XLEN_BITS-1:0] top;
  } ras_ck_t;
  localparam int RCK_W = 2 * RASQ_W + RAS_CNT_W;   // the pointer part of a RAS checkpoint (what the back end carries)
  typedef struct packed { hist_ck_t h; ras_ck_t r; } ck_t;

  // ---- uBTB / L1 entry (taken-path history: the nd fields of the C++ entry are dead and not stored) ----
  typedef struct packed {
    logic                 v;
    logic [UB_TAG_W-1:0]  tag;
    logic [2:0]           ty;
    logic [UB_SLOT_W-1:0] slot;
    logic [1:0]           ctr;
    logic [UB_TGT_W-1:0]  tgt;
    logic                 rvc;      // the taken branch is a 16-bit instruction
  } ub_ent_t;

  // ---- what a block pushes / jumps to: the S0 / S1 guess and the final (S2) prediction share one type ----
  typedef struct packed {
    logic                 hit;      // tag match (S0 guess only)
    logic                 taken;
    logic [UB_SLOT_W-1:0] slot;
    logic [2:0]           ty;
    logic                 rvc;      // the taken branch is a 16-bit instruction
    logic [XLEN_BITS-1:0]          next;
    logic [HSYM_W-1:0]    hbits;    // taken: HSYM history bits pushed
    logic [1:0]           ras_op;   // 0 none, 1 push, 2 pop
    logic [XLEN_BITS-1:0]          ras_val;
  } pred_t;

  // ---- update queue entry (BPU_pipe.h UpdEnt) ----
  typedef struct packed {
    logic [XLEN_BITS-1:0]                 pc;
    logic                        dir;
    logic                        pred;
    logic                        alt;
    logic [2:0]                  ty;
    logic [XLEN_BITS-1:0]                 tgt;
    logic [PCPN_W-1:0]           pcpn;
    logic [TN-1:0][T_TAG_W-1:0]  tag;
    logic [TN-1:0][T_IDX_W-1:0]  idx;
    logic                        rvc;     // the committed instruction is 16 bits (type predictor, RAS push value)
  } upd_ent_t;

  // ---- train event of the uBTB / L1 (kind 0 taken, 1 fall-through end, 2 predicted-taken-not-taken) ----
  typedef struct packed {
    logic [1:0]          kind;
    logic [31:SLOT_SHIFT] start;   // block start slot address (set / tag hash: low bits only)
    logic [UB_SLOT_W-1:0] slot;
    logic [2:0]          ty;
    logic [UB_TGT_W-1:0] tgt;
    logic                rvc;
  } ub_ev_t;


  // ---- main predictor arrays, S1 read data (registered into the S2 stage) ----
  typedef struct packed {
    logic [1:0]                  base;
    logic [TN-1:0][T_TAG_W-1:0]  tag;
    logic [TN-1:0][2:0]          cnt;
    logic [TN-1:0][1:0]          useful;
  } tg_raw_t;
  // TAGE index record of one bank (computed at S0 from the speculative folded histories)
  typedef struct packed {
    logic [T_BASE_W-1:0]         base;
    logic [TN-1:0][T_IDX_W-1:0]  idx;
    logic [TN-1:0][T_TAG_W-1:0]  tag;
  } tg_ix_t;
  // ITT entry (indirect target table k is indexed like TAGE table ITT_TBL[k])
  typedef struct packed {
    logic        valid;
    logic [T_TAG_W-1:0] tag;
    logic [1:0]  conf;
    logic        useful;
    logic [XLEN_BITS-1:0] target;
  } itt_ent_t;

  // Ref: Tage::index.  idx = (fh0 ^ w) & mask, tag = (fh1 ^ fh2 ^ w) & mask, w = bank pc >> SLOT_SHIFT
  function automatic tg_ix_t tage_index(input logic [T_BASE_W-1:0] pc_idx, input fh_t fh);
    tg_ix_t x;
    x.base = pc_idx;
    for (int i = 0; i < TN; i++) begin
      x.idx[i] = fh[0][i][T_IDX_W-1:0] ^ pc_idx;
      x.tag[i] = fh[1][i][T_TAG_W-1:0] ^ fh[2][i][T_TAG_W-1:0] ^ pc_idx[T_TAG_W-1:0];
    end
    return x;
  endfunction


  localparam int HHCK_W = HR_PTR_W + FH_K * TN * FH_W;   // bits of a history checkpoint (head + folded histories)
  localparam int HCK_W = RCK_W + HHCK_W;                 // carried by the back end: RAS pointers above the history

  // ---- block registers of the S1 / S2 stages ----
  typedef struct packed {
    logic        valid;
    logic [XLEN_BITS-1:0] base;
    pred_t       g;       // S0 guess (replaced by the L1 guess on an S1 override)
    ck_t         ck;      // history / RAS state before the block
  } blk_t;
  typedef tg_ix_t [NBANK-1:0] tix_all_t;
  // S1 read data of one bank, registered into S2
  typedef struct packed {
    tp_entry_t [TP_WAYS-1:0] ty;
    tg_raw_t                 tg;
    btb_ent_t [B_WAYS-1:0]   btb;
    itt_ent_t [NITT-1:0]     itt;
  } bank_raw_t;
  typedef bank_raw_t [NBANK-1:0] raw_all_t;

  // ---- helpers ----
  function automatic logic [XLEN_BITS-1:0] block_bnd(input logic [XLEN_BITS-1:0] base);
    logic [XLEN_BITS-1:0] plus;
    plus = base + XLEN_BITS'(FETCH_WIDTH * SLOT_BYTES);
    return ((base & ~XLEN_BITS'(ICACHE_LINE_SIZE - 1)) != (plus & ~XLEN_BITS'(ICACHE_LINE_SIZE - 1))) ?
           (plus & ~XLEN_BITS'(ICACHE_LINE_SIZE - 1)) : plus;
  endfunction

  // taken-path history symbol: XOR-fold of (pc>>2 ^ tgt>>2 ^ pc>>9) into HSYM_W bits (model hist_sym)
  function automatic logic [HSYM_W-1:0] hsym_of(input logic [XLEN_BITS-1:0] pc, input logic [XLEN_BITS-1:0] tgt);
    logic [31:0] v;
    logic [XLEN_BITS-1:0] w;
    logic [HSYM_W-1:0] r;
    w = pc >> SLOT_SHIFT;   // the model shifts the full-width slot address (sign-extended on rv64) and truncates the XOR to 32 bits
    v = 32'(w ^ (tgt >> SLOT_SHIFT) ^ (w >> 7));
    r = '0;
    for (int i = 0; i < 32; i += HSYM_W) r = r ^ HSYM_W'(v >> i);
    return r;
  endfunction

  // uBTB / L1 set index and tag of the block start word address w: set = (w ^ w>>k) & (S-1), tag = (w>>k) & mask
  function automatic logic [UB_SET_W-1:0] ub_set_of(input logic [UB_WA_W-1:0] w);
    return UB_SET_W'(w ^ (w >> UB_SET_W));
  endfunction
  function automatic logic [UB_TAG_W-1:0] ub_tag_of(input logic [UB_WA_W-1:0] w);
    return UB_TAG_W'(w >> UB_SET_W);
  endfunction
  function automatic logic [L1_SET_W-1:0] l1_set_of(input logic [UB_WA_W-1:0] w);
    return L1_SET_W'(w ^ (w >> L1_SET_W));
  endfunction
  function automatic logic [UB_TAG_W-1:0] l1_tag_of(input logic [UB_WA_W-1:0] w);
    return UB_TAG_W'(w >> L1_SET_W);
  endfunction


  // the S0 / S1 guess and the final prediction of a block disagree: next pc, history bits, RAS operation / value
  /* verilator lint_off UNUSEDSIGNAL */
  // (hit, slot and type of the guesses are not compared: local waiver, the fields are used by other consumers)
  function automatic logic pred_differs(input pred_t a, input pred_t b);
    return (a.next != b.next) || (a.taken != b.taken) || (a.hbits != b.hbits) || (a.ras_op != b.ras_op) ||
           (a.ras_op == 2'd1 && a.ras_val != b.ras_val);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- history ring ----
  // Ref: HistRing::push.  One bit: the 12 folded histories (index fold, two tag folds of the 4 tables) and the ring.
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

  // push the HSYM_W bits of a taken branch (bit 0 first)
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
  // committed (circular)
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

  // speculative RAS: an append-only queue (state in bpu_spec): a push writes slot tosw (nos = the entry below),
  // a pop follows the nos link of tosr, so a checkpoint of the pointers (tosr, tosw, depth) is exact
  typedef struct packed {
    logic [RASQ_W-1:0]    tosr;
    logic [RASQ_W-1:0]    tosw;
    logic [RAS_CNT_W-1:0] cnt;      // depth (saturates at RAS_DEPTH)
  } rptr_t;
  // what a command changes in the queue arrays: rebuilt from the committed stack, and up to two slot writes
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

`default_nettype wire
