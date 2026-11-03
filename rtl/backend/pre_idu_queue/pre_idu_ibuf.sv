// Ref: back-end/InstructionBuffer.cpp  class InstructionBuffer; PreIduQueue::comb_begin (issue group), comb_fire
`default_nettype none

// Instruction ring buffer: a fetch group is written compacted at the tail, Idu reads the oldest DECODE_WIDTH slots.
// Slot j is written by the lane i with push_en[i] && tail + rank[i] == j (ranks are unique, so one-hot).
module pre_idu_ibuf import ttg_cfg_pkg::*; import pre_idu_pkg::*; (
  input  logic                           clk,
  input  logic                           rst_n,
  input  logic                           clear,
  input  logic [DECODE_CNT_W-1:0]        pop_cnt,
  input  logic [LANE_CNT_W-1:0]          push_cnt,
  input  logic [BACKEND_FETCH_WIDTH-1:0] push_en,
  input  logic [LANE_CNT_W-1:0]          push_rank [BACKEND_FETCH_WIDTH],
  input  ib_entry_t                      push_entry [BACKEND_FETCH_WIDTH],
  output logic [IB_COUNT_W-1:0]          count,
  output logic [DECODE_WIDTH-1:0]        issue_valid,
  output ib_entry_t                      issue_entry [DECODE_WIDTH]
);

  logic [IB_IDX_W-1:0]    head_q;
  logic [IB_IDX_W-1:0]    head_d;
  logic [IB_IDX_W-1:0]    tail_q;
  logic [IB_IDX_W-1:0]    tail_d;
  logic [IB_COUNT_W-1:0]  count_q;
  logic [IB_COUNT_W-1:0]  count_d;
  ib_entry_t              entry_q [IDU_INST_BUFFER_SIZE];
  ib_entry_t              entry_d [IDU_INST_BUFFER_SIZE];

  logic [IB_IDX_W-1:0]    lane_slot [BACKEND_FETCH_WIDTH];  // slot each lane would write
  logic [BACKEND_FETCH_WIDTH-1:0] slot_hit [IDU_INST_BUFFER_SIZE];
  logic                   slot_wr_en [IDU_INST_BUFFER_SIZE];
  ib_entry_t              slot_wr_data [IDU_INST_BUFFER_SIZE];

  assign count = count_q;

  // Ref: InstructionBuffer::push_back (one write port per lane, compacted by rank)
  always_comb begin
    for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) lane_slot[i] = tail_q + IB_IDX_W'(push_rank[i]);
  end

  for (genvar j = 0; j < IDU_INST_BUFFER_SIZE; j++) begin : g_slot
    always_comb begin
      for (int i = 0; i < BACKEND_FETCH_WIDTH; i++) slot_hit[j][i] = push_en[i] && (lane_slot[i] == IB_IDX_W'(j));
    end
    ttg_onehot_mux #(.N(BACKEND_FETCH_WIDTH), .W($bits(ib_entry_t))) u_wdata (
      .sel(slot_hit[j]), .data(push_entry), .out(slot_wr_data[j]));
    assign slot_wr_en[j] = |slot_hit[j];
  end

  // Ref: PreIduQueue::comb_fire (clear on flush/mispredict, else pop then push) + InstructionBuffer::pop_front
  always_comb begin
    head_d  = head_q;
    tail_d  = tail_q;
    count_d = count_q;
    for (int j = 0; j < IDU_INST_BUFFER_SIZE; j++) entry_d[j] = slot_wr_en[j] ? slot_wr_data[j] : entry_q[j];
    if (clear) begin
      head_d  = '0;
      tail_d  = '0;
      count_d = '0;
    end else begin
      head_d  = head_q + IB_IDX_W'(pop_cnt);
      tail_d  = tail_q + IB_IDX_W'(push_cnt);
      count_d = count_q + IB_COUNT_W'(push_cnt) - IB_COUNT_W'(pop_cnt);
    end
  end

  // Ref: PreIduQueue::comb_begin (issue->entries[i] = ibuf.peek(i) for i < count)
  always_comb begin
    for (int i = 0; i < DECODE_WIDTH; i++) begin
      issue_valid[i] = count_q > IB_COUNT_W'(i);
      issue_entry[i] = entry_q[head_q + IB_IDX_W'(i)];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
      for (int j = 0; j < IDU_INST_BUFFER_SIZE; j++) entry_q[j] <= '0;
    end else begin
      head_q  <= head_d;
      tail_q  <= tail_d;
      count_q <= count_d;
      for (int j = 0; j < IDU_INST_BUFFER_SIZE; j++) entry_q[j] <= entry_d[j];
    end
  end

`ifndef SYNTHESIS
  if ((IDU_INST_BUFFER_SIZE & (IDU_INST_BUFFER_SIZE - 1)) != 0) begin : g_pow2_check
    $error("IDU_INST_BUFFER_SIZE must be a power of 2");
  end
`endif

endmodule

`default_nettype wire
