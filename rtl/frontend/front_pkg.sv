// Ref: front-end/config/frontend_feature_config.h, front-end/wire_types.h, front-end/predecode.h
`default_nettype none
// Front-end constants, instruction_FIFO entry, and Unified FTQ-64 interface bundles.
package front_pkg;
  import ttg_cfg_pkg::*;

  // Instruction FIFO depth (frontend_feature_config.h: INSTRUCTION_FIFO_SIZE)
  localparam int INST_FIFO_DEPTH = INSTRUCTION_FIFO_SIZE;

  // prediction metadata (BPU_configs.h, wire_types.h)
  localparam int PCPN_W        = 3;
  localparam int BLK_ID_W      = 10;   // FTB block ID (matches bpu_types_pkg::FTB_BLK_ID_W)
  localparam int KIND_W        = 3;

  // predecode_type_t (predecode.h)
  localparam logic [1:0] PREDECODE_NON_BRANCH           = 2'd0;
  localparam logic [1:0] PREDECODE_BRANCH               = 2'd1;
  localparam logic [1:0] PREDECODE_JALR                 = 2'd2;
  localparam logic [1:0] PREDECODE_JAL                  = 2'd3;

  // predecode type of a control-flow kind (bpu_pkg BR_*, from predecode_lane): the checker only needs
  // conditional (direction from the prediction) / direct jump (jal target) / indirect jump (predicted target)
  function automatic logic [1:0] ptype_of_kind(input logic [KIND_W-1:0] k);
    case (k)
      bpu_pkg::BR_DIRECT:                                   return PREDECODE_BRANCH;
      bpu_pkg::BR_CALL, bpu_pkg::BR_JAL:                    return PREDECODE_JAL;
      bpu_pkg::BR_RET, bpu_pkg::BR_ICALL, bpu_pkg::BR_IDIRECT: return PREDECODE_JALR;
      default:                                              return PREDECODE_NON_BRANCH;
    endcase
  endfunction

  // RISC-V major opcodes used by predecode (RISCV.h)
  localparam logic [6:0] OPCODE_JAL    = 7'b1101111;
  localparam logic [6:0] OPCODE_JALR   = 7'b1100111;
  localparam logic [6:0] OPCODE_BRANCH = 7'b1100011;

  // instruction_FIFO entry: one halfword window of FETCH_WIDTH slots, already merged at the write side
  // (front_fetch_buf: Block A, and for a same-page line straddle the next line B behind A's a_len slots).
  // The 32-bit window of slot i is {half[i+1], half[i]} while slot i+1 is valid, {up16, half[i]} on the last valid
  // slot (up16 = the halfword above it); expand/predecode runs once in front_head_fix.
  typedef struct packed {
    logic                         is_straddle;   // B merged behind A (the sequential pc does not wrap to A's line)
    logic                         single_word;   // uncached answer (one 32-bit word = 2 slots)
    logic                         tail_ok;       // pc[5:0] == 32 and B hit: the halfword above slot 15 is real
    logic [XLEN_BITS-1:0]         base;          // pc of slot 0
    logic [FETCH_WIDTH-1:0]       valid;         // a prefix of the slots
    logic [FETCH_WIDTH-1:0]       pf;            // page fault (Block A only)
    logic [FETCH_WIDTH-1:0][15:0] half;          // slot halfword (low half of a NOP on invalid / faulting slots)
    logic [15:0]                  up16;          // halfword above the last valid slot (0 on a fault)
  } inst_fifo_entry_t;

  // ---- Unified FTQ-64 frontend <-> backend interface (zero combinational loop) ----
  // Pure registered feedback from ftq_ibuf (back_top) to front_top
  typedef struct packed {
    logic                     ftq_full;        // (bpu-comm)>=63 || (bpu-ifu)>=15
    logic                     ifu_empty;       // ifu_ptr == bpu_ptr
    logic [1:0]               ifu_cnt_sat;     // min(bpu_ptr - ifu_ptr, 3) for S3 hold_n check
    logic                     s2_empty;        // pd_ptr == s2_ptr
    logic [XLEN_BITS-1:0]     ifu_addr;        // entry[ifu_ptr].pc0
    logic [5:0]               ifu_next_set_idx; // entry[ifu_ptr+1].pc0[11:6] (L1I SRAM pre-launch)
    logic [FTQ_IDX_WIDTH-1:0] pd_idx;          // pd_ptr
    logic [XLEN_BITS-1:0]     pd_base_pc;      // entry[pd_ptr].pc0
    logic [FETCH_WIDTH-1:0]   pd_pred_dir;     // entry[pd_ptr].pred_taken
    logic [XLEN_BITS-1:0]     pd_next_pc;      // entry[pd_ptr].next_pc
  } ftq_fe_view_t;

  // Frontend S0 allocate / S3-override drop_tail_n (0..2) / ICache issue pop -> ftq_ibuf
  typedef struct packed {
    logic                 wr_en;
    logic [XLEN_BITS-1:0] addr;
    logic [1:0]           drop_tail_n;
    logic                 ifu_pop;
  } fe_ftq_s0_t;

  // Frontend BPU S2 fill (prediction + ftq_meta written once at s2_ptr) -> ftq_ibuf
  typedef struct packed {
    logic                               wr_en;
    logic [XLEN_BITS-1:0]               base_pc;
    logic [FETCH_WIDTH-1:0]             pred_dir;
    logic [XLEN_BITS-1:0]               next_pc;
    logic [FETCH_WIDTH-1:0]             alt_pred;
    logic [FETCH_WIDTH-1:0][PCPN_W-1:0] pcpn;
    logic [BLK_ID_W-1:0]                blk_id;
  } fe_ftq_s2_t;

  // Frontend Predecode in-place update at pd_ptr (+ frontend-only rollback on flush) -> ftq_ibuf
  typedef struct packed {
    logic                               fire;
    logic                               flush;
    logic                               empty_blk;
    logic                               carry;
    logic [XLEN_BITS-1:0]               pc0;
    logic [FETCH_WIDTH-1:0]             pred_dir;
    logic [FETCH_WIDTH-1:0]             is_rvc;
    logic [XLEN_BITS-1:0]               next_pc;
    logic [FETCH_WIDTH-1:0][KIND_W-1:0] slot_kind;
  } fe_ftq_pd_t;
endpackage

`default_nettype wire
