// Toy 4-entry FIFO, used only to validate the harness. Written to the project RTL standard.
`default_nettype none

module toy_fifo (
  input  wire         clk,
  input  wire         rst_n,
  input  logic        push_valid,
  input  logic [7:0]  push_data,
  input  logic        pop_ready,
  input  logic        flush,
  input  logic [79:0] blob,
  output logic        push_ready,
  output logic        pop_valid,
  output logic [7:0]  pop_data,
  output logic [2:0]  count,
  output logic        slot_valid [4],
  output logic [7:0]  slot_data  [4],
  output logic [79:0] blob_rot,
  output logic [3:0]  lane_sum   [2][2]
);

  // ---- registers ----
  logic [7:0] mem_q  [4];
  logic [1:0] head_q;
  logic [1:0] tail_q;
  logic [2:0] count_q;

  // ---- next state ----
  logic [7:0] mem_d  [4];
  logic [1:0] head_d;
  logic [1:0] tail_d;
  logic [2:0] count_d;

  logic do_push;
  logic do_pop;

  always_comb begin
    push_ready = count_q < 3'd4;
    pop_valid  = count_q != 3'd0;
    pop_data   = mem_q[head_q];
    count      = count_q;
    blob_rot   = {blob[78:0], blob[79]};

    for (int i = 0; i < 4; i++) begin
      slot_valid[i] = 3'(2'(i[1:0] - head_q)) < count_q;
      slot_data[i]  = mem_q[i];
    end
    for (int r = 0; r < 2; r++) begin
      for (int c = 0; c < 2; c++) begin
        lane_sum[r][c] = {1'b0, count_q} + 4'(r * 2 + c);
      end
    end

    do_push = push_valid && push_ready;
    do_pop  = pop_ready && pop_valid;

    mem_d   = mem_q;
    head_d  = head_q;
    tail_d  = tail_q;
    count_d = count_q;
    if (do_push) begin
      mem_d[tail_q] = push_data;
      tail_d        = tail_q + 2'd1;
    end
    if (do_pop) begin
      head_d = head_q + 2'd1;
    end
    count_d = count_q + 3'(do_push) - 3'(do_pop);
    if (flush) begin
      head_d  = 2'd0;
      tail_d  = 2'd0;
      count_d = 3'd0;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < 4; i++) mem_q[i] <= 8'd0;
      head_q  <= 2'd0;
      tail_q  <= 2'd0;
      count_q <= 3'd0;
    end else begin
      mem_q   <= mem_d;
      head_q  <= head_d;
      tail_q  <= tail_d;
      count_q <= count_d;
    end
  end

endmodule

`default_nettype wire
