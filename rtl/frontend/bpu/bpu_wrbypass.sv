// Ref: front-end/BPU/BpuSc.h & BpuFtb.h (8-entry FF WRBypass CAM+Mem, matches XiangShan WRBypass)
// Eliminates commit-side T0 SRAM reads by forwarding recent updates to back-to-back commits of the same entry.
`default_nettype none

module bpu_wrbypass #(
  parameter int N      = 8,
  parameter int KEY_W  = 16,
  parameter int DATA_W = 8
) (
  input  logic              clk,
  input  logic              rst_n,
  // Combinational lookup (up to 1 primary lookup port; secondary lookups use extra instances or direct ports)
  input  logic [KEY_W-1:0]  rd_key,
  output logic              rd_hit,
  output logic [DATA_W-1:0] rd_data,
  // Single-entry synchronous insert (updates in place on key hit, else FIFO round-robin overwrite)
  input  logic              wr_en,
  input  logic [KEY_W-1:0]  wr_key,
  input  logic [DATA_W-1:0] wr_data
);

  localparam int PTR_W = $clog2(N);

  logic [N-1:0]      valid_q;
  logic [KEY_W-1:0]  key_q   [N];
  logic [DATA_W-1:0] data_q  [N];
  logic [PTR_W-1:0]  ptr_q;

  always_comb begin
    rd_hit  = 1'b0;
    rd_data = '0;
    for (int i = 0; i < N; i++) begin
      if (!rd_hit && valid_q[i] && (key_q[i] == rd_key)) begin
        rd_hit  = 1'b1;
        rd_data = data_q[i];
      end
    end
  end

  logic              wr_hit;
  logic [PTR_W-1:0]  wr_hit_idx;

  always_comb begin
    wr_hit     = 1'b0;
    wr_hit_idx = '0;
    for (int i = 0; i < N; i++) begin
      if (!wr_hit && valid_q[i] && (key_q[i] == wr_key)) begin
        wr_hit     = 1'b1;
        wr_hit_idx = PTR_W'(i);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_q <= '0;
      ptr_q   <= '0;
      for (int i = 0; i < N; i++) begin
        key_q[i]  <= '0;
        data_q[i] <= '0;
      end
    end else if (wr_en) begin
      if (wr_hit) begin
        data_q[wr_hit_idx] <= wr_data;
      end else begin
        valid_q[ptr_q] <= 1'b1;
        key_q[ptr_q]   <= wr_key;
        data_q[ptr_q]  <= wr_data;
        ptr_q          <= ptr_q + PTR_W'(1);
      end
    end
  end

endmodule

`default_nettype wire
