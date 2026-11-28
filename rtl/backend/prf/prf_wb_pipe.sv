// Ref: back-end/Prf.cpp  class Prf  inst_r[] / comb_pipeline / seq
`default_nettype none

module prf_wb_pipe import ttg_cfg_pkg::*; import ttg_util_pkg::ttg_rob_younger; #(
  parameter int LANES = WB_LANES
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     flush,
  input  logic                     bcast_mispred,
  input  logic [ROB_IDX_WIDTH-1:0] bcast_rob_idx,
  input  logic                     bcast_rob_flag,
  input  logic [LANES-1:0]         exe_valid,
  input  logic [LANES-1:0]         exe_dest_en,
  input  logic [LANES-1:0]         exe_is_load,
  input  logic [PRF_IDX_WIDTH-1:0] exe_dest_preg [LANES],
  input  logic [XLEN_BITS-1:0]     exe_result    [LANES],
  input  logic [ROB_IDX_WIDTH-1:0] exe_rob_idx   [LANES],
  input  logic [LANES-1:0]         exe_rob_flag,
  output logic [LANES-1:0]         wb_wen_q,
  output logic [LANES-1:0]         wb_is_load_q,
  output logic [PRF_IDX_WIDTH-1:0] wb_dest_preg_q [LANES],
  output logic [XLEN_BITS-1:0]     wb_result_q    [LANES],
  output logic [ROB_IDX_WIDTH-1:0] wb_rob_idx_q   [LANES],
  output logic [LANES-1:0]         wb_rob_flag_q
);

  logic [LANES-1:0] wb_wen_d;

  always_comb begin
    for (int i = 0; i < LANES; i++) begin
      wb_wen_d[i] = !flush && exe_valid[i] && exe_dest_en[i] &&
                    !(bcast_mispred && ttg_rob_younger(exe_rob_idx[i], exe_rob_flag[i], bcast_rob_idx, bcast_rob_flag));
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wb_wen_q      <= '0;
      wb_is_load_q  <= '0;
      wb_rob_flag_q <= '0;
      for (int i = 0; i < LANES; i++) begin
        wb_dest_preg_q[i] <= '0;
        wb_result_q[i]    <= '0;
        wb_rob_idx_q[i]   <= '0;
      end
    end else begin
      wb_wen_q      <= wb_wen_d;
      wb_is_load_q  <= exe_is_load;
      wb_rob_flag_q <= exe_rob_flag;
      for (int i = 0; i < LANES; i++) begin
        wb_dest_preg_q[i] <= exe_dest_preg[i];
        wb_result_q[i]    <= exe_result[i];
        wb_rob_idx_q[i]   <= exe_rob_idx[i];
      end
    end
  end

endmodule

`default_nettype wire
