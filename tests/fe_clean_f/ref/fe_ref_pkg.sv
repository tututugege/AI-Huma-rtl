// Types of the pre-cleanup-F front end (2026-11-29, rtl HEAD 3834bbe), used only by the reference copies in this
// directory: the old inst_fifo entry (raw A + raw B halfwords) and the old 3-slot RAS write overlay of bpu_spec.
`default_nettype none
package fe_ref_pkg;
  import ttg_cfg_pkg::*;
  import bpu_stage_pkg::rptr_t;
  import bpu_pkg::*;

  typedef struct packed {
    logic                         is_straddle;
    logic [3:0]                   a_len;
    logic [XLEN_BITS-1:0]         base_a;
    logic [FETCH_WIDTH-1:0]       valid_a;
    logic [FETCH_WIDTH-1:0]       pf_a;
    logic                         single_word_a;
    logic [FETCH_WIDTH-1:0][15:0] raw_a;
    logic [15:0]                  up16_a;
    logic                         b_ok;
    logic [4:0]                   b_actual_n;
    logic [FETCH_WIDTH-1:0][15:0] raw_b;
    logic [15:0]                  up16_b;
  } fe_ref_inst_fifo_entry_t;

  typedef struct packed {
    logic                       arch;
    logic [2:0]                 w;
    logic [2:0][RASQ_W-1:0]     idx;
    logic [2:0][XLEN_BITS-1:0]  val;
    logic [2:0][RASQ_W-1:0]     nos;
  } fe_ref_rov_t;

  typedef struct packed { rptr_t p; fe_ref_rov_t o; } fe_ref_rst_t;
endpackage
`default_nettype wire
