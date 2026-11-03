// Ref: front-end/BPU/BPU_configs.h  (constants of the effective configuration, frontend_feature_config.h)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */
// BPU constants for the DEFAULT configuration (ENABLE_TAGE_SC_L=0, ENABLE_TAGE_LOOP_PRED=0, 2-ahead/NLP off, RAS on).
// Values are checked against frontend_feature_config.h; ttg_cfg_pkg does not export the BPU-specific macros.
package bpu_pkg;
  import ttg_cfg_pkg::*;

  localparam int NBANK   = 8;                 // BPU_BANK_NUM
  localparam int BANK_W  = 3;
  localparam int NLANE   = FETCH_WIDTH;       // lanes of one fetch group (8)
  localparam int NCOMMIT = COMMIT_WIDTH;      // commit lanes (8)
  localparam int PC_W    = 32;
  localparam int BPC_W   = PC_W - BANK_W;     // bank pc = pc >> 3 (BankPcComb)

  // branch types (BPU_configs.h)
  localparam logic [2:0] BR_DIRECT  = 3'd0;   // conditional branch
  localparam logic [2:0] BR_CALL    = 3'd1;
  localparam logic [2:0] BR_RET     = 3'd2;
  localparam logic [2:0] BR_IDIRECT = 3'd3;
  localparam logic [2:0] BR_NONCTL  = 3'd4;
  localparam logic [2:0] BR_JAL     = 3'd5;

  // ---- type predictor ----
  localparam int TP_WAYS  = 2;
  localparam int TP_SET_W = 9;                // 512 sets per bank
  localparam int TP_TAG_W = 8;
  localparam int TP_MEM_W = BANK_W + TP_SET_W;
  // table entry: the C++ entry's 2-bit confidence counter is dead (only read by the unused pred_confident output)
  typedef struct packed {
    logic               valid;
    logic [TP_TAG_W-1:0] tag;
    logic [2:0]         br_type;
    logic [1:0]         age;
  } tp_entry_t;

  // ---- TAGE ----
  localparam int TN      = 4;                 // tagged tables (TN_MAX)
  localparam int TN_FH   = TN;
  localparam int T_IDX_W = 10;                // TAGE_IDX_WIDTH  (1024 entries)
  localparam int T_TAG_W = 8;                 // TAGE_TAG_WIDTH
  localparam int T_BASE_W = 10;               // base table index width (1024 entries)
  localparam int FH_W    = 11;                // widest folded history
  localparam int FH_K    = 3;                 // FH_N_MAX
  localparam int FH_FLAT = FH_K * TN_FH * FH_W;   // all folded histories as one vector
  localparam int PCPN_W  = 3;

  // ---- BTB ----
  localparam int B_WAYS  = 4;
  localparam int B_IDX_W = 8;
  localparam int B_TAG_W = 8;
  localparam int BHT_W   = 7;                 // 128 entries; the stored history is a uint8_t (8 bits) in the C++ model
  localparam int BHT_DW  = 8;
  localparam int TC_WAYS = 2;
  localparam int TC_IDX_W = 7;
  localparam int TC_TAG_W = 10;

  // ---- history / RAS ----
  localparam int GHR_W   = 119;               // only GHR[0..118] is ever read (FH update, ghr_length[3]-1)
  localparam int RAS_DEPTH = 32;
  localparam int RAS_PTR_W = 5;
  localparam int RAS_CNT_W = 6;
  // folded history lengths fh_length[k][i] and history lengths ghr_length[i] (BPU.h)
  function automatic int fh_len(input int k, input int i);
    if (k == 0) return (i == 0) ? 8 : 11;
    if (k == 1) return 8;
    return 7;
  endfunction
  function automatic int ghr_len(input int i);
    case (i)
      0: return 8;
      1: return 13;
      2: return 32;
      default: return 119;
    endcase
  endfunction

  // update-queue entry (BPU.h QueueEntry without the dead sc/loop fields and altpcpn; base pc kept as bank pc)
  typedef struct packed {
    logic [BPC_W-1:0]        bank_pc;
    logic                    actual_dir;
    logic [2:0]              br_type;
    logic [31:0]             target;
    logic                    pred_dir;
    logic                    alt_pred;
    logic [PCPN_W-1:0]       pcpn;
    logic [TN-1:0][T_TAG_W-1:0] tags;
    logic [TN-1:0][T_IDX_W-1:0] idxs;
  } uq_entry_t;

  // BTB_top.h hash_index_value(): x ^ x>>w ^ x>>2w ^ x>>3w (each only when k*w < 32) ^ salt; the caller masks
  function automatic logic [31:0] hash_fold(input logic [31:0] x, input int unsigned w, input logic [31:0] salt);
    logic [31:0] m;
    m = x;
    if (w < 32) m = m ^ (x >> w);
    if (2 * w < 32) m = m ^ (x >> (2 * w));
    if (3 * w < 32) m = m ^ (x >> (3 * w));
    return m ^ salt;
  endfunction

endpackage

`default_nettype wire
