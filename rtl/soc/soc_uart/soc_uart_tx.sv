// Ref: docs/modules/soc_periph.md  NS16550A 8N1 serial transmitter
`default_nettype none

// 16x-oversampled 8N1 UART TX shift engine. Bit duration = max(divisor, 1) * 16 clock cycles.
module soc_uart_tx (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [15:0] divisor,
  input  logic        tx_valid,
  input  logic [7:0]  tx_data,
  output logic        tx_ready,
  output logic        tx_busy,
  output logic        txd
);

  logic        active_q, active_d;
  logic [9:0]  shift_q, shift_d;      // {stop=1, data[7:0], start=0}
  logic [3:0]  bit_cnt_q, bit_cnt_d;
  logic [19:0] clk_cnt_q, clk_cnt_d;
  logic [19:0] bit_ticks;

  assign bit_ticks = (divisor == 16'd0) ? 20'd16 : {divisor, 4'b0000};
  assign tx_ready  = !active_q;
  assign tx_busy   = active_q;
  assign txd       = active_q ? shift_q[0] : 1'b1;

  always_comb begin
    active_d  = active_q;
    shift_d   = shift_q;
    bit_cnt_d = bit_cnt_q;
    clk_cnt_d = clk_cnt_q;
    if (!active_q) begin
      if (tx_valid) begin
        active_d  = 1'b1;
        shift_d   = {1'b1, tx_data, 1'b0};
        bit_cnt_d = 4'd9;
        clk_cnt_d = bit_ticks - 20'd1;
      end
    end else begin
      if (clk_cnt_q == 20'd0) begin
        if (bit_cnt_q == 4'd0) begin
          active_d = 1'b0;
        end else begin
          shift_d   = {1'b1, shift_q[9:1]};
          bit_cnt_d = bit_cnt_q - 4'd1;
          clk_cnt_d = bit_ticks - 20'd1;
        end
      end else begin
        clk_cnt_d = clk_cnt_q - 20'd1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      active_q  <= 1'b0;
      shift_q   <= 10'h3FF;
      bit_cnt_q <= 4'd0;
      clk_cnt_q <= 20'd0;
    end else begin
      active_q  <= active_d;
      shift_q   <= shift_d;
      bit_cnt_q <= bit_cnt_d;
      clk_cnt_q <= clk_cnt_d;
    end
  end

endmodule

`default_nettype wire
