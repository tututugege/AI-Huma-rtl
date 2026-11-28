// Ref: back-end/Exu/include/Fu.h  FuKind::FDIV (ITER: one instruction at a time, latency by operation and format)
`default_nettype none

// The F/D divide / square-root unit:
//   SYNTH_FPU = 0 (default in simulation): DPI SoftFloat via fp_core at accept + held result registers (fast sim).
//   SYNTH_FPU = 1 (default in synthesis, or -DFPU_REAL): iterative synthesizable fp_div_core (3 bits/cycle).
module fp_div_unit
  import ttg_cfg_pkg::*;
  import fp_pkg::*;
#(
`ifdef SYNTHESIS
  parameter bit SYNTH_FPU = 1'b1
`elsif FPU_REAL
  parameter bit SYNTH_FPU = 1'b1
`else
  parameter bit SYNTH_FPU = 1'b0
`endif
) (
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic                       en,
  input  logic                       flush_all,
  input  logic                       flush_br,
  input  logic [ROB_IDX_WIDTH-1:0]   flush_rob_idx,
  input  logic                       flush_rob_flag,
  input  logic [2:0]                 func3,
  input  logic [6:0]                 func7,
  input  logic [31:0]                imm,
  input  logic [XLEN_BITS-1:0]       src1_rdata,
  input  logic [63:0]                fsrc1,
  input  logic [63:0]                fsrc2,
  input  logic [63:0]                fsrc3,
  input  logic [2:0]                 frm,
  input  logic [ROB_IDX_WIDTH-1:0]   rob_idx,
  input  logic                       rob_flag,
  input  logic [PRF_IDX_WIDTH-1:0]   dest_preg,
  input  logic                       dest_en,
  output logic                       complete,
  output logic [63:0]                fresult,
  output logic [4:0]                 fflags,
  output logic                       illegal,
  output logic [ROB_IDX_WIDTH-1:0]   done_rob_idx,
  output logic                       done_rob_flag,
  output logic [PRF_IDX_WIDTH-1:0]   done_dest_preg,
  output logic                       done_dest_en
);

  logic accept;
  /* verilator lint_off UNUSEDSIGNAL */   // waiver: run used when SYNTH_FPU=1; wb_next unused by FDIV
  logic run, unused_wb_next;
  /* verilator lint_on UNUSEDSIGNAL */

  exu_iter_ctl #(.CW(FP_LAT_W)) u_ctl (
    .clk(clk), .rst_n(rst_n), .flush_all(flush_all), .flush_br(flush_br),
    .flush_rob_idx(flush_rob_idx), .flush_rob_flag(flush_rob_flag),
    .en(en), .en_rob_idx(rob_idx), .en_rob_flag(rob_flag),
    .lat_m1(FP_LAT_W'(fp_div_latency(func7) - 1)),
    .accept(accept), .run(run), .complete(complete), .wb_next(unused_wb_next), .done_rob_flag(done_rob_flag)
  );

  if (!SYNTH_FPU) begin : g_dpi
    logic [63:0] res, res_q;
    logic [4:0]  flags, flags_q;
    logic        bad, bad_q;
    fp_core u_core (
      .func3(func3), .imm(imm), .int_src(src1_rdata), .fsrc1(fsrc1), .fsrc2(fsrc2), .fsrc3(fsrc3), .frm(frm),
      .result(res), .fflags(flags), .illegal(bad)
    );
    always_comb begin
      fresult = res_q;
      fflags  = flags_q;
      illegal = bad_q;
    end
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        res_q   <= '0;
        flags_q <= '0;
        bad_q   <= 1'b0;
      end else if (accept) begin
        res_q   <= res;
        flags_q <= flags;
        bad_q   <= bad;
      end
    end
  end else begin : g_synth
    fp_div_core u_core (
      .clk(clk), .rst_n(rst_n), .accept(accept), .run(run),
      .func3(func3), .imm(imm), .fsrc1(fsrc1), .fsrc2(fsrc2), .frm(frm),
      .result(fresult), .fflags(fflags), .illegal(illegal)
    );
  end

  // payload of the uop in flight, captured when it is accepted
  logic [ROB_IDX_WIDTH-1:0] rob_idx_q;
  logic [PRF_IDX_WIDTH-1:0] dest_preg_q;
  logic                     dest_en_q;
  always_comb begin
    done_rob_idx   = rob_idx_q;
    done_dest_preg = dest_preg_q;
    done_dest_en   = dest_en_q;
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rob_idx_q   <= '0;
      dest_preg_q <= '0;
      dest_en_q   <= 1'b0;
    end else if (accept) begin
      rob_idx_q   <= rob_idx;
      dest_preg_q <= dest_preg;
      dest_en_q   <= dest_en;
    end
  end

endmodule

`default_nettype wire
