// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::main_index (S0: index generation of the main predictor)
`default_nettype none

// Index record of every bank for the block that issues in S0: the slot of bank b is the block pc with pc[4:2] == b, its
// TAGE index / tag come from the speculative folded histories and the bank pc.  The records are registered with the
// block and address the arrays in S1.
module bpu_stage0 import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic [31:0]  base,
  input  fh_t          spec_fh,
  output tix_all_t     tix
);

  logic [31:0] slot_pc [NBANK];

  always_comb begin
    for (int b = 0; b < NBANK; b++) begin
      slot_pc[b] = base + 32'(4 * ((b - int'(base[BANK_W + 1:2])) & (NBANK - 1)));
      tix[b]     = tage_index(slot_pc[b][T_BASE_W + BANK_W + 2 - 1:BANK_W + 2], spec_fh);
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_low;     // the low pc bits are only needed for the bank position, not for the index
  assign unused_low = ^{slot_pc[0][BANK_W + 1:0], slot_pc[0][31:T_BASE_W + BANK_W + 2]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
