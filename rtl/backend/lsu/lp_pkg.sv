// Ref: back-end/Lsu/RealLsuPipe.cpp  lp:: (RealLsuPipe.h types, stq_cam / stlf_confirm helpers)  -- staged LSU, docs
`default_nettype none
/* verilator lint_off UNUSEDPARAM */  // package constants are used by other files
/* verilator lint_off UNUSEDSIGNAL */  // helper functions ignore func3[2] (sign) and unused fields
package lp_pkg;
  import ttg_cfg_pkg::*;

  localparam int NLD  = LSU_LDU_COUNT;      // load pipelines (L1/L2) = DCache load ports = load write-back ports
  localparam int NST  = LSU_STA_COUNT;      // STA ports (AGU + DTLB)
  localparam int NSD  = LSU_SDU_COUNT;      // STD ports
  // critical-path cuts (docs/analysis/lsu-pipe.md section 9):
  //   bit0 B, bit1 R, bit2 D, bit3 F, bit4 G, bit5 E1, bit6 A, bit7 E2, bit8 C1, bit9 C2,
  //   bit10 E3, bit11 E4, bit12 E5, bit13 H, bit14 E6, bit15 E7, bit16 E8
  //   bit17 FM : (with F) the load whose MMIO response arrives in this cycle may still be written back in this cycle
  // Default 262143 = all. F kept (without F lp_core is 36 levels deeper, section 15); F alone cost h264ref 10 points
  // (serial MMIO loads each paid the extra cycle), FM removes it. Model: LSU_PIPE_CUT 127.
  localparam int LP_CUT = 262143;
  // L2 cuts (docs/analysis/lsu-pipe.md section 10), default 1907 = a+a2+F+M+S+W+P+T (model LSU_PIPE_L2=115), no d.
  // Bits 0..3 = model LSU_PIPE_L2; bits 8.. are RTL-only and equivalent (no cycle change):
  //   bit0 a   : L3 register, the direct completion decided at L2 is written back one cycle later (load-to-use +1)
  //   bit1 a2  : (needs bit0) wake-up of the consumers from the L3 register in the cycle of the write-back request
  //   bit3 d   : speculative wake-up at L2 from the L1 hit prediction, cancelled in the next cycle when wrong
  //   bit6 S   : at most one SC completion per cycle
  //   bit5 M   : an MMIO load that becomes MMW at L2 in this cycle is issued to the bus one cycle later
  //   bit4 F   : a load that gets MSHR_FULL in this very cycle is not woken by this cycle's fill (counter)
  //   bit8 W   : wake-up of a load parked at L2 evaluated at port level (4 units) instead of per LDQ entry after the
  //              L2 decision (equivalent: no cycle change)
  //   bit9 P   : log-depth find-first-set (lp_ffs) in the LSU instead of the carry-chain primitive (equivalent)
  //   bit11 R  : wake-up confirm range compare against thresholds from the load side (no adder after the store)
  //   bit10 T  : STQ mispredict cut: first hit searched without the count mask in front (equivalent)
  localparam int LP_L2 = 1907;
  // memory-dependence speculation (EXP-018, model CFG_LSU_MEMSPEC): loads pass older stores with an unknown address
  localparam bit MS   = LSU_MEMSPEC != 0;
  localparam int MDPW = LSU_MDP_BITS;       // wait-table index width (PC hash)
  localparam int NRP  = 4;                  // load replay registers (model CFG_LSU_PIPE_RP)
  localparam int NDR  = (NST < 2) ? NST : 2;  // committed-store drain ports (model CFG_LSU_PIPE_DRAIN)
  localparam int NDC  = 6;                  // committed-store drain candidates = CAMs (model CFG_LSU_PIPE_DCAND)
  localparam int NRET = 4;                  // STQ head entries freed per cycle
  localparam int NDIS = MAX_LDQ_DISPATCH_WIDTH;
  localparam int NCM  = COMMIT_WIDTH;
  localparam int LQ   = LDQ_SIZE;
  localparam int SQ   = STQ_SIZE;
  localparam int LQW  = LDQ_IDX_WIDTH;
  localparam int SQW  = STQ_IDX_WIDTH;
  localparam int CNTW = SQW + 1;            // STQ counters
  localparam int EPW  = 4;                  // per-LDQ-entry request epoch
  localparam int RWW  = 3;                  // replay countdown
  localparam int ROBW = ROB_IDX_WIDTH;
  localparam int PRFW = PRF_IDX_WIDTH;
  localparam int BRW  = BR_MASK_WIDTH;
  localparam int LINEW = 32 - DCACHE_OFFSET_BITS;
  localparam logic [RWW-1:0] RWAIT = RWW'(LSU_PEPLAY_WAIT_CYCLES);

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
    LS_WB3,       // LP_L2[0]: decided at L2, in the L3 register, written back next cycle
    LS_SPD        // memory speculation: written back (consumers woken), ROB completion pending
  } lp_ld_st_t;

  typedef enum logic [2:0] {
    RC_TLB = 3'd0, RC_ADDR, RC_HOLD, RC_DATA, RC_DC
  } lp_rc_t;

  typedef enum logic [2:0] {
    L2_NONE = 3'd0, L2_WBD, L2_PARK, L2_MMW, L2_DCW, L2_RDY
  } lp_l2act_t;

  localparam logic [1:0] RT_HIT = 2'd0, RT_CONFLICT = 2'd1, RT_MSHR_HIT = 2'd2, RT_MSHR_FULL = 2'd3;
  localparam logic [1:0] MMU_MISS = 2'd0, MMU_HIT = 2'd1, MMU_PF = 2'd2;
  localparam logic [1:0] TLB_HIT = 2'd0, TLB_MISS = 2'd1, TLB_PF = 2'd2;  // PL12.tlb
  localparam logic [4:0] AMO_LR = 5'b00010, AMO_SC = 5'b00011;

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
    logic            cand_v;
    logic [SQW-1:0]  cand;
    logic            dcblk;
    logic [31:0]     paddr;        // RTL: carried so that L2 does not read the LDQ
    logic [11:0]     voff;
    logic [2:0]      func3;
  } lp_pl12_t;

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
  } lp_l1in_t;

  // DTLB result of one L1 slot
  typedef struct packed {
    logic            hit;
    logic            pf;
    logic [31:0]     paddr;
    logic            mmio;
  } lp_tl_t;

  typedef struct packed {   // load AGU arrival (port i)
    logic            v;
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
    logic [BRW-1:0]  br_mask;
    logic [MDPW-1:0] mdp;          // wait-table index of the load PC (memory speculation)
    logic            wait_b;       // wait-table bit read at dispatch: this load does not pass unknown-address stores
  } lp_dis_ld_t;

  typedef struct packed {
    logic            v;
    logic [ROBW-1:0] rob_idx;
    logic            rob_flag;
    logic [BRW-1:0]  br_mask;
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
    logic [BRW-1:0]  br_mask;
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
  typedef struct packed {                // state of one insertion batch
    logic            go, tail_v, tail_new, t_mg, t_two;
    logic [1:0]      tail;
    logic [25:0]     t_line;
    logic [NWB-1:0]  alloc;
  } wbb_t;

  // LDQ entry registers visible to the glue (write-back, MMIO, wake)
  typedef struct packed {
    logic [ROBW-1:0] rob_idx;
    logic            rob_flag;
    logic [BRW-1:0]  br_mask;
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

  function automatic logic [12:0] ld_width13(input logic [2:0] func3);   // access size in bytes (1, 2, 4, 8)
    case (func3[1:0])
      2'b00:   return 13'd1;
      2'b01:   return 13'd2;
      2'b10:   return 13'd4;
      default: return (XLEN_BITS == 64) ? 13'd8 : 13'd4;
    endcase
  endfunction

  // relation of load [lo, lo+lw) and store [so, so+sw) on the low 12 address bits: 0 disjoint, 1 store covers, 2
  // partial
  function automatic logic [1:0] rel12(input logic [11:0] lo, input logic [2:0] lf, input logic [11:0] so,
                                       input logic [2:0] sf);
    logic [12:0] l0, l1, s0, s1;
    l0 = {1'b0, lo};
    l1 = l0 + ld_width13(lf);
    s0 = {1'b0, so};
    s1 = s0 + ld_width13(sf);
    if (s0 <= l0 && s1 >= l1) return 2'd1;
    else if (l1 <= s0 || l0 >= s1) return 2'd0;
    else return 2'd2;
  endfunction

  // same on the full 32-bit physical address (no wrap, as in the model)
  function automatic logic [1:0] rel32(input logic [31:0] lo, input logic [2:0] lf, input logic [31:0] so,
                                       input logic [2:0] sf);
    logic [32:0] l0, l1, s0, s1;
    l0 = {1'b0, lo};
    l1 = l0 + 33'(ld_width13(lf));
    s0 = {1'b0, so};
    s1 = s0 + 33'(ld_width13(sf));
    if (s0 <= l0 && s1 >= l1) return 2'd1;
    else if (l1 <= s0 || l0 >= s1) return 2'd0;
    else return 2'd2;
  endfunction

  // LP_L2[11] (R): the same relations for a LATE store address (wake-up confirm: the STA view arrives late, the load
  // is a register): the store address enters only comparators against thresholds computed from the load
  // (s0 + sw >= l1 <=> s0 >= l1 - sw, l0 >= s0 + sw <=> s0 <= l0 - sw), no adder behind it.
  function automatic logic [1:0] rel12s(input logic [11:0] lo, input logic [2:0] lf, input logic [11:0] so,
                                        input logic [2:0] sf);
    logic signed [14:0] s0s, l0s, l1s, a_w, b_w;
    logic covr, dsj;
    s0s = $signed({3'b000, so});
    l0s = $signed({3'b000, lo});
    l1s = l0s + $signed(15'(ld_width13(lf)));
    a_w = l1s - $signed(15'(ld_width13(sf)));
    b_w = l0s - $signed(15'(ld_width13(sf)));
    covr = s0s <= l0s && s0s >= a_w;
    dsj = s0s >= l1s || s0s <= b_w;
    if (covr) return 2'd1;
    else if (dsj) return 2'd0;
    else return 2'd2;
  endfunction

  function automatic logic [1:0] rel32s(input logic [31:0] lo, input logic [2:0] lf, input logic [31:0] so,
                                        input logic [2:0] sf);
    logic signed [34:0] s0s, l0s, l1s, a_w, b_w;
    logic covr, dsj;
    s0s = $signed({3'b000, so});
    l0s = $signed({3'b000, lo});
    l1s = l0s + $signed(35'(ld_width13(lf)));
    a_w = l1s - $signed(35'(ld_width13(sf)));
    b_w = l0s - $signed(35'(ld_width13(sf)));
    covr = s0s <= l0s && s0s >= a_w;
    dsj = s0s >= l1s || s0s <= b_w;
    if (covr) return 2'd1;
    else if (dsj) return 2'd0;
    else return 2'd2;
  endfunction

  // STLF confirm result: 0 no address yet (stay), 1 replay, 2 hold, 3 data missing, 4 forward
  typedef enum logic [2:0] {CF_NOADDR = 3'd0, CF_REPLAY, CF_HOLD, CF_DATA, CF_FWD} lp_conf_t;

  function automatic lp_conf_t stlf_confirm(input logic [11:0] lvoff, input logic [31:0] lpaddr, input logic [2:0] lf,
                                            input logic alive, input logic s_suppress, input logic s_va_v,
                                            input logic [11:0] s_voff, input logic s_pa_v, input logic [31:0] s_paddr,
                                            input logic [2:0] sf, input logic s_data_v, input logic s_hold_sc);
    logic [1:0] r;
    if (!alive || s_suppress) return CF_REPLAY;
    if (!s_va_v) return CF_NOADDR;
    if (!s_pa_v) begin
      if (((LP_L2 & 2048) != 0 ? rel12s(lvoff, lf, s_voff, sf) : rel12(lvoff, lf, s_voff, sf)) == 2'd0)
        return CF_REPLAY;
      return CF_NOADDR;
    end
    r = ((LP_L2 & 2048) != 0) ? rel32s(lpaddr, lf, s_paddr, sf) : rel32(lpaddr, lf, s_paddr, sf);
    if (r == 2'd0) return CF_REPLAY;
    if (r == 2'd2) return CF_HOLD;
    if (!s_data_v) return CF_DATA;
    if (s_hold_sc) return CF_HOLD;
    return CF_FWD;
  endfunction

  function automatic logic [RWW-1:0] replay_wait(input logic [1:0] rt);
    return (rt == RT_MSHR_HIT || rt == RT_MSHR_FULL) ? RWAIT : RWW'(0);
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
