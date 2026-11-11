// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (types, enums, pure helpers: MemUtils.h, check_stlf, CheckAddr)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */  // package constants are used by other files
package lsu_pkg;
  import ttg_cfg_pkg::*;

  localparam int LQ   = LDQ_SIZE;
  localparam int SQ   = STQ_SIZE;
  localparam int LQW  = LDQ_IDX_WIDTH;
  localparam int SQW  = STQ_IDX_WIDTH;
  localparam int NLD  = LSU_LDU_COUNT;      // load units: DCache / MMU / write-back ports
  localparam int NST  = LSU_STA_COUNT;      // store units: DCache / MMU / STA write-back ports
  localparam int NSDU = LSU_SDU_COUNT;
  localparam int WIN  = LSU_LOAD_WINDOW_WIDTH;   // array size of every queue scan (the load window)
  localparam int STWIN = LSU_STORE_WINDOW_WIDTH; // store-queue scan depth (trace-model: LSU_STA_COUNT * 5)
  localparam int GENW = 31 - LDQ_IDX_WIDTH;      // DCache load request generation tag
  localparam int RWW  = LSU_REPLAY_WAIT_CYCLES_WIDTH;
  localparam int NDIS = MAX_LDQ_DISPATCH_WIDTH;
  localparam int NCM  = COMMIT_WIDTH;
  localparam int ROBW = ROB_IDX_WIDTH;
  localparam int PRFW = PRF_IDX_WIDTH;
  localparam int BRW  = BR_MASK_WIDTH;
  localparam int RN   = LDQ_SIZE;                // all six queues are rings of this size
  localparam int RIW  = LDQ_IDX_WIDTH;
  localparam int RCW  = RIW + 1;
  localparam int LINE_LO = DCACHE_OFFSET_BITS;
  localparam int LINEW   = 32 - DCACHE_OFFSET_BITS;

  // ---- LDQ / STQ state machines (RealLsu.h LoadState / IO.h StoreState; only states that survive a clock edge) ----
  typedef enum logic [3:0] {
    LD_EMPTY = 4'd0, LD_ALLOCATED, LD_WAIT_TLB, LD_WAIT_TLB_RETRY, LD_WAIT_STLF, LD_CHECK_STLF, LD_READY_TO_ISSUE,
    LD_WAIT_DCACHE_RESP, LD_WAIT_MMIO_RESP, LD_READY_TO_WB, LD_PAGE_FAULT, LD_WAIT_FINISH, LD_WAIT_DCACHE
  } ld_state_t;

  typedef enum logic [3:0] {
    ST_EMPTY = 4'd0, ST_ALLOCATED, ST_WAIT_DATA, ST_WAIT_TLB, ST_WAIT_TLB_RETRY, ST_WAIT_DONE, ST_READY, ST_WAIT_COMMIT,
    ST_COMMITTED, ST_WAIT_DCACHE_RESP, ST_WAIT_MMIO_RESP, ST_PAGE_FAULT, ST_DONE
  } st_state_t;

  localparam logic [1:0] REPLAY_HIT = 2'd0, REPLAY_MSHR_HIT = 2'd2, REPLAY_MSHR_FULL = 2'd3;
  localparam logic [1:0] MMU_MISS = 2'd0, MMU_HIT = 2'd1, MMU_PAGE_FAULT = 2'd2;
  localparam logic [4:0] INST_STORE = 5'd6, INST_AMO = 5'd18;
  localparam logic [4:0] AMO_LR = 5'b00010, AMO_SC = 5'b00011;
  localparam logic [RWW-1:0] REPLAY_WAIT = RWW'(LSU_PEPLAY_WAIT_CYCLES);

  // rotate a slot-ordered vector so that bit p is slot (head + p): "position" order
  function automatic logic [RN-1:0] rotr_rn(input logic [RN-1:0] v, input logic [RIW-1:0] sh);
    return RN'({v, v} >> sh);
  endfunction
  // inverse: position-ordered vector to slot order
  function automatic logic [RN-1:0] rotl_rn(input logic [RN-1:0] v, input logic [RIW-1:0] sh);
    return rotr_rn(v, RIW'(-sh));
  endfunction

  // stq_idx_alive_after_flush(): is the STQ index inside [head, head + count)
  function automatic logic stq_alive(input logic [RIW-1:0] idx, input logic [RIW-1:0] head,
                                     input logic [RCW-1:0] count);
    return {1'b0, RIW'(idx - head)} < count;
  endfunction

  // ---- per-slot / per-entry bundles (all packed) ----
  // LDQ entry data fields (the state machine and `result` are held separately, see lsu_ldq_ent)
  typedef struct packed {
    logic [31:0]     vaddr, paddr;
    logic [2:0]      func3;
    logic [PRFW-1:0] dest;
    logic [ROBW-1:0] rob_idx;
    logic            rob_flag;
    logic [BRW-1:0]  br_mask;
    logic [SQW-1:0]  snap_idx;
    logic            snap_flag;
    logic [1:0]      replay;
    logic            mmio, pf, lrsc;
  } ldq_fld_t;

  // STQ entry data fields (the state machine and the replay wait are held separately, see lsu_stq_ent)
  typedef struct packed {
    logic [31:0]     data, vaddr, paddr;
    logic [2:0]      func3;
    logic [PRFW-1:0] dest;
    logic [ROBW-1:0] rob_idx;
    logic            rob_flag;
    logic [BRW-1:0]  br_mask;
    logic [1:0]      replay;
    logic            data_valid, paddr_valid, pf, suppress, mmio, lrsc, sc_pass;
  } stq_fld_t;

  // LDQ events (one bundle per entry per cycle; "go" is already fully qualified by the queue logic)
  typedef struct packed { logic go; logic [31:0] data; } ldq_mm_t;                               // C
  typedef struct packed { logic go; logic hit; logic [1:0] rp; logic [31:0] data; } ldq_dc_t;    // D
  typedef struct packed {                                                                          // G
    logic go; logic [31:0] vaddr; logic [PRFW-1:0] dest; logic [2:0] func3;
    logic [SQW-1:0] snap_idx; logic snap_flag; logic lrsc;
  } ldq_agu_t;
  typedef struct packed { logic go; logic [1:0] res; logic [31:0] paddr; } ldq_tr_t;            // I1
  typedef struct packed { logic stlf, fin, retry; } ldq_tw_t;                                    // I2
  typedef struct packed { logic chg; ld_state_t new_st; logic res_we; logic [31:0] res; } ldq_sf_t;   // J
  typedef struct packed {                                                                          // K
    logic go; logic [ROBW-1:0] rob_idx; logic rob_flag; logic [BRW-1:0] br_mask;
  } ldq_al_t;

  // STQ events
  typedef struct packed { logic go; logic hit; logic [1:0] rp; } stq_dc_t;                       // E
  typedef struct packed { logic go; logic sc_upd; logic pass; } stq_wb_t;                        // F
  typedef struct packed { logic std_go; logic std_rdy; logic [31:0] data;                          // G
                          logic sta_go; logic [31:0] vaddr; logic [2:0] func3; logic [PRFW-1:0] dest; logic lrsc;
                        } stq_ex_t;
  typedef struct packed { logic go; logic [1:0] res; logic [31:0] paddr; } stq_tr_t;            // I1
  typedef struct packed { logic done, retry; } stq_tw_t;                                         // I2
  typedef struct packed {                                                                          // K
    logic go; logic [ROBW-1:0] rob_idx; logic rob_flag; logic [BRW-1:0] br_mask;
  } stq_al_t;
  typedef struct packed { logic iss, sup, mm, dec; } stq_is_t;                                   // N

  // ---- a ring queue: valid bit + LDQ/STQ index per slot, head slot, count (the count includes invalid "holes") ----
  typedef struct packed {
    logic [RN-1:0]            valid;
    logic [RN-1:0][RIW-1:0]   idx;
    logic [RIW-1:0]           head;
    logic [RCW-1:0]           count;
  } lsu_ring_t;

  // one queue operation of a cycle: kill_slot, then (do_kp) window kill + pop of leading holes, then append; flush last
  typedef struct packed {
    logic [WIN-1:0]            app_en;     // append candidates, priority order, compacted
    logic [WIN-1:0][RIW-1:0]   app_idx;
    logic [RN-1:0]             kill_slot;  // invalidate by slot
    logic [WIN-1:0]            keep_w;     // window position kept (0 = invalidate)
    logic                      do_kp;
    logic                      flush;      // valid = 0, count = 0, head unchanged
  } lsu_rop_t;

  typedef struct packed { lsu_ring_t r; logic [RN-1:0] set; } lsu_rres_t;

  localparam lsu_rop_t ROP_NOP = '0;

  // ring_apply(): the effect of one operation; `set` marks the slots that were written by the append
  function automatic lsu_rres_t ring_apply(input lsu_ring_t r0, input lsu_rop_t op);
    lsu_rres_t      res;
    lsu_ring_t      a;
    logic [RCW-1:0] n_pop, win_count, n_app;
    logic [RIW-1:0] slot;
    res.set = '0;
    a       = r0;
    a.valid = r0.valid & ~op.kill_slot;
    if (op.do_kp) begin
      for (int p = 0; p < WIN; p++) begin
        if (a.count > RCW'(p) && !op.keep_w[p]) a.valid[a.head + RIW'(p)] = 1'b0;
      end
      win_count = a.count > RCW'(WIN) ? RCW'(WIN) : a.count;
      n_pop     = win_count;
      for (int p = WIN - 1; p >= 0; p--) begin
        if (a.count > RCW'(p) && a.valid[a.head + RIW'(p)]) n_pop = RCW'(p);
      end
      a.head  = a.head + RIW'(n_pop);
      a.count = a.count - n_pop;
    end
    n_app = '0;
    for (int k = 0; k < WIN; k++) begin
      if (op.app_en[k]) begin
        slot = a.head + RIW'(a.count) + RIW'(n_app);
        a.valid[slot]  = 1'b1;
        a.idx[slot]    = op.app_idx[k];
        res.set[slot]  = 1'b1;
        n_app          = n_app + RCW'(1);
      end
    end
    a.count = a.count + n_app;
    if (op.flush) begin
      a.valid = '0;
      a.count = '0;
    end
    res.r = a;
    return res;
  endfunction

  function automatic lsu_rop_t rop_app(input logic [WIN-1:0] en, input logic [WIN-1:0][RIW-1:0] idx);
    lsu_rop_t o;
    o         = ROP_NOP;
    o.app_en  = en;
    o.app_idx = idx;
    return o;
  endfunction

  function automatic lsu_rop_t rop_kp(input logic [WIN-1:0] keep);
    lsu_rop_t o;
    o        = ROP_NOP;
    o.do_kp  = 1'b1;
    o.keep_w = keep;
    return o;
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
      2'b10:   r = (XW == 32) ? sh : f3[2] ? XW'(sh[HW-1:0]) : XW'($signed(sh[HW-1:0]));   // rv64: lw sign-, lwu zero-extends
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

  function automatic logic [3:0] mem_width(input logic [1:0] f3);   // bytes: 1, 2, 4 (or 8: sd / ld on rv64)
    case (f3)
      2'b00:   return 4'd1;
      2'b01:   return 4'd2;
      2'b10:   return 4'd4;
      default: return (XW == 64) ? 4'd8 : 4'd4;
    endcase
  endfunction

  // MMIO = every address outside the cacheable windows (mmio_address_map.h simulator_is_mmio_addr)
  function automatic logic is_mmio_addr(input logic [31:0] a);
    logic cacheable;
    cacheable = (a >= 32'(SIM_CACHE_ADDR_1_MIN) && a < 32'(SIM_CACHE_ADDR_1_MAX)) ||
                (a >= 32'(SIM_CACHE_ADDR_2_MIN) && a < 32'(SIM_CACHE_ADDR_2_MAX));
    return !cacheable;
  endfunction

  // check_stlf(): 0 = disjoint, 1 = store covers the load, 2 = partial overlap (32-bit address wrap as in C++)
  function automatic logic [1:0] stlf_class(input logic [31:0] l_addr, input logic [1:0] l_f3,
                                            input logic [31:0] s_addr, input logic [1:0] s_f3);
    logic [31:0] s_end, l_end;
    s_end = s_addr + 32'(mem_width(s_f3));
    l_end = l_addr + 32'(mem_width(l_f3));
    if (s_addr <= l_addr && s_end >= l_end) return 2'd1;
    else if (l_end <= s_addr || l_addr >= s_end) return 2'd0;
    else return 2'd2;
  endfunction

  // CheckAddr(): do the byte strobes of two data-word-aligned accesses overlap (bases at most one data word apart);
  // a*w = address[31:OW]
  function automatic logic check_addr(input logic [31-OW:0] a1w, input logic [SW:0] s1,
                                      input logic [31-OW:0] a2w, input logic [SW:0] s2);
    logic [32-OW:0]  w1, w2;
    logic [2*SW:0]   m1, m2;
    w1 = {1'b0, a1w};
    w2 = {1'b0, a2w};
    m1 = (2 * SW + 1)'(s1);
    m2 = (2 * SW + 1)'(s2);
    if (w1 == w2)                   return (s1 & s2) != '0;
    else if (w1 + 1'b1 == w2)       return (m1 & (m2 << SW)) != '0;
    else if (w2 + 1'b1 == w1)       return ((m1 << SW) & m2) != '0;
    else return 1'b0;
  endfunction

endpackage
`default_nettype wire
