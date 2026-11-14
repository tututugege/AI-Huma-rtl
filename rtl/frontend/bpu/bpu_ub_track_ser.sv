// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::ub_track (RVC=1: lane-serial form)
`default_nettype none

// RVC=1 form of bpu_ub_track: the same commit-order block tracker, written as the lane loop of the model.  With
// 16-bit instructions a sequential block end can lie inside an instruction (it straddles the end): the next block then
// starts at the block end, not at the next pc, and the following lane is still the continuation (tr_expect = next pc).
// The block start of the following lane therefore depends on the block end of the current one, which is why this
// form is serial over the lanes (the RVC=0 module resolves the lanes in parallel).
module bpu_ub_track_ser import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  input  logic [NCOMMIT-1:0]  upd_valid,
  input  logic [XLEN_BITS-1:0]         base_pc  [NCOMMIT],
  input  logic [2:0]          br_type  [NCOMMIT],
  input  logic [NCOMMIT-1:0]  actual_dir,
  input  logic [NCOMMIT-1:0]  upd_is_rvc,
  input  logic [NCOMMIT-1:0]  pred_dir,
  input  logic [XLEN_BITS-1:0]         target   [NCOMMIT],
  output logic [NCOMMIT-1:0]  ev_valid,
  output ub_ev_t              ev       [NCOMMIT]
);

  localparam logic [1:0] EV_TAKEN = 2'd0;
  localparam logic [1:0] EV_FALL  = 2'd1;
  localparam logic [1:0] EV_NTSLOT = 2'd2;

  logic                 tr_v_q, tr_v_d;
  logic [XLEN_BITS-1:0] tr_start_q, tr_expect_q, tr_start_d, tr_expect_d;
  logic                 tr_cond_q, tr_cond_d;   // a conditional branch was seen in the block (tr_nd > 0)

  always_comb begin
    logic                 v, cond, taken, ntslot, is_dir;
    logic [XLEN_BITS-1:0] start, expct, bnd, nxt, pc;
    v     = tr_v_q;
    start = tr_start_q;
    expct = tr_expect_q;
    cond  = tr_cond_q;
    ev_valid = '0;
    for (int i = 0; i < NCOMMIT; i++) begin
      ev[i]  = '0;
      pc     = base_pc[i];
      bnd    = block_bnd(start);
      is_dir = 1'b0; taken = 1'b0; ntslot = 1'b0;
      nxt    = pc;
      if (upd_valid[i]) begin
        if (!v || pc != expct || pc >= block_bnd(start)) begin
          v = 1'b1; start = pc; cond = 1'b0;
        end
        bnd    = block_bnd(start);
        is_dir = (br_type[i] == BR_DIRECT);
        taken  = (br_type[i] != BR_NONCTL) && actual_dir[i];
        ntslot = !taken && is_dir && pred_dir[i];
        nxt    = pc + (upd_is_rvc[i] ? XLEN_BITS'(2) : XLEN_BITS'(4));
        if (is_dir) cond = 1'b1;
        ev[i].start = start[31:SLOT_SHIFT];
        ev[i].slot  = UB_SLOT_W'((pc - start) >> SLOT_SHIFT);
        ev[i].ty    = br_type[i];
        if (taken) begin
          ev_valid[i] = 1'b1; ev[i].kind = EV_TAKEN; ev[i].tgt = target[i][XLEN_BITS-1:SLOT_SHIFT];
          ev[i].rvc = upd_is_rvc[i];
          start = target[i]; cond = 1'b0; expct = target[i];
        end else begin
          if (ntslot) begin
            ev_valid[i] = 1'b1; ev[i].kind = EV_NTSLOT;
            start = nxt; cond = 1'b0;
          end else if (nxt >= bnd) begin
            ev_valid[i] = cond; ev[i].kind = EV_FALL;
            start = bnd; cond = 1'b0;
          end
          expct = nxt;
        end
      end
    end
    tr_v_d      = v;
    tr_start_d  = start;
    tr_expect_d = expct;
    tr_cond_d   = cond;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tr_v_q      <= 1'b0;
      tr_start_q  <= '0;
      tr_expect_q <= '0;
      tr_cond_q   <= 1'b0;
    end else begin
      tr_v_q      <= tr_v_d;
      tr_start_q  <= tr_start_d;
      tr_expect_q <= tr_expect_d;
      tr_cond_q   <= tr_cond_d;
    end
  end

endmodule

`default_nettype wire
