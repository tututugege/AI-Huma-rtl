// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::update_queue (scheduling of the table writes, block-bank mode)
`default_nettype none

// Which queue entries write the tables this cycle (two leader writes per cycle, UQ_PORTS = 2).  Same decision as the
// sequential scan of the C++ model, written as two parallel stages:
//   leader 1   the oldest valid entry whose block bank is not read by the block in S1;
//   group 1    leader 1 plus the later entries of the same 32-byte window and the same TAGE indices whose slot bank is
//              not taken by an earlier member (the first entry of each bank wins);
//   leader 2   the oldest valid entry outside group 1 whose block bank is free, different from leader 1's, and whose
//              slot bank is not used by group 1;  group 2 as group 1, also avoiding the slot banks of group 1.
module bpu_updq_sched import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic [UQ_DEPTH-1:0]  ent_valid,
  input  logic [31:0]          ent_pc  [UQ_DEPTH],
  input  logic [TN-1:0][T_IDX_W-1:0] ent_idx [UQ_DEPTH],
  input  logic [NBB-1:0]       bank_busy,          // block banks read by the block in S1
  output logic [UQ_DEPTH-1:0]  apply
);

  logic [UQ_DEPTH-1:0] elig1, lead1, cand1, drop1, elig2, lead2, cand2, drop2;
  /* verilator lint_off UNUSEDSIGNAL */
  logic                any1, any2;      // no leader <=> the one-hot is zero: not needed
  /* verilator lint_on UNUSEDSIGNAL */
  logic [NBANK-1:0]    used1;
  logic [26:0]         win1, win2;
  logic [NBB-1:0]      wb1;
  logic [TN-1:0][T_IDX_W-1:0] idx1, idx2;
  logic [UQ_DEPTH-1:0] after1, after2;     // entries younger than the leader

  // Ref: update_queue, first leader
  always_comb begin
    for (int i = 0; i < UQ_DEPTH; i++) elig1[i] = ent_valid[i] && !bank_busy[ent_pc[i][6:5]];
  end
  ttg_first_set #(.N(UQ_DEPTH)) u_lead1 (.req(elig1), .onehot(lead1), .any(any1));

  // Ref: update_queue, merge of the same window / TAGE indices into the leader's write
  always_comb begin
    win1 = '0; idx1 = '0; wb1 = '0; after1 = '0;
    for (int i = 0; i < UQ_DEPTH; i++) begin
      if (lead1[i]) begin
        win1 = ent_pc[i][31:5]; idx1 = ent_idx[i]; wb1 = NBB'(1) << ent_pc[i][6:5];
      end
      after1[i] = |(lead1 & ((UQ_DEPTH'(1) << i) - UQ_DEPTH'(1)));
    end
    for (int j = 0; j < UQ_DEPTH; j++) begin
      cand1[j] = lead1[j] || (after1[j] && ent_valid[j] && ent_pc[j][31:5] == win1 && ent_idx[j] == idx1);
    end
    for (int j = 0; j < UQ_DEPTH; j++) begin
      drop1[j] = 1'b0;
      for (int m = 0; m < j; m++) if (cand1[m] && ent_pc[m][4:2] == ent_pc[j][4:2]) drop1[j] = 1'b1;
    end
    used1 = '0;
    for (int j = 0; j < UQ_DEPTH; j++) if (cand1[j] && !drop1[j]) used1[ent_pc[j][4:2]] = 1'b1;
  end

  // Ref: update_queue, second leader (block bank and slot banks must be free)
  always_comb begin
    for (int k = 0; k < UQ_DEPTH; k++) begin
      elig2[k] = ent_valid[k] && !(cand1[k] && !drop1[k]) && !bank_busy[ent_pc[k][6:5]] &&
                 !wb1[ent_pc[k][6:5]] && !used1[ent_pc[k][4:2]];
    end
  end
  ttg_first_set #(.N(UQ_DEPTH)) u_lead2 (.req(elig2), .onehot(lead2), .any(any2));

  always_comb begin
    win2 = '0; idx2 = '0; after2 = '0;
    for (int i = 0; i < UQ_DEPTH; i++) begin
      if (lead2[i]) begin
        win2 = ent_pc[i][31:5]; idx2 = ent_idx[i];
      end
      after2[i] = |(lead2 & ((UQ_DEPTH'(1) << i) - UQ_DEPTH'(1)));
    end
    for (int j = 0; j < UQ_DEPTH; j++) begin
      cand2[j] = lead2[j] || (after2[j] && ent_valid[j] && !(cand1[j] && !drop1[j]) && ent_pc[j][31:5] == win2 &&
                              ent_idx[j] == idx2 && !used1[ent_pc[j][4:2]]);
    end
    for (int j = 0; j < UQ_DEPTH; j++) begin
      drop2[j] = 1'b0;
      for (int m = 0; m < j; m++) if (cand2[m] && ent_pc[m][4:2] == ent_pc[j][4:2]) drop2[j] = 1'b1;
    end
    apply = (cand1 & ~drop1) | (cand2 & ~drop2);
  end

endmodule

`default_nettype wire
