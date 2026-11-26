// Ref: front-end/BPU/BpuFtb.h  struct PlruArray (per-set 4-way 3b / 8-way 7b tree-PLRU FF array)
`default_nettype none

module bpu_plru #(
  parameter int SETS = 1024,
  parameter int WAYS = 4
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [$clog2(SETS)-1:0]  rd_set,
  output logic [$clog2(WAYS)-1:0]  victim_way,
  input  logic                     touch_en,
  input  logic [$clog2(SETS)-1:0]  touch_set,
  input  logic [$clog2(WAYS)-1:0]  touch_way
);

  localparam int BITS = WAYS - 1;  // 3 for 4-way, 7 for 8-way

  logic [BITS-1:0] plru_q [SETS];

  generate
    if (WAYS == 4) begin : g_w4
      always_comb begin
        logic [2:0] b;
        b = plru_q[rd_set];
        if (!b[0]) victim_way = b[1] ? 2'd1 : 2'd0;
        else       victim_way = b[2] ? 2'd3 : 2'd2;
      end
      always_ff @(posedge clk) begin
        if (!rst_n) begin
          for (int i = 0; i < SETS; i++) plru_q[i] <= 3'd0;
        end else if (touch_en) begin
          if (touch_way < 2'd2) begin
            plru_q[touch_set][0] <= 1'b1;
            plru_q[touch_set][1] <= (touch_way == 2'd0);
          end else begin
            plru_q[touch_set][0] <= 1'b0;
            plru_q[touch_set][2] <= (touch_way == 2'd2);
          end
        end
      end
    end else begin : g_w8
      always_comb begin
        logic [6:0] b;
        b = plru_q[rd_set];
        if (!b[0]) begin
          if (!b[1]) victim_way = b[3] ? 3'd1 : 3'd0;
          else       victim_way = b[4] ? 3'd3 : 3'd2;
        end else begin
          if (!b[2]) victim_way = b[5] ? 3'd5 : 3'd4;
          else       victim_way = b[6] ? 3'd7 : 3'd6;
        end
      end
      always_ff @(posedge clk) begin
        if (!rst_n) begin
          for (int i = 0; i < SETS; i++) plru_q[i] <= 7'd0;
        end else if (touch_en) begin
          if (touch_way < 3'd4) begin
            plru_q[touch_set][0] <= 1'b1;
            if (touch_way < 3'd2) begin
              plru_q[touch_set][1] <= 1'b1;
              plru_q[touch_set][3] <= (touch_way == 3'd0);
            end else begin
              plru_q[touch_set][1] <= 1'b0;
              plru_q[touch_set][4] <= (touch_way == 3'd2);
            end
          end else begin
            plru_q[touch_set][0] <= 1'b0;
            if (touch_way < 3'd6) begin
              plru_q[touch_set][2] <= 1'b1;
              plru_q[touch_set][5] <= (touch_way == 3'd4);
            end else begin
              plru_q[touch_set][2] <= 1'b0;
              plru_q[touch_set][6] <= (touch_way == 3'd6);
            end
          end
        end
      end
    end
  endgenerate

endmodule

`default_nettype wire
