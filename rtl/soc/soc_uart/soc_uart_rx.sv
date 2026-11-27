// Ref: docs/modules/soc_periph.md  NS16550A 8N1 serial receiver
`default_nettype none

// 16x-oversampled 8N1 UART RX shift engine with 2-FF input synchronizer and mid-bit sampling.
module soc_uart_rx (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [15:0] divisor,
  input  logic        rxd,
  output logic        rx_valid,
  output logic [7:0]  rx_data
);

  typedef enum logic [1:0] {
    ST_IDLE  = 2'd0,
    ST_START = 2'd1,
    ST_DATA  = 2'd2,
    ST_STOP  = 2'd3
  } st_e;

  logic        rx_s1_q, rx_s2_q, rx_prev_q;
  st_e         st_q, st_d;
  logic [7:0]  shift_q, shift_d;
  logic [2:0]  bit_cnt_q, bit_cnt_d;
  logic [19:0] clk_cnt_q, clk_cnt_d;
  logic        valid_q, valid_d;
  logic [7:0]  data_q, data_d;
  logic [19:0] bit_ticks, half_ticks;

  assign bit_ticks  = (divisor == 16'd0) ? 20'd16 : {divisor, 4'b0000};
  assign half_ticks = {1'b0, bit_ticks[19:1]};
  assign rx_valid   = valid_q;
  assign rx_data    = data_q;

  always_comb begin
    st_d      = st_q;
    shift_d   = shift_q;
    bit_cnt_d = bit_cnt_q;
    clk_cnt_d = clk_cnt_q;
    valid_d   = 1'b0;
    data_d    = data_q;

    case (st_q)
      ST_IDLE: begin
        if (rx_prev_q && !rx_s2_q) begin
          st_d      = ST_START;
          clk_cnt_d = half_ticks - 20'd1;
        end
      end
      ST_START: begin
        if (clk_cnt_q == 20'd0) begin
          if (!rx_s2_q) begin
            st_d      = ST_DATA;
            bit_cnt_d = 3'd0;
            clk_cnt_d = bit_ticks - 20'd1;
          end else begin
            st_d = ST_IDLE;
          end
        end else begin
          clk_cnt_d = clk_cnt_q - 20'd1;
        end
      end
      ST_DATA: begin
        if (clk_cnt_q == 20'd0) begin
          shift_d = {rx_s2_q, shift_q[7:1]};
          if (bit_cnt_q == 3'd7) begin
            st_d      = ST_STOP;
            clk_cnt_d = bit_ticks - 20'd1;
          end else begin
            bit_cnt_d = bit_cnt_q + 3'd1;
            clk_cnt_d = bit_ticks - 20'd1;
          end
        end else begin
          clk_cnt_d = clk_cnt_q - 20'd1;
        end
      end
      default: begin
        if (clk_cnt_q == 20'd0) begin
          st_d = ST_IDLE;
          if (rx_s2_q) begin
            valid_d = 1'b1;
            data_d  = shift_q;
          end
        end else begin
          clk_cnt_d = clk_cnt_q - 20'd1;
        end
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rx_s1_q   <= 1'b1;
      rx_s2_q   <= 1'b1;
      rx_prev_q <= 1'b1;
      st_q      <= ST_IDLE;
      shift_q   <= 8'd0;
      bit_cnt_q <= 3'd0;
      clk_cnt_q <= 20'd0;
      valid_q   <= 1'b0;
      data_q    <= 8'd0;
    end else begin
      rx_s1_q   <= rxd;
      rx_s2_q   <= rx_s1_q;
      rx_prev_q <= rx_s2_q;
      st_q      <= st_d;
      shift_q   <= shift_d;
      bit_cnt_q <= bit_cnt_d;
      clk_cnt_q <= clk_cnt_d;
      valid_q   <= valid_d;
      data_q    <= data_d;
    end
  end

endmodule

`default_nettype wire
