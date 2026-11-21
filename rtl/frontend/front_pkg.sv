// Ref: front-end/config/frontend_feature_config.h, front-end/wire_types.h, front-end/predecode.h
`default_nettype none
/* verilator lint_off UNUSEDPARAM */
// Front-end constants, 2-taken FetchPair descriptor, and FIFO entry structs.
package front_pkg;
  import ttg_cfg_pkg::*;

  // FIFO depths (frontend_feature_config.h: INSTRUCTION_FIFO_SIZE, PTAB_SIZE, ...)
  localparam int FETCH_ADDR_FIFO_DEPTH = FETCH_ADDR_FIFO_SIZE;
  localparam int INST_FIFO_DEPTH       = INSTRUCTION_FIFO_SIZE;
  localparam int PTAB_DEPTH            = PTAB_SIZE;
  localparam int F2B_FIFO_DEPTH        = FRONT2BACK_FIFO_SIZE;
  // "full" thresholds of the C++ latches: BPU back-pressure FIFOs go full one entry early
  localparam int FETCH_ADDR_FIFO_FULL_AT = FETCH_ADDR_FIFO_DEPTH - 1;
  localparam int INST_FIFO_FULL_AT       = INST_FIFO_DEPTH;
  localparam int PTAB_FULL_AT            = PTAB_DEPTH - 1;
  localparam int F2B_FIFO_FULL_AT        = F2B_FIFO_DEPTH;

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

  // 2-taken fetch pair descriptor carried through fetch_addr_fifo & pend_pair_q
  typedef struct packed {
    logic                 valid;
    logic [XLEN_BITS-1:0] addr2;
    logic [3:0]           a_len;
    logic [3:0]           b_len;
  } fetch_pair_t;

  // ---- FIFO entries ----
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

  // BPU prediction metadata of one fetch group, shared by PTAB and front2back entries.
  // Block A lanes have id = blk_id; paired Block B lanes (idx >= a_len when is_pair) have id = blk_id + 1.
  typedef struct packed {
    logic [BLK_ID_W-1:0]                blk_id;
    logic [FETCH_WIDTH-1:0][PCPN_W-1:0] pcpn;
    logic [FETCH_WIDTH-1:0]             alt_pred;
    logic [XLEN_BITS-1:0]               predict_base_pc;
  } pred_meta_t;

  // PTAB entry: BPU prediction of one fetch group (compact {is_pair, base_b, a_len}, no bpu_ck)
  typedef struct packed {
    pred_meta_t             meta;
    logic                   is_pair;
    logic [XLEN_BITS-1:0]   base_b;
    logic [3:0]             a_len;
    logic [FETCH_WIDTH-1:0] predict_dir;
    logic [XLEN_BITS-1:0]   predict_next_fetch_address;
  } ptab_entry_t;

  // front2back_FIFO entry: instructions + prediction metadata + checker-corrected direction / next address
  typedef struct packed {
    logic [XLEN_BITS-1:0]               predict_next_fetch_address_corrected;
    pred_meta_t                         meta;
    logic                               is_pair;
    logic [XLEN_BITS-1:0]               base_b;
    logic [3:0]                         a_len;
    logic [FETCH_WIDTH-1:0][KIND_W-1:0] slot_kind;
    logic [FETCH_WIDTH-1:0]             predict_dir_corrected;
    logic [FETCH_WIDTH-1:0]             inst_valid;
    logic [FETCH_WIDTH-1:0]             page_fault_inst;
    logic [FETCH_WIDTH-1:0]             pf_inst_hi;
    logic [FETCH_WIDTH-1:0]             is_rvc;
    logic                               carry;
    logic [FETCH_WIDTH-1:0][31:0]       fetch_group;
  } f2b_fifo_entry_t;

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
