// Ref: front-end/BPU/BPU.h  BPU_TOP::bpu_queue_comb (update queue, Q_DEPTH=2, one queue per bank)
`default_nettype none

// Commit-update queue of the BPU.  In the C++ every bank pops its head EVERY cycle and pushes at most one entry, so
// the occupancy never exceeds 1 (checked on real programs, qmax=1, and by induction): the queue is a one-entry
// register per bank, and the "full" condition / write pointers are unreachable.
// Push rule (kept exactly): of the valid commit lanes, only the FIRST lane that maps to a bank (bank = pc[4:2]) is
// accepted that cycle, later lanes of the same bank are DROPPED (bank_enqueued).  The accepted entry is visible at
// the output in the NEXT cycle, where it feeds the TAGE (br_type == DIRECT only) and BTB update ports.
// Outputs are zero when no entry is present (like the C++ update-request structs).
module bpu_uq import bpu_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  // commit lanes (BPU InputPayload in_upd_*)
  input  logic                upd_valid    [NCOMMIT],
  input  logic [31:0]         base_pc      [NCOMMIT],
  input  logic                actual_dir   [NCOMMIT],
  input  logic [2:0]          br_type      [NCOMMIT],
  input  logic [31:0]         target       [NCOMMIT],
  input  logic                pred_dir     [NCOMMIT],
  input  logic                alt_pred     [NCOMMIT],
  input  logic [PCPN_W-1:0]   pcpn         [NCOMMIT],
  input  logic [T_TAG_W-1:0]  tags         [NCOMMIT][TN],
  input  logic [T_IDX_W-1:0]  idxs         [NCOMMIT][TN],
  // per-bank queue head = BTB / TAGE update inputs of this cycle
  output logic                q_valid      [NBANK],
  output logic [BPC_W-1:0]    q_pc         [NBANK],
  output logic [31:0]         q_target     [NBANK],
  output logic [2:0]          q_br_type    [NBANK],
  output logic                q_dir        [NBANK],
  output logic                tage_en      [NBANK],
  output logic                q_pred_dir   [NBANK],
  output logic                q_alt_pred   [NBANK],
  output logic [PCPN_W-1:0]   q_pcpn       [NBANK],
  output logic [T_TAG_W-1:0]  q_tags       [NBANK][TN],
  output logic [T_IDX_W-1:0]  q_idxs       [NBANK][TN]
);

  localparam int EW = $bits(uq_entry_t);

  uq_entry_t          lane_entry [NCOMMIT];
  logic [EW-1:0]      lane_bits  [NCOMMIT];

  always_comb begin
    for (int l = 0; l < NCOMMIT; l++) begin
      lane_entry[l].bank_pc    = base_pc[l][31:BANK_W];
      lane_entry[l].actual_dir = actual_dir[l];
      lane_entry[l].br_type    = br_type[l];
      lane_entry[l].target     = target[l];
      lane_entry[l].pred_dir   = pred_dir[l];
      lane_entry[l].alt_pred   = alt_pred[l];
      lane_entry[l].pcpn       = pcpn[l];
      for (int t = 0; t < TN; t++) begin
        lane_entry[l].tags[t] = tags[l][t];
        lane_entry[l].idxs[t] = idxs[l][t];
      end
      lane_bits[l] = lane_entry[l];
    end
  end

  for (genvar b = 0; b < NBANK; b++) begin : g_bank
    logic [NCOMMIT-1:0] lane_to_bank;     // valid lanes whose pc maps to this bank
    logic [NCOMMIT-1:0] first_lane;       // the accepted lane (lowest index)
    logic               push;
    logic [EW-1:0]      push_bits;
    logic               valid_q;
    logic               valid_d;
    uq_entry_t          head_q;
    uq_entry_t          head_d;
    logic [EW-1:0]      head_bits_d;

    always_comb begin
      for (int l = 0; l < NCOMMIT; l++)
        lane_to_bank[l] = upd_valid[l] && (base_pc[l][BANK_W + 1:2] == BANK_W'(b));
    end

    ttg_first_set #(.N(NCOMMIT)) u_first (.req(lane_to_bank), .onehot(first_lane), .any(push));
    ttg_onehot_mux #(.N(NCOMMIT), .W(EW)) u_mux (.sel(first_lane), .data(lane_bits), .out(push_bits));

    always_comb begin
      valid_d     = push;            // the head is popped every cycle; a push becomes next cycle's head
      head_bits_d = push ? push_bits : EW'(head_q);
      head_d      = uq_entry_t'(head_bits_d);
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        valid_q <= 1'b0;
        head_q  <= '0;
      end else begin
        valid_q <= valid_d;
        head_q  <= head_d;
      end
    end

    always_comb begin
      q_valid[b]   = valid_q;
      q_pc[b]      = valid_q ? head_q.bank_pc : '0;
      q_target[b]  = valid_q ? head_q.target : '0;
      q_br_type[b] = valid_q ? head_q.br_type : '0;
      q_dir[b]     = valid_q && head_q.actual_dir;
      tage_en[b]   = valid_q && (head_q.br_type == BR_DIRECT);
      q_pred_dir[b] = tage_en[b] && head_q.pred_dir;
      q_alt_pred[b] = tage_en[b] && head_q.alt_pred;
      q_pcpn[b]    = tage_en[b] ? head_q.pcpn : '0;
      for (int t = 0; t < TN; t++) begin
        q_tags[b][t] = tage_en[b] ? head_q.tags[t] : '0;
        q_idxs[b][t] = tage_en[b] ? head_q.idxs[t] : '0;
      end
    end
  end

endmodule

`default_nettype wire
