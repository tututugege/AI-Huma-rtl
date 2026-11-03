// Ref: back-end/Exu/include/AbstractFU.h  IterativeFU (busy / done_cycle / comb_ctrl / comb_issue / comb_consume)
`default_nettype none

// Control skeleton of a non-pipelined multi-cycle FU (DIV; the FPU reuses it with a per-op latency).  One uop at a
// time: `accept` loads the uop, the FU stays busy for `lat_m1 + 1` cycles, complete stays high until the Exu consumes
// the result.  `cnt` is the C++ `done_cycle - sim_time` (the accept cycle has done - now = latency, the next cycle
// latency - 1, ...); complete means cnt == 0.  Per cycle:
//   1. kill     : flush removes the in-flight uop (all-ones flush_mask, or a shared br_mask bit)
//   2. clear    : clear_mask bits are removed from the in-flight uop's br_mask
//   3. accept   : en loads a new uop if the FU is not busy *before* this cycle's consume
//   4. complete : the in-flight uop has reached cnt == 0; consume releases the FU
//   5. ready    : the FU is idle after consume and accept
// `run` tells the datapath to advance one iteration (busy and not yet finished).
module exu_iter_ctl
  import ttg_cfg_pkg::*;
#(
  parameter int CW = 4                      // width of the latency counter: latency <= 2**CW
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     flush,
  input  logic [BR_MASK_WIDTH-1:0] flush_mask,
  input  logic [BR_MASK_WIDTH-1:0] clear_mask,
  input  logic                     en,
  input  logic                     consume,
  input  logic [CW-1:0]            lat_m1,    // latency - 1 of the uop being accepted (cycles still to wait next cycle)
  input  logic [BR_MASK_WIDTH-1:0] en_br_mask,
  output logic                     accept,
  output logic                     run,
  output logic                     complete,
  output logic                     ready,
  output logic [BR_MASK_WIDTH-1:0] done_br_mask
);

  logic                     busy_q, busy_d;
  logic [CW-1:0]            cnt_q, cnt_d;
  logic [BR_MASK_WIDTH-1:0] br_mask_q, br_mask_d;

  logic kill, live, pop, finished;

  // Ref: IterativeFU::comb_ctrl / comb_issue / comb_consume
  always_comb begin
    kill     = busy_q && flush && ((&flush_mask) || (|(br_mask_q & flush_mask)));
    live     = busy_q && !kill;
    finished = (cnt_q == '0);
    complete = live && finished;
    accept   = en && !live;                       // busy is tested before consume releases the FU
    pop      = consume && complete;
    run      = live && !finished;
    done_br_mask = br_mask_q & ~clear_mask;       // the uop shown at complete has seen this cycle's clear

    busy_d    = accept || (live && !pop);
    cnt_d     = accept ? lat_m1 : (finished ? '0 : cnt_q - CW'(1));
    br_mask_d = accept ? en_br_mask : done_br_mask;
    ready     = !busy_d;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      busy_q    <= 1'b0;
      cnt_q     <= '0;
      br_mask_q <= '0;
    end else begin
      busy_q    <= busy_d;
      cnt_q     <= cnt_d;
      br_mask_q <= br_mask_d;
    end
  end

endmodule

`default_nettype wire
