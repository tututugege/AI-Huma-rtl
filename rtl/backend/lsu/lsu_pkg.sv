// Ref: back-end/Lsu/RealLsu.cpp  RealLsu  (types, enums, pure helpers: MemUtils.h, check_stlf, CheckAddr)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */  // package constants are used by other files
package lsu_pkg;
  import ttg_cfg_pkg::*;

  localparam int LQ   = LDQ_SIZE;
  localparam int SQ   = STQ_SIZE;
  localparam int LQW  = LDQ_IDX_WIDTH;
  localparam int SQW  = STQ_IDX_WIDTH;
  localparam int LQCW = LQW + 1;
  localparam int SQCW = SQW + 1;
  localparam int NLD  = LSU_LDU_COUNT;      // load units: DCache / MMU / write-back ports
  localparam int NST  = LSU_STA_COUNT;      // store units: DCache / MMU / STA write-back ports
  localparam int NSDU = LSU_SDU_COUNT;
  localparam int WIN  = LSU_LOAD_WINDOW_WIDTH;   // == LSU_STORE_WINDOW_WIDTH, window of every queue scan
  localparam int GENW = 31 - LDQ_IDX_WIDTH;      // DCache load request generation tag
  localparam int RWW  = LSU_REPLAY_WAIT_CYCLES_WIDTH;
  localparam int NDIS = MAX_LDQ_DISPATCH_WIDTH;
  localparam int NCM  = COMMIT_WIDTH;
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

  localparam logic [1:0] REPLAY_HIT = 2'd0, REPLAY_CONFLICT = 2'd1, REPLAY_MSHR_HIT = 2'd2, REPLAY_MSHR_FULL = 2'd3;
  localparam logic [1:0] MMU_MISS = 2'd0, MMU_HIT = 2'd1, MMU_PAGE_FAULT = 2'd2;
  localparam logic [4:0] INST_LOAD = 5'd5, INST_STORE = 5'd6, INST_AMO = 5'd18;
  localparam logic [4:0] AMO_LR = 5'b00010, AMO_SC = 5'b00011;
  localparam logic [RWW-1:0] REPLAY_WAIT = RWW'(LSU_PEPLAY_WAIT_CYCLES);

  // ---- a ring queue: valid bit + LDQ/STQ index per slot, head slot, count (the count includes invalid "holes") ----
  typedef struct packed {
    logic [RN-1:0]            valid;
    logic [RN-1:0][RIW-1:0]   idx;
    logic [RIW-1:0]           head;
    logic [RCW-1:0]           count;
  } lsu_ring_t;

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

  // ---- MemUtils.h ----
  function automatic logic [31:0] extract_data(input logic [31:0] raw, input logic [1:0] off, input logic [2:0] f3);
    logic [31:0] sh, r;
    sh = raw >> {off, 3'b000};
    case (f3[1:0])
      2'b00:   r = f3[2] ? {24'b0, sh[7:0]} : {{24{sh[7]}}, sh[7:0]};
      2'b01:   r = f3[2] ? {16'b0, sh[15:0]} : {{16{sh[15]}}, sh[15:0]};
      default: r = sh;
    endcase
    return r;
  endfunction

  function automatic logic [4:0] store_strb(input logic [1:0] off, input logic [1:0] f3);
    case (f3)
      2'b00:   return 5'b00001 << off;
      2'b01:   return 5'b00011 << off;
      2'b10:   return 5'b01111;
      default: return 5'b00000;
    endcase
  endfunction

  function automatic logic [31:0] align_store_data(input logic [31:0] data, input logic [1:0] off,
                                                   input logic [1:0] f3);
    logic [31:0] b, h;
    b = {24'b0, data[7:0]} << {off, 3'b000};
    h = {16'b0, data[15:0]} << {off, 3'b000};
    case (f3)
      2'b00:   return b;
      2'b01:   return h;
      2'b10:   return data;
      default: return 32'b0;
    endcase
  endfunction

  function automatic logic [2:0] mem_width(input logic [1:0] f3);   // bytes: 1, 2 or 4
    case (f3)
      2'b00:   return 3'd1;
      2'b01:   return 3'd2;
      default: return 3'd4;
    endcase
  endfunction

  // MMIO = every address outside the cacheable windows (mmio_address_map.h simulator_is_mmio_addr)
  function automatic logic is_mmio_addr(input logic [31:0] a);
    logic cacheable;
    cacheable = (a >= 32'(SIM_CACHE_ADDR_1_MIN) && a < 32'(SIM_CACHE_ADDR_1_MAX)) ||
                (a >= 32'(SIM_CACHE_ADDR_2_MIN) && a < 32'(SIM_CACHE_ADDR_2_MAX)) ||
                (a >= 32'(SIM_CACHE_ADDR_3_MIN) && a < 32'(SIM_CACHE_ADDR_3_MAX));
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

  // CheckAddr(): do the byte strobes of two word-aligned accesses overlap (bases at most one word apart)
  function automatic logic check_addr(input logic [29:0] a1w, input logic [4:0] s1,   // a*w = address[31:2]
                                      input logic [29:0] a2w, input logic [4:0] s2);
    logic [30:0] w1, w2;
    logic [8:0]  m1, m2;
    w1 = {1'b0, a1w};
    w2 = {1'b0, a2w};
    m1 = 9'(s1);
    m2 = 9'(s2);
    if (w1 == w2)           return (s1 & s2) != 5'b0;
    else if (w1 + 31'd1 == w2) return (m1 & (m2 << 4)) != 9'b0;
    else if (w2 + 31'd1 == w1) return ((m1 << 4) & m2) != 9'b0;
    else return 1'b0;
  endfunction

endpackage
`default_nettype wire
