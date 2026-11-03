// Ref: back-end/Ren.cpp  class Ren  (inst_r, inst_valid; Ren::comb_pipeline)
`default_nettype none

// Rename pipeline register: holds the decoded group until every valid slot has fired.
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

  // priority: kill (keep payload, drop valid) > take_new (sample, clear mask unconditionally)
  //           > hold (valid slots only get their mask cleared)
  for (genvar i = 0; i < N; i++) begin : g_slot
    always_comb begin
      inst[i]    = inst_q[i];
      inst_d[i]  = inst_q[i];
      valid_d[i] = valid_q[i] & ~fire[i];
      if (kill) begin
        valid_d[i] = 1'b0;
      end else if (take_new) begin
        valid_d[i]         = dec_valid[i];
        inst_d[i]          = dec_uop[i];
        inst_d[i].br_mask  = dec_uop[i].br_mask & ~clear_mask;
      end else if (valid_d[i]) begin
        inst_d[i].br_mask  = inst_q[i].br_mask & ~clear_mask;
      end
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        valid_q[i] <= 1'b0;
        inst_q[i]  <= '0;
      end else begin
        valid_q[i] <= valid_d[i];
        inst_q[i]  <= inst_d[i];
      end
    end
  end

endmodule

`default_nettype wire
