// Ref: back-end/include/FTQ.h  FTQTrainMetaEntry; back-end/include/InstructionBuffer.h  InstructionBufferEntry
`default_nettype none

// waiver (reviewed): a package is linted standalone, where its constants and types look unused; they are used by the
// pre_idu_* modules.
/* verilator lint_off UNUSEDPARAM */
package pre_idu_pkg;
  import ttg_cfg_pkg::*;

  // ---- widths the reference model derives from front-end types that ttg_cfg_pkg does not export (wire_types.h) ----
  localparam int TAGE_N = 4;  // TN_MAX
  localparam int TAGE_IDX_W = 10;  // clog2(TN_ENTRY_NUM = 1024)
  localparam int TAGE_TAG_W = 8;  // TAGE_TAG_WIDTH
  localparam int PCPN_W = 3;  // pcpn_t
  localparam int SC_SUM_W = 16;  // tage_scl_meta_sum_t
  localparam int SC_IDX_W = BPU_SCL_META_IDX_BITS;
  localparam int LOOP_IDX_W = BPU_LOOP_META_IDX_BITS;
  localparam int LOOP_TAG_W = BPU_LOOP_META_TAG_BITS;

  // ---- derived sizes ----
  localparam int FTQ_COUNT_W = $clog2(FTQ_SIZE + 1);
  localparam int IB_IDX_W = $clog2(IDU_INST_BUFFER_SIZE);
  localparam int IB_COUNT_W = $clog2(IDU_INST_BUFFER_SIZE + 1);
  localparam int LANE_CNT_W = $clog2(BACKEND_FETCH_WIDTH + 1);
  localparam int COMMIT_CNT_W = $clog2(COMMIT_WIDTH + 1);
  localparam int DECODE_CNT_W = $clog2(DECODE_WIDTH + 1);

  // Training metadata of one fetch slot; written when the fetch group enters the FTQ, read back at commit.
  typedef struct packed {
    logic                                       alt_pred;
    logic [PCPN_W-1:0]                          pcpn;
    logic [TAGE_N-1:0][TAGE_IDX_W-1:0]          tage_idx;
    logic [TAGE_N-1:0][TAGE_TAG_W-1:0]          tage_tag;
  } ftq_meta_t;

  // One InstructionBuffer slot (valid is implied by the occupancy count; pc is dropped, only Idu dbg reads it).
  typedef struct packed {
    logic [31:0]                inst;
    logic                       page_fault_inst;
    logic [FTQ_IDX_WIDTH-1:0]   ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic                       ftq_is_last;
  } ib_entry_t;
endpackage
/* verilator lint_on UNUSEDPARAM */

`default_nettype wire
