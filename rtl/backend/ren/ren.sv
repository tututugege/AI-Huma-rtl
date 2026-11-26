// Ref: back-end/Ren.cpp  class Ren  (commit 2f31e8d)
`default_nettype none

// Top-level wrapper for ren_core (packs ROB commit fields; dec2ren / ren2dis already use packed structs).
module ren
  import ttg_cfg_pkg::*;
  import ren_pkg::*;
(
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic [DECODE_WIDTH-1:0]     dec2ren_valid,
  input  ren_inst_t                   dec2ren_uop [DECODE_WIDTH],
  input  logic                        dec_bcast_mispred,
  input  logic [ROB_IDX_WIDTH-1:0]    dec_bcast_redirect_rob_idx,
  input  logic                        dis2ren_ready,
  input  logic                        rob_bcast_flush,
  input  logic                        rob_bcast_interrupt,
  input  logic [COMMIT_WIDTH-1:0]     rob_commit_commit_entry_valid,
  input  logic [INST_TYPE_WIDTH-1:0]  rob_commit_commit_entry_uop_type [COMMIT_WIDTH],
  input  logic [COMMIT_WIDTH-1:0]     rob_commit_commit_entry_uop_page_fault_inst,
  input  logic [COMMIT_WIDTH-1:0]     rob_commit_commit_entry_uop_page_fault_load,
  input  logic [COMMIT_WIDTH-1:0]     rob_commit_commit_entry_uop_page_fault_store,
  input  logic [COMMIT_WIDTH-1:0]     rob_commit_commit_entry_uop_illegal_inst,
  output logic                        ren2dec_ready,
  output logic                        ren2rob_walking,
  output logic [PRF_IDX_WIDTH-1:0]    ren_commit_dest_preg [COMMIT_WIDTH],
  output logic [DECODE_WIDTH-1:0]     ren2dis_valid,
  output ren_out_uop_t                ren2dis_uop [DECODE_WIDTH]
);

  ren_commit_t commit [COMMIT_WIDTH];

  for (genvar k = 0; k < COMMIT_WIDTH; k++) begin : g_commit
    assign commit[k] = '{valid:            rob_commit_commit_entry_valid[k],
                         inst_type:        rob_commit_commit_entry_uop_type[k],
                         page_fault_inst:  rob_commit_commit_entry_uop_page_fault_inst[k],
                         page_fault_load:  rob_commit_commit_entry_uop_page_fault_load[k],
                         page_fault_store: rob_commit_commit_entry_uop_page_fault_store[k],
                         illegal_inst:     rob_commit_commit_entry_uop_illegal_inst[k]};
  end

  ren_core u_core (
    .clk(clk), .rst_n(rst_n), .dec_valid(dec2ren_valid), .dec_uop(dec2ren_uop),
    .dec_mispred(dec_bcast_mispred), .dec_redirect_rob_idx(dec_bcast_redirect_rob_idx),
    .dis_ready(dis2ren_ready), .rob_flush(rob_bcast_flush), .rob_interrupt(rob_bcast_interrupt),
    .commit(commit), .ren2dec_ready(ren2dec_ready), .ren2rob_walking(ren2rob_walking),
    .ren2dis_valid(ren2dis_valid), .ren2dis_uop(ren2dis_uop), .commit_dest_preg(ren_commit_dest_preg)
  );

endmodule

`default_nettype wire
