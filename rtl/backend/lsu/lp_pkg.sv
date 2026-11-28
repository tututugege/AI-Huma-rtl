// Ref: back-end/Lsu/RealLsuPipe.cpp  lp:: (RealLsuPipe.h types, stq_cam / stlf_confirm, MemUtils.h helpers)
`default_nettype none
package lp_pkg;
  import ttg_cfg_pkg::*;

  /* verilator lint_off UNUSEDPARAM */  // package constants are used by other files
  localparam int NLD  = LSU_LDU_COUNT;      // load pipelines (L1/L2) = DCache load ports = load write-back ports
  localparam int NWBP = 2;                  // V2 WBP load write-back wake/pick bandwidth (64 -> 2)
  localparam int NWK  = 3 * NLD + NWBP;     // wakeup channels: [0..NLD-1] L1 spec, [NLD..2*NLD-1] L3, [2*NLD..3*NLD-1] L2b/L2a, [3*NLD..NWK-1] WBP
  localparam int NST  = LSU_STA_COUNT;      // STA ports (AGU + DTLB)
  localparam int NSD  = LSU_SDU_COUNT;      // STD ports
  localparam int MDPW = LSU_MDP_BITS;       // wait-table index width (PC hash)
  localparam int NRP  = 4;                  // load replay registers (model CFG_LSU_PIPE_RP)
  localparam int NDR  = (NST < 2) ? NST : 2;  // committed-store drain ports (model CFG_LSU_PIPE_DRAIN)
  localparam int NRET = 4;                  // STQ head entries freed per cycle
  localparam int NDIS = MAX_LDQ_DISPATCH_WIDTH;
  localparam int NCM  = COMMIT_WIDTH;
  localparam int LQ   = LDQ_SIZE;
  localparam int SQ   = STQ_SIZE;
  localparam int LQW  = LDQ_IDX_WIDTH;
  localparam int SQW  = STQ_IDX_WIDTH;
  localparam int CNTW = SQW + 1;            // STQ counters
  localparam int EPW  = 4;                  // per-LDQ-entry request epoch
  localparam int RWW  = LSU_REPLAY_WAIT_CYCLES_WIDTH;   // replay countdown (memcpu_pkg::replay_wait)
  localparam int ROBW = ROB_IDX_WIDTH;
  localparam int PRFW = PRF_IDX_WIDTH;
  localparam int LINEW = 32 - DCACHE_OFFSET_BITS;
  /* verilator lint_on UNUSEDPARAM */

  // LDQ entry state
  typedef enum logic [3:0] {
    LS_EMPTY = 4'd0,
    LS_ALLOC,     // allocated at dispatch, waiting for the AGU request
    LS_PIPE,      // inside L1 / L2 (or in a replay register)
    LS_DCW,       // DCache request sent, waiting for the response
    LS_RPW,       // parked: cause in rcause, wake condition in rwait / blk
    LS_RDY,       // ready for a replay port
    LS_WBP,       // result ready, waiting for a load write-back port
    LS_MMW,       // MMIO load waiting to be the oldest instruction
    LS_MMR,       // MMIO load on the bus
    LS_WB3,       // decided at L2, in the L3 register, written back next cycle
    LS_SPD        // memory speculation: written back (consumers woken), ROB completion pending
  } lp_ld_st_t;

  typedef enum logic [2:0] {
    RC_TLB = 3'd0, RC_ADDR, RC_HOLD, RC_DATA, RC_DC
  } lp_rc_t;

  typedef enum logic [2:0] {
    L2_NONE = 3'd0, L2_WBD, L2_PARK, L2_MMW, L2_DCW, L2_RDY, L2_WBP
  } lp_l2act_t;

  // DTLB outcome stored in PL12.tlb.  Its own encoding (hit = 0), NOT the DTLB response code
  // (tlb_mmu_pkg::RES_MISS / RES_HIT / RES_FAULT = 0 / 1 / 2): lp_l1 builds it from booleans, the two never mix.
  // Replay type: memcpu_pkg::REPLAY_*; AMO funct7[6:2]: dis_pkg::AMO_LR / AMO_SC.
  /* verilator lint_off UNUSEDPARAM */
  localparam logic [1:0] PL12_TLB_HIT = 2'd0, PL12_TLB_MISS = 2'd1, PL12_TLB_PF = 2'd2;
  /* verilator lint_on UNUSEDPARAM */

  // decision of one L2 port (what happens to the load of PL12[p])
  typedef struct packed {
    lp_l2act_t       act;
    lp_rc_t          cause;
    logic [SQW-1:0]  blk;
    logic [RWW-1:0]  wait_c;
  } lp_l2dec_t;

  // outcome of the wake-up of a parked load (RC_ADDR / RC_HOLD / RC_DATA), see lp_wk
  typedef struct packed {
    logic            rdy;          // -> RDY
    logic            wbp;          // -> WBP (forwarded result in res)
    logic            rc_set;       // park cause changes to rc
    logic [2:0]      rc;
    logic            wt_set;       // wait field (store byte offset for RC_DATA) changes to wt
    logic [RWW-1:0]  wt;
    logic            res_set;
    logic [XLEN_BITS-1:0] res;
  } lp_wk_t;

  // L1/L2 pipeline register (one per load port)
  typedef struct packed {
    logic            v;
    logic [LQW-1:0]  ldq;
    logic [EPW-1:0]  epoch;
    logic [1:0]      tlb;
    logic            mmio;
    logic            dcblk;
    logic            bloom;        // DCache launch suppressed by 256-bit STQ word bloom filter (first pass only)
    logic [31:0]     paddr;        // RTL: carried so that L2 does not read the LDQ
    logic [28:0]     paddr_p1;     // precomputed paddr[31:3] + 1 (eliminates 29b adders in lp_cam / lp_l2)
    logic [28:0]     paddr_m1;     // precomputed paddr[31:3] - 1
    logic [11:0]     voff;
    logic [2:0]      func3;
    logic [SQW-1:0]  snap_idx;     // carried for L2a STQ CAM
    logic            snap_flag;
    logic            spec_ok;
    logic            replay;
    logic            spec_w;
    logic [PRFW-1:0] spec_preg;
    logic [7:0]      pc8;
  } lp_pl12_t;

  // L2a -> L2b pipeline register (STLF-only: decouples 64-entry STQ CAM from stlf_confirm + lp_wk)
  typedef struct packed {
    logic            v;
    logic [LQW-1:0]  ldq;
    logic [EPW-1:0]  epoch;
    logic [SQW-1:0]  cand;
    logic [31:0]     paddr;
    logic [28:0]     paddr_p1;
    logic [28:0]     paddr_m1;
    logic [11:0]     voff;
    logic [2:0]      func3;
  } lp_pl2b_t;

  // one L1 slot of this cycle
  typedef struct packed {
    logic            v;
    logic            replay;
    logic            need_tlb;
    logic [LQW-1:0]  ldq;
    logic [XLEN_BITS-1:0] vaddr;
    logic [2:0]      func3;
    logic [SQW-1:0]  snap_idx;
    logic            snap_flag;
    logic            pa_v;         // replay with a known physical address
    logic [31:0]     paddr_reg;
    logic            mmio_reg;
    logic            lrsc;         // LR (new load: from the AGU, replay: from the entry)
    logic [EPW-1:0]  epoch;        // pre-launch LDQ epoch (avoids 64:1 mux on epoch_nx)
    logic            second;       // memory speculation second pass (replay: from rp_f_q)
    logic            wait_b;       // memory speculation wait-table bit
    logic [PRFW-1:0] dest;
    logic [ROBW-1:0] rob_idx;
    logic            rob_flag;
    logic            no_l1_spec;
    logic [7:0]      pc8;
  } lp_l1in_t;

  // pre-registered immutable LDQ payload stored in each replay register (removes 64:1 LDQ mux from L1/CAM critical path)
  typedef struct packed {
    logic [XLEN_BITS-1:0] vaddr;
    logic [2:0]      func3;
    logic [SQW-1:0]  snap_idx;
    logic            snap_flag;
    logic            pa_v;
    logic [31:0]     paddr;
    logic            mmio;
    logic            lrsc;
    logic [EPW-1:0]  epoch;
    logic            second;
    logic            wait_b;
    logic [PRFW-1:0] dest_preg;
    logic [ROBW-1:0] rob_idx;
    logic            rob_flag;
    logic            no_l1_spec;
  } lp_rp_ent_t;

  // DTLB result of one L1 slot
  typedef struct packed {
    logic            hit;
    logic            pf;
    logic [31:0]     paddr;
    logic            mmio;
  } lp_tl_t;

  typedef struct packed {   // load AGU arrival (port i)
    logic            v;
    logic            occ;           // the AGU holds a uop (killed by a flush / mispredict or not): the replay allocation looks at this
    logic [LQW-1:0]  ldq;
    logic [ROBW-1:0] rob_idx;
    logic            rob_flag;
    logic [XLEN_BITS-1:0] vaddr;
    logic [PRFW-1:0] dest;
    logic [2:0]      func3;
    logic [SQW-1:0]  snap_idx;
    logic            snap_flag;
    logic            lr;
  } lp_agu_ld_t;

  typedef struct packed {   // STA AGU arrival (port i)
    logic            v;
    logic            occ;           // (as lp_agu_ld_t)
    logic [SQW-1:0]  stq;
    logic [ROBW-1:0] rob_idx;
    logic            rob_flag;
    logic [XLEN_BITS-1:0] vaddr;
    logic [PRFW-1:0] dest;
    logic [2:0]      func3;
    logic            sc;
  } lp_agu_st_t;

  typedef struct packed {   // STD write
    logic            v;
    logic [SQW-1:0]  stq;
    logic [ROBW-1:0] rob_idx;
    logic            rob_flag;
    logic [XLEN_BITS-1:0] data;
  } lp_std_t;

  // dispatch allocation (one slot)
  typedef struct packed {
    logic            v;
    logic [LQW-1:0]  ldq;
    logic [ROBW-1:0] rob_idx;
    logic            rob_flag;
    logic [MDPW-1:0] mdp;          // wait-table index of the load PC (memory speculation)
    logic [31:0]     pc;
    logic            wait_b;       // wait-table bit read at dispatch: this load does not pass unknown-address stores
  } lp_dis_ld_t;

  typedef struct packed {
    logic            v;
    logic [ROBW-1:0] rob_idx;
    logic            rob_flag;
    logic [2:0]      func3;
  } lp_dis_st_t;

  // STQ entry view broadcast with an STA event (values after this cycle's arrival / DTLB result / STD / SC verdict)
  typedef struct packed {
    logic            v;            // this slot carries an STA event
    logic [SQW-1:0]  stq;
    logic            va_v;
    logic [11:0]     voff;
    logic [2:0]      func3;
    logic            pa_v;
    logic [31:0]     paddr;
    logic [28:0]     paddr_p1;     // precomputed paddr[31:3] + 1 before sta_info_q FF (eliminates 192x 29b adders in lp_wk)
    logic [28:0]     paddr_m1;     // precomputed paddr[31:3] - 1 before sta_info_q FF
    logic            data_v;
    logic            hold_sc;      // lrsc && !sc_pass
    logic            suppress;
    logic [XLEN_BITS-1:0] data;
  } lp_sta_info_t;

  // STQ entry registers (read ports: CAM, L2 confirm, write-back, drain)
  typedef struct packed {
    logic            va_v, pa_v, data_v, pf, mmio, lrsc, sc_pass, suppress;
    logic            trp, wbp, wbd, cmt, iss, mmw, done;
    logic [XLEN_BITS-1:0] vaddr;
    logic [31:0]     paddr;
    logic [XLEN_BITS-1:0] data;
    logic [2:0]      func3;
    logic [PRFW-1:0] dest_preg;
    logic [ROBW-1:0] rob_idx;
    logic            rob_flag;
    logic [1:0]      rtype;
    logic [RWW-1:0]  rwait;
  } lp_stq_t;

  // EXP-024 write buffer: entries of up to two stores of one cache line, and the store handed to the insertion
  localparam int NWB = 4;
  typedef struct packed {
    logic            v, st, mg, two;     // valid, sent to the DCache, mergeable, holds two stores
    logic [25:0]     line;
    logic [SQW-1:0]  m0, m1;             // STQ indices of the stores (first = leader)
    logic [31:0]     a0, a1;             // their physical address
    logic [XLEN_BITS-1:0] d0, d1;        // their data
    logic [1:0]      f0, f1;             // their size
  } wbe_t;
  typedef wbe_t [NWB-1:0]            wbs_t;   // all entries
  typedef logic [NWB-1:0][NWB-1:0]   ltm_t;   // age matrix
  typedef struct packed {
    logic            mmio, done, lrsc;
    logic [31:0]     paddr;
    logic [XLEN_BITS-1:0] data;
    logic [1:0]      f3;
  } wbi_t;

  // LDQ entry registers visible to the glue (write-back, MMIO, wake)
  typedef struct packed {
    logic [ROBW-1:0] rob_idx;
    logic            rob_flag;
    logic [PRFW-1:0] dest_preg;
    logic [2:0]      func3;
    logic [XLEN_BITS-1:0] vaddr;
    logic            pa_v;
    logic [31:0]     paddr;
    logic            mmio, pf, lrsc;
    logic [XLEN_BITS-1:0] result;
    logic [SQW-1:0]  snap_idx;
    logic            snap_flag;
    logic [2:0]      rcause;
    logic [SQW-1:0]  blk;
    logic [RWW-1:0]  rwait;
    logic [1:0]      rtype;
    logic [EPW-1:0]  epoch;
    logic            spec;         // passed an older store whose address was unknown at L1
    logic            vio;          // an overlapping older store address arrived later
    logic            second;       // second pass: completion write-back / re-execution after a violation
    logic            wait_b;       // predictor: does not pass unknown-address stores
    logic [MDPW-1:0] mdp;          // wait-table index
    logic [31:0]     pc;
    logic            no_l1_spec;   // parked on doomed polling replay (RC_TLB / MSHR miss): skip L1 spec wake until filled
  } lp_ldq_t;

  // ---- helpers ----
  // number of older stores of a load: distance (snapshot tag, head tag) on the 2N tag ring, clipped to the STQ count
  function automatic logic [CNTW-1:0] older_cnt(input logic snap_flag, input logic [SQW-1:0] snap_idx,
                                                input logic head_flag, input logic [SQW-1:0] head,
                                                input logic [CNTW-1:0] count);
    logic [SQW:0] d;
    d = {snap_flag, snap_idx} - {head_flag, head};
    return (CNTW'(d) > count) ? count : CNTW'(d);
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */  // func3[2] (sign) does not change the size
  function automatic logic [12:0] ld_width13(input logic [2:0] func3);   // access size in bytes (1, 2, 4, 8)
    case (func3[1:0])
      2'b00:   return 13'd1;
      2'b01:   return 13'd2;
      2'b10:   return 13'd4;
      default: return 13'd8;
    endcase
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // relation of load [lo, lo+lw) and store [so, so+sw) on W address bits (W=12 or 32, no wrap):
  //   0 = disjoint, 1 = store covers load, 2 = partial overlap.
  // Uses 8-byte block split + 3 parallel upper equality checks (zero W-bit carry chains on the compare).
  // The callers differ only in how the three upper-part relations are formed (eq0: upper parts equal, s_is_l1: the
  // store's upper part is the load's + 1, l_is_s1: the load's is the store's + 1; at most one holds); the byte-in-8
  // part (lo3 / so3 = address bits [2:0]) is shared here.
  /* verilator lint_off UNUSEDSIGNAL */  // func3[2] (sign) does not change the size
  function automatic logic rel_ovl(input logic eq0, input logic s_is_l1, input logic l_is_s1,
                                   input logic [2:0] lo3, input logic [2:0] lf, input logic [2:0] so3,
                                   input logic [2:0] sf);   // the ranges overlap (rel != 0)
    logic              c0, c1, cm;
    logic signed [5:0] dl, lw, sw;
    lw = $signed({2'b00, 4'(ld_width13(lf))});
    sw = $signed({2'b00, 4'(ld_width13(sf))});
    dl = $signed({3'b000, so3}) - $signed({3'b000, lo3});
    c0 = (dl > -sw) && (dl < lw);        // same 8-byte block
    c1 = (dl + 6'sd8 < lw);              // store block one higher: d = 8 + dl > 0
    cm = (dl - 6'sd8 > -sw);             // store block one lower: d = dl - 8 < 0
    return (eq0 && c0) || (s_is_l1 && c1) || (l_is_s1 && cm);
  endfunction

  function automatic logic [1:0] rel_tail(input logic eq0, input logic s_is_l1, input logic l_is_s1,
                                          input logic [2:0] lo3, input logic [2:0] lf, input logic [2:0] so3,
                                          input logic [2:0] sf);
    logic              cov0, covm, cov;
    logic signed [5:0] dl, lw, sw;
    lw   = $signed({2'b00, 4'(ld_width13(lf))});
    sw   = $signed({2'b00, 4'(ld_width13(sf))});
    dl   = $signed({3'b000, so3}) - $signed({3'b000, lo3});
    cov0 = (dl <= 6'sd0) && (dl + sw >= lw);
    covm = (dl - 6'sd8 + sw >= lw);
    cov  = (eq0 && cov0) || (l_is_s1 && covm);
    if (cov) return 2'd1;
    else if (!rel_ovl(eq0, s_is_l1, l_is_s1, lo3, lf, so3, sf)) return 2'd0;
    else return 2'd2;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic [1:0] rel12(input logic [11:0] lo, input logic [2:0] lf, input logic [11:0] so,
                                       input logic [2:0] sf);
    logic [8:0] ul, us, us_p, us_m;
    logic       eq0, s_is_l1, l_is_s1;
    ul      = lo[11:3];
    us      = so[11:3];
    us_p    = us + 9'd1;
    us_m    = us - 9'd1;
    eq0     = (ul == us);
    s_is_l1 = (ul == us_m) && (us != 9'd0);
    l_is_s1 = (ul == us_p) && !(&us);
    return rel_tail(eq0, s_is_l1, l_is_s1, lo[2:0], lf, so[2:0], sf);
  endfunction

  // STLF confirm result: 0 no address yet (stay), 1 replay, 2 hold, 3 data missing, 4 forward
  typedef enum logic [2:0] {CF_NOADDR = 3'd0, CF_REPLAY, CF_HOLD, CF_DATA, CF_FWD} lp_conf_t;

  // Zero-29b-adder rel32 variants using pre-registered paddr[31:3] +/- 1 from store side (lp_wk) or load side (lp_l2)
  function automatic logic [1:0] rel32_pre_s(input logic [31:0] lo, input logic [2:0] lf,
                                             input logic [31:0] so, input logic [28:0] so_p1, input logic [28:0] so_m1,
                                             input logic [2:0] sf);
    logic [28:0] ul, us;
    logic        eq0, s_is_l1, l_is_s1;
    ul      = lo[31:3];
    us      = so[31:3];
    eq0     = (ul == us);
    s_is_l1 = (ul == so_m1) && (us != 29'd0);
    l_is_s1 = (ul == so_p1) && !(&us);
    return rel_tail(eq0, s_is_l1, l_is_s1, lo[2:0], lf, so[2:0], sf);
  endfunction

  function automatic logic [1:0] rel32_pre_l(input logic [31:0] lo, input logic [28:0] lo_p1, input logic [28:0] lo_m1,
                                             input logic [2:0] lf, input logic [31:0] so, input logic [2:0] sf);
    logic [28:0] ul, us;
    logic        eq0, s_is_l1, l_is_s1;
    ul      = lo[31:3];
    us      = so[31:3];
    eq0     = (ul == us);
    s_is_l1 = (us == lo_p1) && !(&ul);
    l_is_s1 = (us == lo_m1) && (ul != 29'd0);
    return rel_tail(eq0, s_is_l1, l_is_s1, lo[2:0], lf, so[2:0], sf);
  endfunction

  function automatic lp_conf_t stlf_confirm_pre_s(input logic [11:0] lvoff, input logic [31:0] lpaddr, input logic [2:0] lf,
                                                  input logic alive, input logic s_suppress, input logic s_va_v,
                                                  input logic [11:0] s_voff, input logic s_pa_v, input logic [31:0] s_paddr,
                                                  input logic [28:0] s_paddr_p1, input logic [28:0] s_paddr_m1,
                                                  input logic [2:0] sf, input logic s_data_v, input logic s_hold_sc);
    logic [1:0] r;
    if (!alive || s_suppress) return CF_REPLAY;
    if (!s_va_v) return CF_NOADDR;
    if (!s_pa_v) begin
      if (rel12(lvoff, lf, s_voff, sf) == 2'd0) return CF_REPLAY;
      return CF_NOADDR;
    end
    r = rel32_pre_s(lpaddr, lf, s_paddr, s_paddr_p1, s_paddr_m1, sf);
    if (r == 2'd0) return CF_REPLAY;
    if (r == 2'd2) return CF_HOLD;
    if (!s_data_v) return CF_DATA;
    if (s_hold_sc) return CF_HOLD;
    return CF_FWD;
  endfunction

  function automatic lp_conf_t stlf_confirm_pre_l(input logic [11:0] lvoff, input logic [31:0] lpaddr,
                                                  input logic [28:0] lpaddr_p1, input logic [28:0] lpaddr_m1,
                                                  input logic [2:0] lf, input logic alive, input logic s_suppress,
                                                  input logic s_va_v, input logic [11:0] s_voff, input logic s_pa_v,
                                                  input logic [31:0] s_paddr, input logic [2:0] sf,
                                                  input logic s_data_v, input logic s_hold_sc);
    logic [1:0] r;
    if (!alive || s_suppress) return CF_REPLAY;
    if (!s_va_v) return CF_NOADDR;
    if (!s_pa_v) begin
      if (rel12(lvoff, lf, s_voff, sf) == 2'd0) return CF_REPLAY;
      return CF_NOADDR;
    end
    r = rel32_pre_l(lpaddr, lpaddr_p1, lpaddr_m1, lf, s_paddr, sf);
    if (r == 2'd0) return CF_REPLAY;
    if (r == 2'd2) return CF_HOLD;
    if (!s_data_v) return CF_DATA;
    if (s_hold_sc) return CF_HOLD;
    return CF_FWD;
  endfunction

  // ---- MemUtils.h ----
  // data word of the LSU: XLEN bits.  Offsets inside it are OW bits, a store strobe has SW + 1 bits (the last one:
  // the first byte of the next data word, for a half-word at the last offset: conflict checks only).
  localparam int XW = XLEN_BITS;
  localparam int HW = XLEN_BITS / 2;
  localparam int SW = XLEN_BITS / 8;
  localparam int OW = $clog2(SW);

  function automatic logic [XW-1:0] extract_data(input logic [XW-1:0] raw, input logic [OW-1:0] off,
                                                 input logic [2:0] f3);
    logic [XW-1:0] sh, r;
    sh = raw >> {off, 3'b000};
    case (f3[1:0])
      2'b00:   r = f3[2] ? XW'(sh[7:0]) : XW'($signed(sh[7:0]));
      2'b01:   r = f3[2] ? XW'(sh[15:0]) : XW'($signed(sh[15:0]));
      2'b10:   r = (XW == 32) ? sh : f3[2] ? XW'(sh[HW-1:0]) : XW'($signed(sh[HW-1:0]));   // rv64: lw sign / lwu zero
      default: r = sh;                                                    // ld (rv64)
    endcase
    return r;
  endfunction

  function automatic logic [SW:0] store_strb(input logic [OW-1:0] off, input logic [1:0] f3);
    case (f3)
      2'b00:   return (SW + 1)'(1) << off;
      2'b01:   return (SW + 1)'(3) << off;
      2'b10:   return (SW + 1)'(15) << (XW == 64 ? off : OW'(0));
      default: return (XW == 64) ? (SW + 1)'(8'hFF) : (SW + 1)'(0);   // sd (rv64)
    endcase
  endfunction

  function automatic logic [XW-1:0] align_store_data(input logic [XW-1:0] data, input logic [OW-1:0] off,
                                                     input logic [1:0] f3);
    logic [XW-1:0] b, h, w;
    b = XW'(data[7:0]) << {off, 3'b000};
    h = XW'(data[15:0]) << {off, 3'b000};
    w = XW'(data[HW-1:0]) << {off, 3'b000};
    case (f3)
      2'b00:   return b;
      2'b01:   return h;
      2'b10:   return (XW == 64) ? w : data;
      default: return (XW == 64) ? data : '0;
    endcase
  endfunction

  // MMIO = every address outside the cacheable windows (mmio_address_map.h simulator_is_mmio_addr)
  function automatic logic is_mmio_addr(input logic [31:0] a);
    logic cacheable;
    cacheable = (a >= 32'(SIM_CACHE_ADDR_1_MIN) && a < 32'(SIM_CACHE_ADDR_1_MAX)) ||
                (a >= 32'(SIM_CACHE_ADDR_2_MIN));   // DDR up to the end of the 32-bit space
    return !cacheable;
  endfunction

  // ring helpers: rotate a slot-ordered vector so that bit 0 is slot `sh` / and back
  function automatic logic [63:0] rotr64(input logic [63:0] v, input logic [5:0] sh);
    return 64'({v, v} >> sh);
  endfunction
  function automatic logic [63:0] rotl64(input logic [63:0] v, input logic [5:0] sh);
    return rotr64(v, 6'(-sh));
  endfunction

endpackage
`default_nettype wire
