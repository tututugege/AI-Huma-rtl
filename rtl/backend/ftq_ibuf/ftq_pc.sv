// Ref: back-end/PreIduQueue.cpp  ftq_lookup_entries[] (FTQEntry), ftq_pc() (2-taken discontinuity next_pc)
`default_nettype none

// Compact 8-bank FTQ PC storage:
//   - Compact per-entry PC representation: {pc0, base_b, carry, is_pair, a_len} = 134 bits/entry (-86.9% FFs).
//   - 4 random read ports for EXU/PRF (2 PC-ALU + 2 BRU).
//   - 1 shared 8-bank 8:1 sequential window (anchored at ftq_head) for ROB head + 8 Commit ports.
//   - 1 shared 8-bank 8:1 sequential window (anchored at dis_idx[0]) for 8 Dispatch ports (32-bit PC only).
module ftq_pc import ttg_cfg_pkg::*; import ftq_ibuf_pkg::*; (
  input  logic                         clk,
  input  logic                         wr_en,
  input  logic [FTQ_IDX_WIDTH-1:0]     wr_idx,
  input  logic [BACKEND_FETCH_WIDTH-1:0] wr_valid,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [XLEN_BITS-1:0]         wr_slot_pc [BACKEND_FETCH_WIDTH],
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [BACKEND_FETCH_WIDTH-1:0] wr_pred_taken,
  input  logic [BACKEND_FETCH_WIDTH-1:0] wr_is_rvc,
  input  logic                         wr_is_pair,
  input  logic [3:0]                   wr_a_len,
  input  logic [XLEN_BITS-1:0]         wr_next_pc,
  // Branch mispredict target fix-up (mutually exclusive with wr_en)
  input  logic                         mispred_en,
  input  logic [FTQ_IDX_WIDTH-1:0]     mispred_idx,
  input  logic [FTQ_OFFSET_WIDTH-1:0]  mispred_off,
  input  logic [XLEN_BITS-1:0]         mispred_target,
  // Oldest live FTQ index (anchor for 8-bank commit + ROB window)
  input  logic [FTQ_IDX_WIDTH-1:0]     ftq_head,
  // EXU/PRF random read ports (2 PC-ALU + 2 BRU = 4 ports)
  input  logic [FTQ_IDX_WIDTH-1:0]     prf_idx [FTQ_PRF_PC_PORT_NUM],
  input  logic [FTQ_OFFSET_WIDTH-1:0]  prf_off [FTQ_PRF_PC_PORT_NUM],
  output logic [XLEN_BITS-1:0]         prf_pc [FTQ_PRF_PC_PORT_NUM],
  output logic                         prf_pred_taken [FTQ_PRF_PC_PORT_NUM],
  output logic                         prf_is_rvc [FTQ_PRF_PC_PORT_NUM],
  output logic [XLEN_BITS-1:0]         prf_next_pc [FTQ_PRF_PC_PORT_NUM],
  // ROB head read port (reuses 8-bank commit window)
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [FTQ_IDX_WIDTH-1:0]     rob_idx,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [FTQ_OFFSET_WIDTH-1:0]  rob_off,
  output logic [XLEN_BITS-1:0]         rob_pc,
  output logic                         rob_is_rvc,
  // Commit 8-wide read ports (8-bank 8:1 window)
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [FTQ_IDX_WIDTH-1:0]     cm_idx [COMMIT_WIDTH],
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [FTQ_OFFSET_WIDTH-1:0]  cm_off [COMMIT_WIDTH],
  output logic [XLEN_BITS-1:0]         cm_pc [COMMIT_WIDTH],
  output logic                         cm_pred_taken [COMMIT_WIDTH],
  output logic                         cm_is_rvc [COMMIT_WIDTH],
  output logic [XLEN_BITS-1:0]         cm_next_pc [COMMIT_WIDTH],
  // Dispatch 8-wide read ports (8-bank 8:1 window, 32-bit PC for MDP/prefetchers)
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [FTQ_IDX_WIDTH-1:0]     dis_idx [DECODE_WIDTH],
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [FTQ_OFFSET_WIDTH-1:0]  dis_off [DECODE_WIDTH],
  output logic [31:0]                  dis_pc [DECODE_WIDTH],
  output logic                         dis_is_rvc [DECODE_WIDTH]
);

  localparam int NB = 8;
  localparam int NL = FTQ_SIZE / NB;
  localparam int BW = $clog2(NB);
  localparam int LW = $clog2(NL);

  typedef struct packed {
    logic [XLEN_BITS-1:0]           pc0;
    logic [XLEN_BITS-1:0]           base_b;
    logic                           carry;
    logic                           is_pair;
    logic [3:0]                     a_len;
    logic [BACKEND_FETCH_WIDTH-1:0] pred_taken;
    logic [BACKEND_FETCH_WIDTH-1:0] is_rvc;
    logic [XLEN_BITS-1:0]           next_pc;
    logic [4:0]                     nslots;
  } ftq_pc_ent_t;

  ftq_pc_ent_t bank_q [NB][NL];

  logic [4:0] wr_nslots;
  logic       wr_carry;
  always_comb begin
    wr_nslots = 5'd0;
    for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) if (wr_valid[i]) wr_nslots = 5'(i + 1);
    wr_carry = (!wr_is_pair || (wr_a_len > 4'd1)) &&
               (wr_slot_pc[1] != (wr_slot_pc[0] + XLEN_BITS'(SLOT_BYTES)));
  end

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [XLEN_BITS-1:0] ent_pc(
    input ftq_pc_ent_t                 e,
    input logic [FTQ_OFFSET_WIDTH-1:0] off
  );
    logic [XLEN_BITS-1:0] base;
    logic [4:0]           step;
    if (e.is_pair && (off >= e.a_len)) begin
      base = e.base_b;
      step = {1'b0, off - e.a_len};
    end else begin
      base = e.pc0;
      step = (off == '0) ? 5'd0 : ({1'b0, off} + {4'b0, e.carry});
    end
    return base + (XLEN_BITS'(step) << SLOT_SHIFT);
  endfunction

  function automatic logic [XLEN_BITS-1:0] ent_next_pc(
    input ftq_pc_ent_t                 e,
    input logic [FTQ_OFFSET_WIDTH-1:0] off,
    input logic [XLEN_BITS-1:0]        pc_cur
  );
    logic [4:0] off_p1;
    off_p1 = {1'b0, off} + 5'd1;
    if (e.pred_taken[off] && (off_p1 < e.nslots) &&
        e.is_pair && (off_p1 == {1'b0, e.a_len}) &&
        (e.base_b != (pc_cur + (e.is_rvc[off] ? XLEN_BITS'(2) : XLEN_BITS'(4)))))
      return e.base_b;
    else
      return e.next_pc;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- 1. EXU/PRF 4 random read ports ----
  always_comb begin
    for (int p = 0; p < FTQ_PRF_PC_PORT_NUM; p++) begin
      ftq_pc_ent_t e;
      logic [XLEN_BITS-1:0] pc_cur;
      e                 = bank_q[prf_idx[p][BW-1:0]][prf_idx[p][FTQ_IDX_WIDTH-1:BW]];
      pc_cur            = ent_pc(e, prf_off[p]);
      prf_pc[p]         = pc_cur;
      prf_pred_taken[p] = e.pred_taken[prf_off[p]];
      prf_is_rvc[p]     = e.is_rvc[prf_off[p]];
      prf_next_pc[p]    = ent_next_pc(e, prf_off[p], pc_cur);
    end
  end

  // ---- 2. Commit 8 + ROB 1 shared 8-bank 8:1 window (anchored at ftq_head) ----
  ftq_pc_ent_t cm_win [NB];
  always_comb begin
    logic [BW-1:0] hb;
    logic [LW-1:0] hl;
    hb = ftq_head[BW-1:0];
    hl = ftq_head[FTQ_IDX_WIDTH-1:BW];
    for (int b = 0; b < NB; b++) begin
      logic [LW-1:0] r;
      r         = (BW'(b) < hb) ? (hl + LW'(1)) : hl;
      cm_win[b] = bank_q[b][r];
    end
  end

  always_comb begin
    ftq_pc_ent_t re;
    re         = cm_win[rob_idx[BW-1:0]];
    rob_pc     = ent_pc(re, rob_off);
    rob_is_rvc = re.is_rvc[rob_off];
    for (int k = 0; k < COMMIT_WIDTH; k++) begin
      ftq_pc_ent_t ce;
      logic [XLEN_BITS-1:0] pc_cur;
      ce               = cm_win[cm_idx[k][BW-1:0]];
      pc_cur           = ent_pc(ce, cm_off[k]);
      cm_pc[k]         = pc_cur;
      cm_pred_taken[k] = ce.pred_taken[cm_off[k]];
      cm_is_rvc[k]     = ce.is_rvc[cm_off[k]];
      cm_next_pc[k]    = ent_next_pc(ce, cm_off[k], pc_cur);
    end
  end

  // ---- 3. Dispatch 8 shared 8-bank 8:1 window (anchored at dis_idx[0], 32-bit PC only) ----
  ftq_pc_ent_t dis_win [NB];
  always_comb begin
    logic [BW-1:0] db;
    logic [LW-1:0] dl;
    db = dis_idx[0][BW-1:0];
    dl = dis_idx[0][FTQ_IDX_WIDTH-1:BW];
    for (int b = 0; b < NB; b++) begin
      logic [LW-1:0] r;
      r          = (BW'(b) < db) ? (dl + LW'(1)) : dl;
      dis_win[b] = bank_q[b][r];
    end
  end

  always_comb begin
    for (int p = 0; p < DECODE_WIDTH; p++) begin
      /* verilator lint_off UNUSEDSIGNAL */
      ftq_pc_ent_t de;
      /* verilator lint_on UNUSEDSIGNAL */
      logic [31:0] base32;
      logic [4:0]  step;
      de            = dis_win[dis_idx[p][BW-1:0]];
      dis_is_rvc[p] = de.is_rvc[dis_off[p]];
      if (de.is_pair && (dis_off[p] >= de.a_len)) begin
        base32 = de.base_b[31:0];
        step   = {1'b0, dis_off[p] - de.a_len};
      end else begin
        base32 = de.pc0[31:0];
        step   = (dis_off[p] == '0) ? 5'd0 : ({1'b0, dis_off[p]} + {4'b0, de.carry});
      end
      dis_pc[p] = base32 + (32'(step) << SLOT_SHIFT);
    end
  end

  // ---- Write / mispredict fix-up ----
  always_ff @(posedge clk) begin
    if (wr_en) begin
      bank_q[wr_idx[BW-1:0]][wr_idx[FTQ_IDX_WIDTH-1:BW]] <= '{
        pc0:        wr_slot_pc[0],
        base_b:     wr_slot_pc[wr_a_len],
        carry:      wr_carry,
        is_pair:    wr_is_pair,
        a_len:      wr_a_len,
        pred_taken: wr_pred_taken,
        is_rvc:     wr_is_rvc,
        next_pc:    wr_next_pc,
        nslots:     wr_nslots
      };
    end else if (mispred_en) begin
      bank_q[mispred_idx[BW-1:0]][mispred_idx[FTQ_IDX_WIDTH-1:BW]].next_pc <= mispred_target;
      bank_q[mispred_idx[BW-1:0]][mispred_idx[FTQ_IDX_WIDTH-1:BW]].nslots  <= {1'b0, mispred_off} + 5'd1;
    end
  end

`ifndef SYNTHESIS
  logic [BACKEND_FETCH_WIDTH-1:0] pc_chk_ok;
  always_comb begin
    for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) begin
      logic [4:0]           st_dbg;
      logic [XLEN_BITS-1:0] exp_pc_dbg;
      if (wr_is_pair && (4'(i) >= wr_a_len)) begin
        st_dbg     = {1'b0, 4'(i) - wr_a_len};
        exp_pc_dbg = wr_slot_pc[wr_a_len] + (XLEN_BITS'(st_dbg) << SLOT_SHIFT);
      end else begin
        st_dbg     = (i == 0) ? 5'd0 : (5'(i) + {4'b0, wr_carry});
        exp_pc_dbg = wr_slot_pc[0] + (XLEN_BITS'(st_dbg) << SLOT_SHIFT);
      end
      pc_chk_ok[i] = !wr_en || !wr_valid[i] || (exp_pc_dbg == wr_slot_pc[i]);
    end
  end
  assert property (@(posedge clk) (&pc_chk_ok));
`endif

endmodule
`default_nettype wire
