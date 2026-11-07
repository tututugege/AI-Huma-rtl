// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::ub_track (commit-order fetch-block tracker, taken-path history mode)
`default_nettype none

// Follows the committed instruction stream and reconstructs the fetch block each instruction belonged to; produces the
// train events of the uBTB / L1 (one per commit lane at most), in program order.
//   new block: after a taken control instruction (at its target), after a conditional branch predicted taken but not
//   taken (at pc+4), at the block boundary, and at any pc discontinuity.
module bpu_ub_track import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  input  logic [NCOMMIT-1:0]  upd_valid,
  input  logic [31:0]         base_pc  [NCOMMIT],
  input  logic [2:0]          br_type  [NCOMMIT],
  input  logic [NCOMMIT-1:0]  actual_dir,
  input  logic [NCOMMIT-1:0]  pred_dir,
  input  logic [31:0]         target   [NCOMMIT],
  output logic [NCOMMIT-1:0]  ev_valid,
  output ub_ev_t              ev       [NCOMMIT]
);

  localparam logic [1:0] EV_TAKEN = 2'd0;
  localparam logic [1:0] EV_FALL  = 2'd1;
  localparam logic [1:0] EV_NTSLOT = 2'd2;

  logic        tr_v_q, tr_v_d;
  logic [31:0] tr_start_q, tr_start_d;
  logic [31:0] tr_expect_q, tr_expect_d;
  logic        tr_cond_q, tr_cond_d;        // a conditional branch was seen in the current block

  // Ref: ub_track, loop over the commit lanes (state carried lane to lane)
  always_comb begin
    logic        v;
    logic [31:0] start;
    logic [31:0] expect_pc;
    logic        cond;
    logic [31:0] bnd;
    logic        taken;
    logic [31:0] nxt;
    v = tr_v_q; start = tr_start_q; expect_pc = tr_expect_q; cond = tr_cond_q;
    ev_valid = '0; bnd = '0; taken = 1'b0; nxt = '0;
    for (int i = 0; i < NCOMMIT; i++) begin
      ev[i] = '0;
      if (upd_valid[i]) begin
        if (!v || base_pc[i] != expect_pc || base_pc[i] >= block_bnd(start)) begin
          v = 1'b1; start = base_pc[i]; cond = 1'b0;
        end
        bnd   = block_bnd(start);
        taken = (br_type[i] != BR_NONCTL) && actual_dir[i];
        nxt   = base_pc[i] + 32'd4;
        cond  = cond || (br_type[i] == BR_DIRECT);
        ev[i].start = start[31:2];
        ev[i].slot  = 3'((base_pc[i] - start) >> 2);
        ev[i].ty    = br_type[i];
        if (taken) begin
          ev_valid[i] = 1'b1; ev[i].kind = EV_TAKEN; ev[i].tgt = target[i][31:2];
          start = target[i]; cond = 1'b0; expect_pc = target[i];
        end else begin
          if (br_type[i] == BR_DIRECT && pred_dir[i]) begin
            ev_valid[i] = 1'b1; ev[i].kind = EV_NTSLOT;
            start = nxt; cond = 1'b0;
          end else if (nxt >= bnd) begin
            ev_valid[i] = cond; ev[i].kind = EV_FALL;
            start = nxt; cond = 1'b0;
          end
          expect_pc = nxt;
        end
      end
    end
    tr_v_d = v; tr_start_d = start; tr_expect_d = expect_pc; tr_cond_d = cond;
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
