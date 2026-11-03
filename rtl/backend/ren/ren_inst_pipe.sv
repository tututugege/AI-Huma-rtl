// Ref: back-end/Ren.cpp  class Ren  (inst_r, inst_valid; Ren::comb_pipeline)
`default_nettype none

// Rename pipeline register: holds the decoded group until every valid slot has fired.
// Payload of an invalid slot is don't-care (downstream only reads ren2dis fields while ren2dis_valid), so the
// payload simply follows take_new and the resolved-branch bits are cleared from every slot unconditionally.
module ren_inst_pipe
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
#(
  parameter int N = DECODE_WIDTH
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic [N-1:0]  dec_valid,
  input  ren_inst_t     dec_uop [N],
  input  logic          take_new,     // ren2dec.ready: accept the next group from decode
  input  logic          kill,         // flush or mispredict: drop the held group
  input  logic [N-1:0]  fire,
  input  br_mask_t      clear_mask,   // resolved-branch bits to clear from every br_mask
  output logic [N-1:0]  valid,
  output ren_inst_t     inst [N]
);

  logic [N-1:0] valid_q, valid_d;
  ren_inst_t    inst_q [N], inst_d [N];

  assign valid = valid_q;

  always_comb begin
    for (int i = 0; i < N; i++) begin
      inst[i]   = inst_q[i];
      inst_d[i] = take_new ? dec_uop[i] : inst_q[i];
      inst_d[i].br_mask = inst_d[i].br_mask & ~clear_mask;
    end
    if (kill)          valid_d = '0;
    else if (take_new) valid_d = dec_valid;
    else               valid_d = valid_q & ~fire;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_q <= '0;
      inst_q  <= '{default: '0};
    end else begin
      valid_q <= valid_d;
      inst_q  <= inst_d;
    end
  end

endmodule

`default_nettype wire
