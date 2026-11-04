// Ref: back-end/Dispatch.cpp  Dispatch::comb_wake
`default_nettype none

// Source-operand busy bits of the dispatch group: busy-table read, same-cycle wakeup, and the
// intra-group RAW rule (a source whose preg is written by an older lane of this group is busy).
module dispatch_src_busy
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  logic [PRF_NUM-1:0] busy_table,
  input  dis_inst_t          inst      [NUM_SLOTS],
  input  logic [NUM_SLOTS-1:0] inst_valid,
  input  logic [NUM_SLOTS-1:0] woken1,
  input  logic [NUM_SLOTS-1:0] woken2,
  output logic [NUM_SLOTS-1:0] busy1,
  output logic [NUM_SLOTS-1:0] busy2
);

  logic [NUM_SLOTS-1:0] dest_written;   // valid lane writes a real (non-x0) destination

  always_comb begin
    for (int i = 0; i < NUM_SLOTS; i++) begin
      dest_written[i] = inst_valid[i] && inst[i].dest_en && (inst[i].dest_areg != '0);
    end
  end

  for (genvar i = 0; i < NUM_SLOTS; i++) begin : g_lane
    logic older_writes_src1;
    logic older_writes_src2;
    // Ref: Dispatch::comb_wake inner loop over j < i
    always_comb begin
      older_writes_src1 = 1'b0;
      older_writes_src2 = 1'b0;
      for (int j = 0; j < i; j++) begin
        older_writes_src1 = older_writes_src1 || (dest_written[j] && (inst[i].src1_preg == inst[j].dest_preg));
        older_writes_src2 = older_writes_src2 || (dest_written[j] && (inst[i].src2_preg == inst[j].dest_preg));
      end
    end
    // a lane that fires is the only one whose busy bits reach an IQ; held lanes re-derive them next cycle
    always_comb begin
      busy1[i] = inst[i].src1_en && ((busy_table[inst[i].src1_preg] && !woken1[i]) || older_writes_src1);
      busy2[i] = inst[i].src2_en && ((busy_table[inst[i].src2_preg] && !woken2[i]) || older_writes_src2);
    end
  end

endmodule

`default_nettype wire
