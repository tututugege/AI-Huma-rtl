// Ref: back-end/Exu/include/Fu.h  FuKind::FMA / FMISC / I2F (PIPE: fully pipelined, fixed latency)
`default_nettype none

// A pipelined F/D unit:
//   SYNTH_FPU = 0 (default in simulation): DPI SoftFloat via fp_core at accept + mul_pipe delay queue (fast sim).
//   SYNTH_FPU = 1 (default in synthesis, or -DFPU_REAL): synthesizable RV64FD datapath:
//     MODE = 0 (FMA, LAT=3)   : 3-stage pipelined fp_fma_core (result valid at t+2, like mul_core) + mul_pipe payload
//     MODE = 1 (FMISC, LAT=2) : fp_misc_core + fp_fcvt_core + mul_pipe
//     MODE = 2 (I2F, LAT=2)   : fp_i2f_core + mul_pipe
module fp_pipe_unit
  import ttg_cfg_pkg::*;
  import exu_fu_pkg::*;
#(
  parameter int LAT  = 3,
  parameter int MODE = 0,
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

  logic [63:0] res;
  logic [4:0]  flags;
  logic        bad;
  fp_uop_t     en_uop;
  /* verilator lint_off UNUSEDSIGNAL */
  fp_uop_t     done_uop;
  /* verilator lint_on UNUSEDSIGNAL */

  if (!SYNTH_FPU) begin : g_dpi
    fp_core u_core (
      .func3(func3), .imm(imm), .int_src(src1_rdata), .fsrc1(fsrc1), .fsrc2(fsrc2), .fsrc3(fsrc3), .frm(frm),
      .result(res), .fflags(flags), .illegal(bad)
    );
    always_comb begin
      en_uop  = '{fresult: res, fflags: flags, illegal: bad, rob_idx: rob_idx, rob_flag: rob_flag, dest_preg: dest_preg, dest_en: dest_en};
      fresult = done_uop.fresult;
      fflags  = done_uop.fflags;
      illegal = done_uop.illegal;
    end
  end else if (MODE == 0) begin : g_fma
    // 3-stage pipelined FMA: result arrives at t+2 matching mul_pipe completion (guaranteed consumed by wb_gate)
    fp_fma_core u_fma (
      .clk(clk), .func3(func3), .imm(imm), .fsrc1(fsrc1), .fsrc2(fsrc2), .fsrc3(fsrc3), .frm(frm),
      .result(res), .fflags(flags), .illegal(bad)
    );
    always_comb begin
      en_uop  = '{fresult: '0, fflags: '0, illegal: 1'b0, rob_idx: rob_idx, rob_flag: rob_flag, dest_preg: dest_preg, dest_en: dest_en};
      fresult = res;
      fflags  = flags;
      illegal = bad;
    end
  end else if (MODE == 1) begin : g_misc
    logic [63:0] m_res, c_res;
    logic [4:0]  m_flg, c_flg;
    logic        m_bad, c_bad, is_fcvt;
    fp_misc_core u_misc (
      .func3(func3), .imm(imm), .fsrc1(fsrc1), .fsrc2(fsrc2),
      .result(m_res), .fflags(m_flg), .illegal(m_bad)
    );
    fp_fcvt_core u_fcvt (
      .func3(func3), .imm(imm), .fsrc1(fsrc1), .frm(frm),
      .result(c_res), .fflags(c_flg), .illegal(c_bad)
    );
    always_comb begin
      is_fcvt = (imm[11:7] == 5'h08) || (imm[11:7] == 5'h18);
      res     = is_fcvt ? c_res : m_res;
      flags   = is_fcvt ? c_flg : m_flg;
      bad     = is_fcvt ? c_bad : m_bad;
      en_uop  = '{fresult: res, fflags: flags, illegal: bad, rob_idx: rob_idx, rob_flag: rob_flag, dest_preg: dest_preg, dest_en: dest_en};
      fresult = done_uop.fresult;
      fflags  = done_uop.fflags;
      illegal = done_uop.illegal;
    end
  end else begin : g_i2f
    fp_i2f_core u_i2f (
      .func3(func3), .imm(imm), .int_src(src1_rdata), .frm(frm),
      .result(res), .fflags(flags), .illegal(bad)
    );
    always_comb begin
      en_uop  = '{fresult: res, fflags: flags, illegal: bad, rob_idx: rob_idx, rob_flag: rob_flag, dest_preg: dest_preg, dest_en: dest_en};
      fresult = done_uop.fresult;
      fflags  = done_uop.fflags;
      illegal = done_uop.illegal;
    end
  end

  always_comb begin
    done_rob_idx   = done_uop.rob_idx;
    done_rob_flag  = done_uop.rob_flag;
    done_dest_preg = done_uop.dest_preg;
    done_dest_en   = done_uop.dest_en;
  end

  mul_pipe #(.DEPTH(LAT), .UOP_T(fp_uop_t)) u_pipe (
    .clk(clk), .rst_n(rst_n), .flush_all(flush_all), .flush_br(flush_br),
    .flush_rob_idx(flush_rob_idx), .flush_rob_flag(flush_rob_flag),
    .en(en), .en_uop(en_uop), .complete(complete), .done_uop(done_uop)
  );

endmodule

`default_nettype wire
