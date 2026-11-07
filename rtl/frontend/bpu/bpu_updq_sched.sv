// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::update_queue (scheduling of the table writes, block-bank mode)
`default_nettype none

// Which queue entries write the tables this cycle.  The queue is scanned from the oldest entry (the head).  An entry
// leads a write when fewer than UQ_PORTS writes were granted, its block bank is not read by the block in S1, no earlier
// leader of this cycle writes the same block bank, and its slot bank is free.  A leader pulls later entries of the same
// 32-byte window and the same TAGE indices into the same write (one more entry per free slot bank).
module bpu_updq_sched import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic [UQ_DEPTH-1:0]  ent_valid,
  input  logic [31:0]          ent_pc  [UQ_DEPTH],
  input  logic [TN-1:0][T_IDX_W-1:0] ent_idx [UQ_DEPTH],
  input  logic [NBB-1:0]       bank_busy,          // block banks read by the block in S1
  output logic [UQ_DEPTH-1:0]  apply
);

  localparam int NW_W = $clog2(UQ_PORTS + 1);

  // Ref: update_queue, loop over the queue entries
  always_comb begin
    logic [NW_W-1:0]  nw;
    logic [NBANK-1:0] slot_used;
    logic [NBB-1:0]   bb_written;
    logic [UQ_DEPTH-1:0] done;
    nw = '0; slot_used = '0; bb_written = '0; done = '0;
    apply = '0;
    for (int qi = 0; qi < UQ_DEPTH; qi++) begin
      if (ent_valid[qi] && !done[qi] && nw < NW_W'(UQ_PORTS) && !bank_busy[ent_pc[qi][6:5]] &&
          !bb_written[ent_pc[qi][6:5]] && !slot_used[ent_pc[qi][4:2]]) begin
        apply[qi] = 1'b1;
        slot_used[ent_pc[qi][4:2]] = 1'b1;
        bb_written[ent_pc[qi][6:5]] = 1'b1;
        nw = nw + NW_W'(1);
        for (int qj = qi + 1; qj < UQ_DEPTH; qj++) begin
          if (ent_valid[qj] && !done[qj] && ent_pc[qj][31:5] == ent_pc[qi][31:5] &&
              !slot_used[ent_pc[qj][4:2]] && ent_idx[qj] == ent_idx[qi]) begin
            apply[qj] = 1'b1;
            slot_used[ent_pc[qj][4:2]] = 1'b1;
            done[qj] = 1'b1;
          end
        end
      end
    end
  end

endmodule

`default_nettype wire
