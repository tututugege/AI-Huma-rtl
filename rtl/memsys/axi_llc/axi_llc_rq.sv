`default_nettype none
// Ref: AXI_LLC.cpp  drive_read_responses + enqueue_read_response  (read_resp register + read_resp_q of one master)
// One read-response unit per upstream read master: a shift FIFO of RQC entries whose entry 0 is the response
// register seen by the master.  Entry 0 is `fresh` for one tick after it appears (the master cannot take it in
// that tick); afterwards a tick with `ready` pops it and the queue shifts down.
// Up to three producers enqueue in one tick, in priority order (0 lookup hit, 1 bypass memory response,
// 2 MSHR completion); producer k is accepted if the FIFO still has room after the pop and producers < k.
module axi_llc_rq
  import axi_llc_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  input  logic ready,                          // master takes the response register (up_rd_resp_ready)
  input  logic [2:0] enq_v,
  input  logic [2:0][3:0] enq_id,
  input  logic [2:0][511:0] enq_data,
  output logic [2:0] enq_acc,
  output logic valid_cur,                        // up_rd_resp_valid
  output logic fresh_q,
  output logic [3:0] id_cur,
  output line_t data_cur,
  output logic valid_d                         // response register occupied at the end of this tick
);
  localparam int CW = $clog2(RQC + 1);

  logic [CW-1:0] cnt_q, cnt_d;
  logic fresh_d;
  logic [RQC-1:0][3:0] ent_id_q;
  line_t [RQC-1:0] ent_data_q;

  logic pop;
  logic [CW-1:0] cnt_pop;                      // entries left after the pop
  logic [2:0][CW-1:0] pos;                     // FIFO position producer k writes to
  logic [RQC-1:0] ent_we;
  logic [RQC-1:0][3:0] ent_id_d;
  line_t [RQC-1:0] ent_data_d;

  // pop and acceptance chain
  always_comb begin
    pop = (cnt_q != CW'(0)) && !fresh_q && ready;
    cnt_pop = cnt_q - CW'(pop);
    pos[0] = cnt_pop;
    enq_acc[0] = enq_v[0] && (pos[0] < CW'(RQC));
    pos[1] = pos[0] + CW'(enq_acc[0]);
    enq_acc[1] = enq_v[1] && (pos[1] < CW'(RQC));
    pos[2] = pos[1] + CW'(enq_acc[1]);
    enq_acc[2] = enq_v[2] && (pos[2] < CW'(RQC));
    cnt_d = pos[2] + CW'(enq_acc[2]);
    fresh_d = (pop && cnt_q > CW'(1)) || (cnt_pop == CW'(0) && (|enq_acc));
  end

  // per-entry write enable and data: producer at the entry, else the shifted-down neighbour
  always_comb begin
    for (int e = 0; e < RQC; e++) begin
      ent_we[e] = pop;
      ent_id_d[e] = (e + 1 < RQC) ? ent_id_q[(e + 1) % RQC] : 4'd0;
      ent_data_d[e] = (e + 1 < RQC) ? ent_data_q[(e + 1) % RQC] : '0;
      for (int k = 0; k < 3; k++) begin
        if (enq_acc[k] && pos[k] == CW'(e)) begin
          ent_we[e] = 1'b1;
          ent_id_d[e] = enq_id[k];
          ent_data_d[e] = enq_data[k];
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cnt_q <= '0;
      fresh_q <= 1'b0;
    end else begin
      cnt_q <= cnt_d;
      fresh_q <= fresh_d;
    end
  end

  for (genvar e = 0; e < RQC; e++) begin : g_ent
    always_ff @(posedge clk) begin
      if (ent_we[e]) begin
        ent_id_q[e] <= ent_id_d[e];
        ent_data_q[e] <= ent_data_d[e];
      end
    end
  end

  assign valid_cur = cnt_q != CW'(0);
  assign valid_d = cnt_d != CW'(0);
  assign id_cur = ent_id_q[0];
  assign data_cur = ent_data_q[0];

`ifndef SYNTHESIS
  // the C++ queue is 32 deep; the RTL depth is never reached in any measured run
  assert property (@(posedge clk) disable iff (!rst_n) cnt_d <= CW'(RQD))
    else $error("axi_llc_rq: read response queue full");
`endif
endmodule

`default_nettype wire
