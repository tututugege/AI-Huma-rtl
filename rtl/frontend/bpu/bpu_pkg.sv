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
  localparam logic [2:0] BR_ICALL   = 3'd6;   // jalr rd=ra: indirect target and RAS push of its own pc+4 (BPU_ACC)

  // ---- TAGE / folded-history widths ----
  localparam int TN      = 4;                 // tagged tables (TN_MAX)
  localparam int TN_FH   = TN;
  localparam int T_IDX_W = 10;                // TAGE_IDX_WIDTH  (1024 entries; also FTB blk_id width)
  localparam int FH_W    = 11;                // widest folded history
  localparam int FH_K    = 3;                 // FH_N_MAX
  localparam int PCPN_W  = 3;

  // ---- RAS ----
  localparam int RAS_DEPTH = 32;
  localparam int RAS_PTR_W = 5;
  localparam int RAS_CNT_W = 6;
  localparam int RASQ_N    = 64;              // slots of the speculative RAS queue (append-only)
  localparam int RASQ_W    = 6;

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

endpackage

`default_nettype wire
