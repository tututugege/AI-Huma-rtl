// Ref: back-end/Lsu/RealLsuPipe.cpp  RealLsu (PL3 register, comb_lsu2exe_p step 1 with LSU_PIPE_L2 bit 1)
`default_nettype none

// L3 register of the staged LSU (LP_L2[0]).  The direct completion decided at L2 (forward / page fault / DCache hit)
// is registered; the write-back port allocation, the LDQ free and the reservation update run one cycle later from
// registers only.  A load killed in between is dropped by the state check (its LDQ entry is no longer WB3).
// With LP_L2[0] = 0 the module is a wire (the L2 result goes to the write-back in the same cycle).
module lp_l3
  import ttg_cfg_pkg::*;
  import lp_pkg::*;
(
  input  logic                clk,
  input  logic                rst_n,
  input  logic [NLD-1:0]      wbd_v,
  input  logic [LQW-1:0]      wbd_idx [NLD],
  input  logic [NLD-1:0]      wbd_hasdata,
  input  logic [31:0]         wbd_data [NLD],
  input  logic [LQ-1:0]       wb3_r,
  output logic [NLD-1:0]      wbw_v,
  output logic [LQW-1:0]      wbw_idx [NLD],
  output logic [NLD-1:0]      wbw_hd,
  output logic [31:0]         wbw_data [NLD]
);

  logic [NLD-1:0]  l3_v_q;
  logic [LQW-1:0]  l3_idx_q [NLD];
  logic [NLD-1:0]  l3_hd_q;
  logic [31:0]     l3_data_q [NLD];

  always_ff @(posedge clk) begin
    if (!rst_n) l3_v_q <= '0;
    else        l3_v_q <= wbd_v;
    for (int p = 0; p < NLD; p++) begin
      l3_idx_q[p] <= wbd_idx[p];
      l3_data_q[p] <= wbd_data[p];
    end
    l3_hd_q <= wbd_hasdata;
  end

  always_comb begin
    for (int p = 0; p < NLD; p++) begin
      if ((LP_L2 & 1) != 0) begin
        wbw_v[p] = l3_v_q[p] && wb3_r[l3_idx_q[p]];
        wbw_idx[p] = l3_idx_q[p];
        wbw_hd[p] = l3_hd_q[p];
        wbw_data[p] = l3_data_q[p];
      end else begin
        wbw_v[p] = wbd_v[p];
        wbw_idx[p] = wbd_idx[p];
        wbw_hd[p] = wbd_hasdata[p];
        wbw_data[p] = wbd_data[p];
      end
    end
  end

endmodule

`default_nettype wire
