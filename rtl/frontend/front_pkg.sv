// Ref: front-end/config/frontend_feature_config.h, front-end/wire_types.h, front-end/predecode.h
`default_nettype none
/* verilator lint_off UNUSEDPARAM */
// Front-end constants, 2-taken FetchPair descriptor, instruction_FIFO entry, and Unified FTQ-64 interface bundles.
package front_pkg;
  import ttg_cfg_pkg::*;

  // Instruction FIFO depth (frontend_feature_config.h: INSTRUCTION_FIFO_SIZE)
  localparam int INST_FIFO_DEPTH   = INSTRUCTION_FIFO_SIZE;
  localparam int INST_FIFO_FULL_AT = INST_FIFO_DEPTH;

  // prediction metadata (BPU_configs.h, wire_types.h)
  localparam int PCPN_W        = 3;
  localparam int BLK_ID_W      = 10;   // FTB block ID (matches bpu_types_pkg::FTB_BLK_ID_W)
  localparam int INST_BYTES    = 4;
  localparam int KIND_W        = 3;

  // predecode_type_t (predecode.h)
  localparam logic [1:0] PREDECODE_NON_BRANCH           = 2'd0;
  localparam logic [1:0] PREDECODE_DIRECT_JUMP_NO_JAL   = 2'd1;
  localparam logic [1:0] PREDECODE_JALR                 = 2'd2;
  localparam logic [1:0] PREDECODE_JAL                  = 2'd3;

  // RISC-V major opcodes used by predecode (RISCV.h)
  localparam logic [6:0] OPCODE_JAL    = 7'b1101111;
  localparam logic [6:0] OPCODE_JALR   = 7'b1100111;
  localparam logic [6:0] OPCODE_BRANCH = 7'b1100011;

  // 2-taken fetch pair descriptor carried through Unified FTQ-64 & pend_pair_q
  typedef struct packed {
    logic                 valid;
    logic [XLEN_BITS-1:0] addr2;
    logic [3:0]           a_len;
    logic [3:0]           b_len;
  } fetch_pair_t;

  // instruction_FIFO entry: compact raw halfwords (Block A + optional Block B); expand/predecode runs once after S2 A/B mux.
  typedef struct packed {
    logic                         is_pair;
    logic [3:0]                   a_len;
    logic [XLEN_BITS-1:0]         base_a;
    logic [XLEN_BITS-1:0]         base_b;
    logic [FETCH_WIDTH-1:0]       valid_a;
    logic [FETCH_WIDTH-1:0]       pf_a;
    logic                         single_word_a;
    logic [FETCH_WIDTH-1:0][15:0] raw_a;
    logic [15:0]                  up16_a;
    logic                         b_ok;
    logic [4:0]                   b_actual_n;
    logic [FETCH_WIDTH-1:0][15:0] raw_b;
    logic [15:0]                  up16_b;
  } inst_fifo_entry_t;

  // ---- Unified FTQ-64 frontend <-> backend interface (zero combinational loop) ----
  // Pure registered feedback from ftq_ibuf (back_top) to front_top
  typedef struct packed {
    logic                     ftq_full;        // (bpu-comm)>=63 || (bpu-ifu)>=15
    logic                     fa_empty;        // ifu_ptr == bpu_ptr
    logic                     fa_head_fresh;   // EXP-044: ifu_ptr entry pushed last cycle
    logic                     s2_empty;        // pd_ptr == s2_ptr
    logic [XLEN_BITS-1:0]     ifu_addr;        // entry[ifu_ptr].pc0
    fetch_pair_t              ifu_pair;        // entry[ifu_ptr] FetchPair descriptor
    logic [5:0]               ifu_next_fa_idx; // entry[ifu_ptr+1].pc0[11:6] (L1I SRAM pre-launch)
    logic [5:0]               ifu_next_b_idx;  // entry[ifu_ptr+1].base_b[11:6] (L1I SRAM pre-launch)
    logic [FTQ_IDX_WIDTH-1:0] pd_idx;          // pd_ptr
    logic [XLEN_BITS-1:0]     pd_base_pc;      // entry[pd_ptr].pc0
    logic                     pd_is_pair;      // entry[pd_ptr].is_pair
    logic [XLEN_BITS-1:0]     pd_base_b;       // entry[pd_ptr].base_b
    logic [3:0]               pd_a_len;        // entry[pd_ptr].a_len
    logic [FETCH_WIDTH-1:0]   pd_pred_dir;     // entry[pd_ptr].pred_taken
    logic [XLEN_BITS-1:0]     pd_next_pc;      // entry[pd_ptr].next_pc
  } ftq_fe_view_t;

  // Frontend S0 allocate / S2-override drop_tail / ICache issue pop -> ftq_ibuf
  typedef struct packed {
    logic                 wr_en;
    logic [XLEN_BITS-1:0] addr;
    fetch_pair_t          pair;
    logic                 drop_tail;
    logic                 ifu_pop;
  } fe_ftq_s0_t;

  // Frontend BPU S2 fill (prediction + ftq_meta written once at s2_ptr) -> ftq_ibuf
  typedef struct packed {
    logic                               wr_en;
    logic [XLEN_BITS-1:0]               base_pc;
    logic                               is_pair;
    logic [XLEN_BITS-1:0]               base_b;
    logic [3:0]                         a_len;
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
    logic [4:0]                         nslots;
    logic [FETCH_WIDTH-1:0][KIND_W-1:0] slot_kind;
  } fe_ftq_pd_t;

  // Reconstruct lane i PC from compact {base_a, is_pair, a_len, base_b}
  function automatic logic [XLEN_BITS-1:0] pair_slot_pc(
    input logic [XLEN_BITS-1:0] base_a, input logic is_pair,
    input logic [3:0] a_len, input logic [XLEN_BITS-1:0] base_b, input int idx
  );
    if (is_pair && (4'(idx) >= a_len))
      return base_b + (XLEN_BITS'(4'(idx) - a_len) << SLOT_SHIFT);
    else
      return base_a + XLEN_BITS'(SLOT_BYTES * idx);
  endfunction
endpackage

`default_nettype wire
