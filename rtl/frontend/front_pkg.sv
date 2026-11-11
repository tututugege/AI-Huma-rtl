// Ref: front-end/config/frontend_feature_config.h, front-end/wire_types.h, front-end/predecode.h
`default_nettype none
/* verilator lint_off UNUSEDPARAM */
// Front-end constants: FIFO depths (from ttg_cfg_pkg, generated from frontend_feature_config.h), prediction-metadata
// widths and the predecode type encoding.  Values checked with docs/analysis/tools/widths.cpp (real configuration).
package front_pkg;
  import ttg_cfg_pkg::*;

  // FIFO depths (frontend_feature_config.h: INSTRUCTION_FIFO_SIZE, PTAB_SIZE, ...)
  localparam int FETCH_ADDR_FIFO_DEPTH = FETCH_ADDR_FIFO_SIZE;
  localparam int INST_FIFO_DEPTH       = INSTRUCTION_FIFO_SIZE;
  localparam int PTAB_DEPTH            = PTAB_SIZE;
  localparam int F2B_FIFO_DEPTH        = FRONT2BACK_FIFO_SIZE;
  // "full" thresholds of the C++ latches (front_top.cpp:1841-1848): BPU back-pressure FIFOs go full one entry early
  localparam int FETCH_ADDR_FIFO_FULL_AT = FETCH_ADDR_FIFO_DEPTH - 1;
  localparam int INST_FIFO_FULL_AT       = INST_FIFO_DEPTH;
  localparam int PTAB_FULL_AT            = PTAB_DEPTH - 1;
  localparam int F2B_FIFO_FULL_AT        = F2B_FIFO_DEPTH;

  // prediction metadata (BPU_configs.h, wire_types.h)
  localparam int TN_MAX        = 4;    // TAGE tables
  localparam int PCPN_W        = 3;
  localparam int TAGE_IDX_W    = 10;
  localparam int TAGE_TAG_W    = 8;
  localparam int INST_BYTES    = 4;
  // BPU repair record of a fetch group: history checkpoint of the block + history epoch (travels with the block to the
  // back-end FTQ and is returned with a branch mispredict), and the BPU type of every slot (predecode)
  localparam int BCK_W         = bpu_stage_pkg::HCK_W + bpu_stage_pkg::EPOCH_W;
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

  // ---- FIFO entries (debug-only fields of the C++ entries are not stored) ----
  // instruction_FIFO entry: one predecoded fetch group
  typedef struct packed {
    logic [31:0]                               seq_next_pc;
    logic [FETCH_WIDTH-1:0][31:0]              predecode_target_address;
    logic [FETCH_WIDTH-1:0][1:0]               predecode_type;
    logic [FETCH_WIDTH-1:0]                    inst_valid;
    logic [FETCH_WIDTH-1:0]                    page_fault_inst;
    logic [FETCH_WIDTH-1:0][31:0]              instructions;
  } inst_fifo_entry_t;

  // BPU prediction metadata of one fetch group, shared by the PTAB and front2back entries.
  // predict_base_pc is the pc of lane 0; lane i is predict_base_pc + 4*i (front_top.cpp front_ptab_write_comb).
  typedef struct packed {
    logic [FETCH_WIDTH-1:0][TN_MAX-1:0][TAGE_TAG_W-1:0]      tage_tag;
    logic [FETCH_WIDTH-1:0][TN_MAX-1:0][TAGE_IDX_W-1:0]      tage_idx;
    logic [FETCH_WIDTH-1:0][PCPN_W-1:0]                      pcpn;
    logic [FETCH_WIDTH-1:0]                                  alt_pred;
    logic [31:0]                                             predict_base_pc;
  } pred_meta_t;

  // PTAB entry: BPU prediction of one fetch group
  typedef struct packed {
    pred_meta_t                    meta;
    logic [BCK_W-1:0]              bpu_ck;
    logic [FETCH_WIDTH-1:0]        predict_dir;
    logic [31:0]                   predict_next_fetch_address;
  } ptab_entry_t;

  // front2back_FIFO entry: instructions + prediction metadata + checker-corrected direction / next address
  typedef struct packed {
    logic [31:0]                   predict_next_fetch_address_corrected;
    pred_meta_t                    meta;
    logic [BCK_W-1:0]              bpu_ck;
    logic [FETCH_WIDTH-1:0][KIND_W-1:0] slot_kind;
    logic [FETCH_WIDTH-1:0]        predict_dir_corrected;
    logic [FETCH_WIDTH-1:0]        inst_valid;
    logic [FETCH_WIDTH-1:0]        page_fault_inst;
    logic [FETCH_WIDTH-1:0][31:0]  fetch_group;
  } f2b_fifo_entry_t;
endpackage

`default_nettype wire
