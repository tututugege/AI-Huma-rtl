// Ref: back-end/PreIduQueue.cpp  ftq_train_meta_fifo[].meta.blk_id (BPA_REPAIR: BPU checkpoint record of the FTQ entry)
`default_nettype none

// BPU repair record of every FTQ entry: the history checkpoint (and epoch) of the fetch block, the BPU type of every
// slot and the block's base pc.  One write port (an allocation), one read port addressed by the FTQ index of the
// mispredicted branch: the slot of the branch is its pc relative to the block base, the type is the stored type of
// that slot.
module pre_idu_ftq_bpu import ttg_cfg_pkg::*; import bpu_pkg::BANK_W; import bpu_pkg::BANK_TOP;
  import front_pkg::BCK_W; import front_pkg::KIND_W;
  import bpu_stage_pkg::HCK_W; import bpu_stage_pkg::EPOCH_W; (
  input  logic                        clk,
  input  logic                        wr_en,
  input  logic [FTQ_IDX_WIDTH-1:0]    wr_idx,
  input  logic [BCK_W-1:0]            wr_bck,
  input  logic [FETCH_WIDTH-1:0][KIND_W-1:0] wr_kind,
  /* verilator lint_off UNUSEDSIGNAL */  // only the slot position inside the window matters to the record
  input  logic [XLEN_BITS-1:0]        wr_pc1,        // pc of slot 1 (slot 0 may start before the block)
  input  logic [FTQ_IDX_WIDTH-1:0]    rd_idx,
  input  logic [XLEN_BITS-1:0]        rd_br_pc,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [HCK_W-1:0]            rd_ck,
  output logic [EPOCH_W-1:0]          rd_epoch,
  output logic [2:0]                  rd_type
);

  typedef struct packed {
    logic [BCK_W-1:0]                   bck;
    logic [FETCH_WIDTH-1:0][KIND_W-1:0] kind;
    logic [BANK_TOP:SLOT_SHIFT]         base_rel;    // slot position of the block base (carried slot 0: -1)
  } rec_t;

  rec_t rec_q [FTQ_SIZE];
  rec_t rec;
  logic [BANK_TOP:SLOT_SHIFT] rel;
  logic [BANK_W-1:0]          slot;

  // Ref: comb: slot of the branch inside its block
  always_comb begin
    rec  = rec_q[rd_idx];
    rel  = rd_br_pc[BANK_TOP:SLOT_SHIFT] - rec.base_rel;
    // RVC=1: slot 0 may be an instruction carried over from the previous group (pc one slot below the base): its
    // checkpoint is that of the next block, so the BPU gets no exact repair for it (the model has no record either)
    slot = rel[BANK_TOP-1:SLOT_SHIFT];
    {rd_epoch, rd_ck} = rec.bck;
    rd_type = (&rel) ? 3'd7 : rec.kind[slot];   // carried slot 0: BR_NOREPAIR
  end

  always_ff @(posedge clk) begin
    if (wr_en) rec_q[wr_idx] <= '{bck: wr_bck, kind: wr_kind, base_rel: wr_pc1[BANK_TOP:SLOT_SHIFT] - (BANK_W + 1)'(1)};
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_pc;    // only the word position inside the 32-byte window of the pcs is needed
  assign unused_pc = ^{rd_br_pc[31:BANK_TOP+1], rd_br_pc[SLOT_SHIFT-1:0],
                       wr_pc1[31:BANK_TOP+1], wr_pc1[SLOT_SHIFT-1:0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
