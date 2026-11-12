// Ref: back-end/Exu/include/Fu.h  FuKind::FMA / FMISC / I2F (PIPE: fully pipelined, fixed latency)
`default_nettype none

// A pipelined F/D unit: the result is computed in the accept cycle (as in the reference) and travels through the result
// pipeline together with its write-back payload (mul_pipe with the FP payload). LAT = the unit latency of the model.
module fp_pipe_unit
  import ttg_cfg_pkg::*;
  import exu_fu_pkg::*;
#(
  parameter int LAT = 3
) (
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic                       en,
  input  logic                       consume,
  input  logic                       flush,
  input  logic [BR_MASK_WIDTH-1:0]   flush_mask,
  input  logic [BR_MASK_WIDTH-1:0]   clear_mask,
  input  logic [2:0]                 func3,
  input  logic [31:0]                imm,
  input  logic [XLEN_BITS-1:0]       src1_rdata,
  input  logic [63:0]                fsrc1,
  input  logic [63:0]                fsrc2,
  input  logic [63:0]                fsrc3,
  input  logic [2:0]                 frm,
  input  logic [ROB_IDX_WIDTH-1:0]   rob_idx,
  input  logic [PRF_IDX_WIDTH-1:0]   dest_preg,
  input  logic                       dest_en,
  input  logic [BR_MASK_WIDTH-1:0]   br_mask,
  output logic                       complete,
  output logic                       ready,
  output logic [63:0]                fresult,
  output logic [4:0]                 fflags,
  output logic                       illegal,
  output logic [ROB_IDX_WIDTH-1:0]   done_rob_idx,
  output logic [PRF_IDX_WIDTH-1:0]   done_dest_preg,
  output logic                       done_dest_en,
  output logic [BR_MASK_WIDTH-1:0]   done_br_mask
);

  logic [63:0] res;
  logic [4:0]  flags;
  logic        bad;
  fp_uop_t     en_uop, done_uop;

  fp_core u_core (
    .func3(func3), .imm(imm), .int_src(src1_rdata), .fsrc1(fsrc1), .fsrc2(fsrc2), .fsrc3(fsrc3), .frm(frm),
    .result(res), .fflags(flags), .illegal(bad)
  );

  always_comb begin
    en_uop = '{fresult: res, fflags: flags, illegal: bad, rob_idx: rob_idx, dest_preg: dest_preg, dest_en: dest_en,
               br_mask: br_mask};
    fresult        = done_uop.fresult;
    fflags         = done_uop.fflags;
    illegal        = done_uop.illegal;
    done_rob_idx   = done_uop.rob_idx;
    done_dest_preg = done_uop.dest_preg;
    done_dest_en   = done_uop.dest_en;
    done_br_mask   = done_uop.br_mask;
  end

  mul_pipe #(.DEPTH(LAT), .UOP_T(fp_uop_t)) u_pipe (
    .clk(clk), .rst_n(rst_n), .flush(flush), .flush_mask(flush_mask), .clear_mask(clear_mask),
    .en(en), .consume(consume), .en_uop(en_uop), .complete(complete), .ready(ready), .done_uop(done_uop)
  );

endmodule

`default_nettype wire
