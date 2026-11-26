// Ref: back-end/PreIduQueue.cpp  class PreIduQueue  comb_accept_front / comb_fire (control part)
`default_nettype none

// Front-end handshake and ibuf-update control (FTQ entry already allocated at BPU S0 in Unified FTQ-64).
module ftq_ibuf_ctrl import ttg_cfg_pkg::*; import ftq_ibuf_pkg::*; (
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic [BACKEND_FETCH_WIDTH-1:0] front_valid,
  input  logic                      br_mispred,         // idu br_latch.mispred (a register in Idu)
  input  logic                      rob_flush,          // rob_bcast.flush of THIS cycle
  input  logic [IB_COUNT_W-1:0]     ib_count,
  input  logic [DECODE_WIDTH-1:0]   idu_fire,
  output logic                      ready,
  output logic [BACKEND_FETCH_WIDTH-1:0] fire,
  output logic [LANE_CNT_W-1:0]     lane_rank [BACKEND_FETCH_WIDTH],  // valid lanes below this one
  output logic [BACKEND_FETCH_WIDTH-1:0] lane_is_last,  // highest valid lane of the group
  output logic [LANE_CNT_W-1:0]     push_cnt,
  output logic                      queue_clear,        // flush or mispredict: drop the whole InstructionBuffer
  output logic [DECODE_CNT_W-1:0]   ib_pop_cnt
);

  logic flush_prev_q;
  logic flush_prev_d;

  logic [LANE_CNT_W-1:0] incoming;
  logic [IB_COUNT_W-1:0] ib_free;
  logic                  ib_has_room;

  ttg_popcount #(.N(BACKEND_FETCH_WIDTH)) u_incoming (.bits(front_valid), .count(incoming));

  assign flush_prev_d = rob_flush;
  assign ib_free      = IB_COUNT_W'(IDU_INST_BUFFER_SIZE) - ib_count;
  assign ib_has_room  = IB_COUNT_W'(incoming) <= ib_free;
  assign ready        = !br_mispred && !flush_prev_q && ib_has_room;
  assign fire         = front_valid & {BACKEND_FETCH_WIDTH{ready}};
  assign push_cnt     = ready ? incoming : '0;
  assign queue_clear  = rob_flush || br_mispred;

  // Rank of each lane inside the group and the group's last lane: pure prefix/suffix masks of front_valid.
  for (genvar i = 0; i < BACKEND_FETCH_WIDTH; i++) begin : g_lane
    localparam logic [BACKEND_FETCH_WIDTH-1:0] BELOW = BACKEND_FETCH_WIDTH'((64'd1 << i) - 64'd1);
    localparam logic [BACKEND_FETCH_WIDTH-1:0] ABOVE = ~BELOW & ~(BACKEND_FETCH_WIDTH'(64'd1) << i);
    ttg_popcount #(.N(BACKEND_FETCH_WIDTH)) u_rank (.bits(front_valid & BELOW), .count(lane_rank[i]));
    assign lane_is_last[i] = front_valid[i] && ((front_valid & ABOVE) == '0);
  end

  // Idu consumes a prefix of the issue group: number of leading ones of idu_fire.
  logic [DECODE_WIDTH-1:0] fire_prefix;
  for (genvar i = 0; i < DECODE_WIDTH; i++) begin : g_prefix
    if (i == 0) begin : g_first
      assign fire_prefix[i] = idu_fire[i];
    end else begin : g_next
      assign fire_prefix[i] = fire_prefix[i-1] && idu_fire[i];
    end
  end
  ttg_popcount #(.N(DECODE_WIDTH)) u_ib_pop (.bits(fire_prefix), .count(ib_pop_cnt));

  always_ff @(posedge clk) begin
    if (!rst_n) flush_prev_q <= 1'b0;
    else        flush_prev_q <= flush_prev_d;
  end

endmodule

`default_nettype wire
