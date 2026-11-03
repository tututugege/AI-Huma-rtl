`default_nettype none
// Ref: AXI_Interconnect.cpp  seq (llc_read_resp_* registers, w_resp_* registers, llc_write_resp_delay),
//   prepare_llc_inputs
// Response boundary between the LLC and the masters.
// read : one register per master; filled from the LLC when empty and not "fresh"; emptied when the master's
//   resp.ready is high.
// write: LLC response -> 2-entry delay line (an entry becomes poppable one tick after it was pushed) -> w_resp
//   register ->
//          emptied by the master's resp.ready.
module axi_ic_resp
  import axi_ic_pkg::*;
(
  input  logic          clk,
  input  logic          rst_n,
  // LLC outputs
  input  logic          lo_rd_valid [NR],
  input  logic [3:0]    lo_rd_id    [NR],
  input  logic [511:0]  lo_rd_data  [NR],
  input  logic          hz_rd_fresh [NR],
  input  logic          lo_wr_valid [NW],
  input  logic [3:0]    lo_wr_id    [NW],
  input  logic [1:0]    lo_wr_resp  [NW],
  // master side
  input  logic          m_rd_ready [NR],
  input  logic          m_wr_ready [NW],
  output logic          rr_v    [NR],
  output logic [3:0]    rr_id   [NR],
  output logic [511:0]  rr_data [NR],
  output logic          wr_v    [NW],
  output logic [3:0]    wr_id   [NW],
  output logic [1:0]    wr_resp [NW],
  // to the LLC
  output logic          li_rd_ready [NR],
  output logic          li_wr_ready [NW]
);
  // ---------------- read responses ----------------
  for (genvar i = 0; i < NR; i++) begin : g_r
    logic        v_q, v_d;
    logic [3:0]  id_q, id_d;
    logic [511:0] data_q, data_d;
    logic take;
    assign li_rd_ready[i] = !v_q && !hz_rd_fresh[i];
    assign take = lo_rd_valid[i] && li_rd_ready[i];
    always_comb begin
      v_d = v_q; id_d = id_q; data_d = data_q;
      if (take) begin v_d = 1'b1; id_d = lo_rd_id[i]; data_d = lo_rd_data[i]; end
      else if (v_q && m_rd_ready[i]) begin v_d = 1'b0; id_d = 4'd0; data_d = '0; end
    end
    always_ff @(posedge clk) begin
      if (!rst_n) begin v_q <= 1'b0; id_q <= 4'd0; data_q <= '0; end
      else        begin v_q <= v_d;  id_q <= id_d;  data_q <= data_d; end
    end
    assign rr_v[i] = v_q;
    assign rr_id[i] = id_q;
    assign rr_data[i] = data_q;
  end

  // ---------------- write responses ----------------
  for (genvar i = 0; i < NW; i++) begin : g_w
    logic        v_q, v_d;
    logic [3:0]  id_q, id_d;
    logic [1:0]  rs_q, rs_d;
    // delay line: entry 0 = oldest; aged_q[k] = the entry has been through a seq already
    logic [1:0]  cnt_q, cnt_d;
    logic [3:0]  dl_id_q   [2];
    logic [1:0]  dl_rs_q   [2];
    logic [3:0]  dl_id_d   [2];
    logic [1:0]  dl_rs_d   [2];
    logic        pop, v_after_clear, push;
    assign li_wr_ready[i] = !v_q && (cnt_q < 2'd2);
    assign push = lo_wr_valid[i] && li_wr_ready[i];
    assign v_after_clear = v_q && !m_wr_ready[i] ? 1'b1 : 1'b0;
    // every entry present before this tick is aged (age 1) by now; the entry pushed this tick is not poppable yet
    assign pop = (cnt_q != 2'd0) && !v_after_clear;
    always_comb begin
      v_d = v_q; id_d = id_q; rs_d = rs_q;
      cnt_d = cnt_q;
      for (int k = 0; k < 2; k++) begin dl_id_d[k] = dl_id_q[k]; dl_rs_d[k] = dl_rs_q[k]; end
      if (v_q && m_wr_ready[i]) begin v_d = 1'b0; id_d = 4'd0; rs_d = 2'd0; end
      if (pop) begin
        v_d = 1'b1; id_d = dl_id_q[0]; rs_d = dl_rs_q[0];
        dl_id_d[0] = dl_id_q[1]; dl_rs_d[0] = dl_rs_q[1];
        cnt_d = cnt_q - 2'd1;
      end
      if (push) begin
        dl_id_d[cnt_d[0]] = lo_wr_id[i];
        dl_rs_d[cnt_d[0]] = lo_wr_resp[i];
        cnt_d = cnt_d + 2'd1;
      end
    end
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        v_q <= 1'b0; id_q <= 4'd0; rs_q <= 2'd0; cnt_q <= 2'd0;
        for (int k = 0; k < 2; k++) begin dl_id_q[k] <= 4'd0; dl_rs_q[k] <= 2'd0; end
      end else begin
        v_q <= v_d; id_q <= id_d; rs_q <= rs_d; cnt_q <= cnt_d;
        for (int k = 0; k < 2; k++) begin dl_id_q[k] <= dl_id_d[k]; dl_rs_q[k] <= dl_rs_d[k]; end
      end
    end
    assign wr_v[i] = v_q;
    assign wr_id[i] = id_q;
    assign wr_resp[i] = rs_q;
  end
endmodule

`default_nettype wire
