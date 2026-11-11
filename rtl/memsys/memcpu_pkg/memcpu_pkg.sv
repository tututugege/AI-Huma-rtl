// Ref: MemSubSystem/MemRouteBlock.h  Owner, route request ids; shared constants of the CPU-phase blocks
`default_nettype none
/* verilator lint_off UNUSEDPARAM */  // constants package: not every constant is used by every module
package memcpu_pkg;
  import ttg_cfg_pkg::*;

  // ---- DCache load/store ports (LSU side) ----
  localparam int NLD        = LSU_LDU_COUNT;         // load ports; the LAST one (NLD-1) is shared with ICache / PTW
  localparam int NST        = LSU_STA_COUNT;         // 4 store ports
  localparam int P3         = NLD - 1;               // shared load port
  localparam int LD_ID_W    = 31;                    // LSU load request id (bit 31 = route flag, route block's)
  localparam int ST_ID_W    = 6;                     // LSU store request id (STQ index)
  localparam int ST_STRB_W  = DST_STRB_W;            // store strobe bits (XLEN/8 + 1); the DCache uses XLEN/8
  localparam int FILL_LINE_W = 26;                   // mshr_fill_addr >> 6

  // ---- route request ids {1, 0.., counter}; only the low RT_ID_W bits are kept: one route request is in flight
  //      (its response comes back the next cycle), so ids never alias inside the window where they are compared ----
  localparam int RT_ID_W    = 4;

  typedef enum logic [1:0] {
    OWN_NONE   = 2'd0,
    OWN_ICACHE = 2'd1,
    OWN_WALK   = 2'd2
  } route_owner_e;

  // ReplayType of IO.h
  localparam logic [1:0] REPLAY_HIT      = 2'd0;
  localparam logic [1:0] REPLAY_CONFLICT = 2'd1;
  localparam logic [1:0] REPLAY_MSHR_HIT = 2'd2;
  localparam logic [1:0] REPLAY_MSHR_FULL = 2'd3;

  // ---- PTW (Sv32: 2 levels, 4-byte PTEs; Sv39: 3 levels, 8-byte PTEs) ----
  localparam int PT_LEVELS    = (XLEN_BITS == 64) ? 3 : 2;
  localparam int PT_VPN_PART_W = (XLEN_BITS == 64) ? 9 : 10;   // one VPN field
  localparam int PT_PTE_SHIFT = (XLEN_BITS == 64) ? 3 : 2;     // log2 of the PTE size
  localparam int PT_LVL_W     = (XLEN_BITS == 64) ? 2 : 1;     // leaf level 0 .. PT_LEVELS-1
  localparam int PT_VPN_W   = PT_LEVELS * PT_VPN_PART_W;
  localparam int PT_PPN_IN_W = 22;                   // satp.ppn as sent by the TLBs
  localparam int PT_PPN_W   = 20;                    // ppn bits that reach a 32-bit address ((ppn << 12) wraps)
  localparam int PT_PERM_W  = 8;
  localparam int PT_ID_W    = RT_ID_W;
  localparam int PT_NCLIENT = 2;                     // 0 = DTLB, 1 = ITLB

  // walker FSM (Ref: MemPtwBlock WalkState)
  typedef enum logic [2:0] {
    PW_IDLE    = 3'd0,
    PW_L1_REQ  = 3'd1,   // level-1 PTE read to be issued
    PW_L1_WAIT = 3'd2,   // level-1 read granted, waiting for the PTE
    PW_L2_REQ  = 3'd3,   // level-0 PTE read to be issued
    PW_L2_WAIT = 3'd4
  } ptw_state_e;

  // ---- peripheral ----
  localparam int PA_SIZE_W  = 2;                     // AXI total_size = bytes-1 in {0,1,3}

  // ---- AXI CPU-port adapter ----
  localparam int AX_ID_W    = 4;                     // AXI ids of the CPU-side masters (ICache: 4, peripheral: 0)
  localparam int AX_NCH     = 3;                     // channels: read ICACHE, read EXTRA, write EXTRA
endpackage
`default_nettype wire
