// Ref: back-end/include/FTQ.h  FTQTrainMetaEntry; back-end/include/InstructionBuffer.h  InstructionBufferEntry
`default_nettype none

// waiver (reviewed): a package is linted standalone, where its constants and types look unused; they are used by the
// ftq_ibuf_* modules.
/* verilator lint_off UNUSEDPARAM */
package ftq_ibuf_pkg;
  import ttg_cfg_pkg::*;

  // ---- widths the reference model derives from front-end types that ttg_cfg_pkg does not export (wire_types.h) ----
  localparam int BLK_ID_W = 10;  // FTB block ID width (matches bpu_types_pkg::FTB_BLK_ID_W)
  localparam int PCPN_W = 3;  // pcpn_t

  // ---- derived sizes ----
  localparam int IB_IDX_W = $clog2(IDU_INST_BUFFER_SIZE);
  localparam int IB_COUNT_W = $clog2(IDU_INST_BUFFER_SIZE + 1);
  localparam int LANE_CNT_W = $clog2(BACKEND_FETCH_WIDTH + 1);
  localparam int DECODE_CNT_W = $clog2(DECODE_WIDTH + 1);

  // Per-slot training metadata (written when the fetch group enters the FTQ, read back at commit).
  typedef struct packed {
    logic                alt_pred;
    logic [PCPN_W-1:0]   pcpn;
  } ftq_meta_t;

  // Per-FTQ-entry compact training metadata: 15b block descriptor + 16 x 4b slot metadata = 79b/entry.
  typedef struct packed {
    logic [BLK_ID_W-1:0]                       blk_id;
    logic                                      is_pair;
    logic [3:0]                                a_len;
    ftq_meta_t [BACKEND_FETCH_WIDTH-1:0]       slots;
  } ftq_meta_entry_t;

  // One InstructionBuffer slot (valid is implied by the occupancy count; pc is dropped, only Idu dbg reads it).
  typedef struct packed {
    logic [31:0]                inst;
    logic                       page_fault_inst;
    logic                       pf_inst_hi;
    logic [FTQ_IDX_WIDTH-1:0]   ftq_idx;
    logic [FTQ_OFFSET_WIDTH-1:0] ftq_offset;
    logic                       ftq_is_last;
  } ib_entry_t;
endpackage
/* verilator lint_on UNUSEDPARAM */

`default_nettype wire
