// Ref: back-end/PreIduQueue.cpp  Unified FTQ-64 ftq_lookup_entries[] (S0/S2/PD/Mispred 4-writer ring + FE/EXU/ROB/CM/DIS reads)
`default_nettype none

// Compact 8-bank Unified FTQ-64 PC & fetch-pair storage:
//   - 4 mutually-exclusive per-entry writers: S0 (bpu_ptr), S2 (s2_ptr), PD (pd_ptr), Mispred (mispred_idx).
//   - Registered frontend read views: ifu_ptr (+ ifu_ptr+1 6b set indices for L1I SRAM pre-launch) and pd_ptr.
//   - 4 random read ports for EXU/PRF (2 PC-ALU + 2 BRU).
//   - 1 shared 8-bank 8:1 sequential window (anchored at comm_ptr) for ROB head + 8 Commit ports.
//   - 1 shared 8-bank 8:1 sequential window (anchored at dis_idx[0]) for 8 Dispatch ports (32-bit PC only).
module ftq_pc import ttg_cfg_pkg::*; import ftq_ibuf_pkg::*; import front_pkg::fetch_pair_t; (
  input  logic                         clk,
  // 1. S0 allocate write port (at s0_idx)
  input  logic                         s0_wr_en,
  input  logic [FTQ_IDX_WIDTH-1:0]     s0_idx,
  input  logic [XLEN_BITS-1:0]         s0_addr,
  input  fetch_pair_t                  s0_pair,
  // 2. BPU S2 fill write port (at s2_idx; preserves S0 fetch_pair fields base_b/a_len/b_len/fa_pair_v)
  input  logic                         s2_wr_en,
  input  logic [FTQ_IDX_WIDTH-1:0]     s2_idx,
  input  logic                         s2_is_pair,
  input  logic [BACKEND_FETCH_WIDTH-1:0] s2_pred_dir,
  input  logic [XLEN_BITS-1:0]         s2_next_pc,
  // 3. Predecode in-place update write port (at pd_idx)
  input  logic                         pd_fire,
  input  logic [FTQ_IDX_WIDTH-1:0]     pd_idx,
  input  logic                         pd_carry,
  input  logic [XLEN_BITS-1:0]         pd_pc0,
  input  logic [BACKEND_FETCH_WIDTH-1:0] pd_pred_dir,
  input  logic [BACKEND_FETCH_WIDTH-1:0] pd_is_rvc,
  input  logic [XLEN_BITS-1:0]         pd_next_pc,
  input  logic [4:0]                   pd_nslots,
  // 4. Branch mispredict target fix-up (mutually exclusive with s0/s2/pd)
  input  logic                         mispred_en,
  input  logic [FTQ_IDX_WIDTH-1:0]     mispred_idx,
  input  logic [FTQ_OFFSET_WIDTH-1:0]  mispred_off,
  input  logic [XLEN_BITS-1:0]         mispred_target,
  // Frontend registered read pointers & outputs (pure reads of bank_q)
  input  logic [FTQ_IDX_WIDTH-1:0]     ifu_ptr,
  output logic [XLEN_BITS-1:0]         ifu_addr,
  output fetch_pair_t                  ifu_pair,
  output logic [5:0]                   ifu_next_fa_idx,
  output logic [5:0]                   ifu_next_b_idx,
  output logic [XLEN_BITS-1:0]         pd_base_pc,
  output logic                         pd_is_pair,
  output logic [XLEN_BITS-1:0]         pd_base_b,
  output logic [3:0]                   pd_a_len,
  output logic [BACKEND_FETCH_WIDTH-1:0] pd_out_pred_dir,
  output logic [XLEN_BITS-1:0]         pd_out_next_pc,
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
  input  logic [FTQ_IDX_WIDTH-1:0]     cm_idx [COMMIT_WIDTH],
  input  logic [FTQ_OFFSET_WIDTH-1:0]  cm_off [COMMIT_WIDTH],
  output logic [XLEN_BITS-1:0]         cm_pc [COMMIT_WIDTH],
  output logic                         cm_pred_taken [COMMIT_WIDTH],
  output logic                         cm_is_rvc [COMMIT_WIDTH],
  output logic [XLEN_BITS-1:0]         cm_next_pc [COMMIT_WIDTH],
  // Dispatch 8-wide read ports (8-bank 8:1 window, 32-bit PC for MDP/prefetchers)
  input  logic [FTQ_IDX_WIDTH-1:0]     dis_idx [DECODE_WIDTH],
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
    logic                           fa_pair_v;
    logic [3:0]                     b_len;
    logic                           carry;
    logic                           is_pair;
    logic [3:0]                     a_len;
    logic [BACKEND_FETCH_WIDTH-1:0] pred_taken;
    logic [BACKEND_FETCH_WIDTH-1:0] is_rvc;
    logic [XLEN_BITS-1:0]           next_pc;
    logic [4:0]                     nslots;
  } ftq_pc_ent_t;

  ftq_pc_ent_t bank_q [NB][NL];

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

  // ---- 0. Frontend registered read views (ifu_ptr, ifu_ptr+1 set indices, pd_ptr) ----
  always_comb begin
    /* verilator lint_off UNUSEDSIGNAL */
    ftq_pc_ent_t ie0, ie1, pe;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [FTQ_IDX_WIDTH-1:0] ifu_p1;
    ifu_p1          = ifu_ptr + FTQ_IDX_WIDTH'(1);
    ie0             = bank_q[ifu_ptr[BW-1:0]][ifu_ptr[FTQ_IDX_WIDTH-1:BW]];
    ie1             = bank_q[ifu_p1[BW-1:0]][ifu_p1[FTQ_IDX_WIDTH-1:BW]];
    pe              = bank_q[pd_idx[BW-1:0]][pd_idx[FTQ_IDX_WIDTH-1:BW]];
    ifu_addr        = ie0.pc0;
    ifu_pair        = '{valid: ie0.fa_pair_v, addr2: ie0.base_b, a_len: ie0.a_len, b_len: ie0.b_len};
    ifu_next_fa_idx = ie1.pc0[11:6];
    ifu_next_b_idx  = ie1.base_b[11:6];
    pd_base_pc      = pe.pc0;
    pd_is_pair      = pe.is_pair;
    pd_base_b       = pe.base_b;
    pd_a_len        = pe.a_len;
    pd_out_pred_dir = pe.pred_taken;
    pd_out_next_pc  = pe.next_pc;
  end

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

  // ---- 4. Mutually-exclusive per-entry writes (S0 / S2 / PD / Mispred) ----
  always_ff @(posedge clk) begin
    if (mispred_en) begin
      bank_q[mispred_idx[BW-1:0]][mispred_idx[FTQ_IDX_WIDTH-1:BW]].next_pc <= mispred_target;
      bank_q[mispred_idx[BW-1:0]][mispred_idx[FTQ_IDX_WIDTH-1:BW]].nslots  <= {1'b0, mispred_off} + 5'd1;
    end else begin
      if (s0_wr_en) begin
        bank_q[s0_idx[BW-1:0]][s0_idx[FTQ_IDX_WIDTH-1:BW]] <= '{
          pc0:        s0_addr,
          base_b:     s0_pair.addr2,
          fa_pair_v:  s0_pair.valid,
          b_len:      s0_pair.b_len,
          carry:      1'b0,
          is_pair:    s0_pair.valid,
          a_len:      s0_pair.a_len,
          pred_taken: '0,
          is_rvc:     '0,
          next_pc:    '0,
          nslots:     '0
        };
      end
      if (s2_wr_en) begin
        bank_q[s2_idx[BW-1:0]][s2_idx[FTQ_IDX_WIDTH-1:BW]].is_pair    <= s2_is_pair;
        bank_q[s2_idx[BW-1:0]][s2_idx[FTQ_IDX_WIDTH-1:BW]].pred_taken <= s2_pred_dir;
        bank_q[s2_idx[BW-1:0]][s2_idx[FTQ_IDX_WIDTH-1:BW]].next_pc    <= s2_next_pc;
      end
      if (pd_fire) begin
        bank_q[pd_idx[BW-1:0]][pd_idx[FTQ_IDX_WIDTH-1:BW]].pc0        <= pd_pc0;
        bank_q[pd_idx[BW-1:0]][pd_idx[FTQ_IDX_WIDTH-1:BW]].carry      <= pd_carry;
        bank_q[pd_idx[BW-1:0]][pd_idx[FTQ_IDX_WIDTH-1:BW]].pred_taken <= pd_pred_dir;
        bank_q[pd_idx[BW-1:0]][pd_idx[FTQ_IDX_WIDTH-1:BW]].is_rvc     <= pd_is_rvc;
        bank_q[pd_idx[BW-1:0]][pd_idx[FTQ_IDX_WIDTH-1:BW]].next_pc    <= pd_next_pc;
        bank_q[pd_idx[BW-1:0]][pd_idx[FTQ_IDX_WIDTH-1:BW]].nslots     <= pd_nslots;
      end
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk) !(s0_wr_en && s2_wr_en && (s0_idx == s2_idx)));
  assert property (@(posedge clk) !(s0_wr_en && pd_fire  && (s0_idx == pd_idx)));
  assert property (@(posedge clk) !(s2_wr_en && pd_fire  && (s2_idx == pd_idx)));
`endif

endmodule
`default_nettype wire
