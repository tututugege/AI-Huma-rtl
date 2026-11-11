// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::update_queue (storage, compaction, per-bank write ports)
`default_nettype none

// Update queue of the pipelined BPU: control instructions of the commit stream (UQ_DEPTH entries, a full queue drops
// the new entry).  Entries that are scheduled (bpu_updq_sched) leave the queue and appear on the per-bank write ports
// of the type predictor, the TAGE banks and the BTB / ITT banks in the SAME cycle; the others stay in order.
module bpu_updq import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  // commit lanes
  input  logic [NCOMMIT-1:0]  upd_valid,
  input  logic [XLEN_BITS-1:0]         base_pc    [NCOMMIT],
  input  logic [NCOMMIT-1:0]  actual_dir,
  input  logic [2:0]          br_type    [NCOMMIT],
  input  logic [XLEN_BITS-1:0]         target     [NCOMMIT],
  input  logic [NCOMMIT-1:0]  pred_dir,
  input  logic [NCOMMIT-1:0]  alt_pred,
  input  logic [PCPN_W-1:0]   pcpn       [NCOMMIT],
  input  logic [T_TAG_W-1:0]  tags       [NCOMMIT][TN],
  input  logic [T_IDX_W-1:0]  idxs       [NCOMMIT][TN],
  input  logic [NBB-1:0]      bank_busy,
  // table writes of this cycle, indexed by slot bank
  output logic [NBANK-1:0]    wr_valid,
  output upd_ent_t            wr_ent     [NBANK],
  output logic [3:0]          occ               // entries held at the start of the cycle (compact ROB credits)
);

  localparam int CNT_W = $clog2(UQ_DEPTH + 1);

  upd_ent_t            uq_q [UQ_DEPTH];
  upd_ent_t            uq_d [UQ_DEPTH];
  logic [CNT_W-1:0]    n_q;
  logic [CNT_W-1:0]    n_d;
  logic [UQ_DEPTH-1:0] ent_valid;
  logic [UQ_DEPTH-1:0] apply;
  logic [XLEN_BITS-1:0]         ent_pc  [UQ_DEPTH];
  logic [TN-1:0][T_IDX_W-1:0] ent_idx [UQ_DEPTH];
  upd_ent_t            lane_ent [NCOMMIT];
  logic [NCOMMIT-1:0]  lane_ctl;

  always_comb begin
    for (int i = 0; i < UQ_DEPTH; i++) begin
      ent_valid[i] = (CNT_W'(i) < n_q);
      ent_pc[i]    = uq_q[i].pc;
      ent_idx[i]   = uq_q[i].idx;
    end
    for (int l = 0; l < NCOMMIT; l++) begin
      lane_ctl[l]        = upd_valid[l] && (br_type[l] != BR_NONCTL);
      lane_ent[l].pc     = base_pc[l];
      lane_ent[l].dir    = actual_dir[l];
      lane_ent[l].pred   = pred_dir[l];
      lane_ent[l].alt    = alt_pred[l];
      lane_ent[l].ty     = br_type[l];
      lane_ent[l].tgt    = target[l];
      lane_ent[l].pcpn   = pcpn[l];
      for (int k = 0; k < TN; k++) begin
        lane_ent[l].tag[k] = tags[l][k];
        lane_ent[l].idx[k] = idxs[l][k];
      end
    end
  end

  bpu_updq_sched u_sched (.ent_valid, .ent_pc, .ent_idx, .bank_busy, .apply);

  // write ports: the applied entry of slot bank b
  always_comb begin
    wr_valid = '0;
    for (int b = 0; b < NBANK; b++) wr_ent[b] = '0;
    for (int i = 0; i < UQ_DEPTH; i++) begin
      if (apply[i]) begin
        wr_valid[uq_q[i].pc[BANK_W + 1:2]]  = 1'b1;
        wr_ent[uq_q[i].pc[BANK_W + 1:2]]    = uq_q[i];
      end
    end
  end

  // Ref: update_queue: keep the entries that did not write (in order), then append the new control entries
  always_comb begin
    int unsigned k;
    for (int i = 0; i < UQ_DEPTH; i++) uq_d[i] = uq_q[i];
    k = 0;
    for (int i = 0; i < UQ_DEPTH; i++) begin
      if (ent_valid[i] && !apply[i]) begin
        uq_d[k] = uq_q[i];
        k = k + 1;
      end
    end
    for (int l = 0; l < NCOMMIT; l++) begin
      if (lane_ctl[l] && k < UQ_DEPTH) begin
        uq_d[k] = lane_ent[l];
        k = k + 1;
      end
    end
    n_d = CNT_W'(k);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) n_q <= '0;
    else        n_q <= n_d;
  end
  always_comb begin
    occ = 4'(n_q);
  end

  for (genvar i = 0; i < UQ_DEPTH; i++) begin : g_entry
    always_ff @(posedge clk) uq_q[i] <= uq_d[i];
  end

endmodule

`default_nettype wire
