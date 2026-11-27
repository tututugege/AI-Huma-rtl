// Ref: front-end/BPU/BPU_configs.h  (shared BPU constants used by the FTB branch predictor)
`default_nettype none
/* verilator lint_off UNUSEDPARAM */
package bpu_pkg;
  import ttg_cfg_pkg::*;

  localparam int BANK_W  = $clog2(FETCH_WIDTH);
  localparam int NLANE   = FETCH_WIDTH;       // lanes of one fetch group (RVC=1: 16 two-byte slots)
  localparam int NCOMMIT = COMMIT_WIDTH;      // commit lanes (8)
  localparam int PC_W    = XLEN_BITS;

  // branch types (BPU_configs.h)
  localparam logic [2:0] BR_DIRECT  = 3'd0;   // conditional branch
  localparam logic [2:0] BR_CALL    = 3'd1;
  localparam logic [2:0] BR_RET     = 3'd2;
  localparam logic [2:0] BR_IDIRECT = 3'd3;
  localparam logic [2:0] BR_NONCTL  = 3'd4;
  localparam logic [2:0] BR_JAL     = 3'd5;
  localparam logic [2:0] BR_ICALL   = 3'd6;   // jalr rd=ra: indirect target and RAS push of its own pc+4

  // ---- TAGE / block-ID widths ----
  localparam int TN      = 4;                 // 1-Ahead TAGE tagged tables
  localparam int T_IDX_W = 10;                // FTB blk_id width (1024 sequence numbers)
  localparam int PCPN_W  = 3;

  // ---- RAS ----
  localparam int RAS_DEPTH = 32;
  localparam int RAS_PTR_W = 5;
  localparam int RAS_CNT_W = 6;
  localparam int RASQ_N    = 64;              // slots of the speculative RAS queue (append-only)
  localparam int RASQ_W    = 6;

endpackage
/* verilator lint_on UNUSEDPARAM */

`default_nettype wire
