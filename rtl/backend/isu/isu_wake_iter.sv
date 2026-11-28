// Ref: back-end/Isu.cpp  Isu::comb_calc_latency_next / comb_flush (fp_wake_slots)
`default_nettype none

// Countdown wake-up slots of one FP-capable issue port: at most one request per cycle goes into the first free slot.
module isu_wake_iter
  import ttg_cfg_pkg::*;
  import isu_pkg::*;
#(
  parameter int SLOTS = 2,
  parameter int CW    = COUNT_W,
  parameter int CN_W  = LSU_LDU_COUNT
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     req_valid,
  input  logic [PRF_IDX_WIDTH-1:0] req_preg,
  input  logic [ROB_IDX_WIDTH-1:0] req_rob_idx,
  input  logic                     req_rob_flag,
  input  logic [CW-1:0]            req_countdown,
  input  logic [CN_W-1:0]          req_spec_mask,
  input  logic [CN_W-1:0]          cn_port_mask,
  input  logic                     flush_all,
  input  logic                     flush_br,
  input  logic [ROB_IDX_WIDTH-1:0] flush_rob_idx,
  input  logic                     flush_rob_flag,
  output logic [SLOTS-1:0]         wake_valid,
  output logic [PRF_IDX_WIDTH-1:0] wake_preg [SLOTS]
);

  localparam int RPW = 1 + ROB_IDX_WIDTH;

  logic [SLOTS-1:0] slot_free;
  logic [SLOTS-1:0] alloc_slot;
  logic             req_killed;

  assign req_killed = flush_br && isu_rob_younger(req_rob_idx, req_rob_flag, flush_rob_idx, flush_rob_flag);

  logic [SLOTS-1:0] first_free;
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: the slots cannot overflow (isu_wake_src sizes them)
  logic             any_free;
  /* verilator lint_on UNUSEDSIGNAL */
  ttg_first_set #(.N(SLOTS)) u_first (.req(slot_free), .onehot(first_free), .any(any_free));
  assign alloc_slot = req_valid ? first_free : '0;

  for (genvar j = 0; j < SLOTS; j++) begin : g_slot
    logic                     valid_q, valid_d;
    logic [CW-1:0]            count_q, count_d;
    logic [PRF_IDX_WIDTH-1:0] preg_q, preg_d;
    logic [RPW-1:0]           rptr_q, rptr_d;
    logic [CN_W-1:0]          spec_mask_q, spec_mask_d;
    logic                     counting;
    logic                     old_killed, spec_cancelled;

    assign counting       = valid_q && (count_q != '0);
    assign slot_free[j]   = !counting;
    assign old_killed     = flush_br && isu_rob_younger(rptr_q[ROB_IDX_WIDTH-1:0], rptr_q[ROB_IDX_WIDTH],
                                                        flush_rob_idx, flush_rob_flag);
    assign spec_cancelled = |(spec_mask_q & cn_port_mask);

    always_comb begin
      valid_d     = (req_valid && !req_killed && !flush_all && alloc_slot[j]) ||
                    (counting && !old_killed && !spec_cancelled && !flush_all);
      count_d     = slot_free[j] ? req_countdown : (count_q - CW'(1));
      preg_d      = slot_free[j] ? req_preg : preg_q;
      rptr_d      = slot_free[j] ? {req_rob_flag, req_rob_idx} : rptr_q;
      spec_mask_d = slot_free[j] ? req_spec_mask : '0;
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        valid_q     <= 1'b0;
        count_q     <= '0;
        preg_q      <= '0;
        rptr_q      <= '0;
        spec_mask_q <= '0;
      end else begin
        valid_q     <= valid_d;
        count_q     <= count_d;
        preg_q      <= preg_d;
        rptr_q      <= rptr_d;
        spec_mask_q <= spec_mask_d;
      end
    end

    assign wake_valid[j] = valid_q && (count_q == '0) && !spec_cancelled;
    assign wake_preg[j]  = preg_q;
  end

endmodule

`default_nettype wire
