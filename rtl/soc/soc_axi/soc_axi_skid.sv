// Ref: docs/modules/soc_axi.md  Full-throughput 2-entry AXI4 skid buffer (breaks valid & ready paths)
`default_nettype none

// Classic 2-stage skid buffer:
//   - 0 combinational path from s_valid/s_data to m_valid/m_data (registered output)
//   - 0 combinational path from m_ready to s_ready (registered ready)
//   - 100% throughput (1 transfer/cycle, zero bubbles)
module soc_axi_skid #(
  parameter int WIDTH = 32
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             s_valid,
  output logic             s_ready,
  input  logic [WIDTH-1:0] s_data,
  output logic             m_valid,
  input  logic             m_ready,
  output logic [WIDTH-1:0] m_data
);

  logic             out_v_q, out_v_d;
  logic [WIDTH-1:0] out_d_q, out_d_d;
  logic             skid_v_q, skid_v_d;
  logic [WIDTH-1:0] skid_d_q, skid_d_d;

  assign s_ready = !skid_v_q;
  assign m_valid = out_v_q;
  assign m_data  = out_d_q;

  always_comb begin
    logic s_fire, m_fire;
    s_fire   = s_valid && !skid_v_q;
    m_fire   = out_v_q && m_ready;
    out_v_d  = out_v_q;
    out_d_d  = out_d_q;
    skid_v_d = skid_v_q;
    skid_d_d = skid_d_q;

    if (!out_v_q) begin
      // Output empty (skid is also empty): direct load into output
      if (s_fire) begin
        out_v_d = 1'b1;
        out_d_d = s_data;
      end
    end else if (m_fire) begin
      // Output drained: promote skid if present, else accept new input
      if (skid_v_q) begin
        out_v_d  = 1'b1;
        out_d_d  = skid_d_q;
        skid_v_d = 1'b0;
      end else if (s_fire) begin
        out_v_d  = 1'b1;
        out_d_d  = s_data;
      end else begin
        out_v_d  = 1'b0;
      end
    end else begin
      // Output stalled: capture incoming beat into skid slot
      if (s_fire) begin
        skid_v_d = 1'b1;
        skid_d_d = s_data;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_v_q  <= 1'b0;
      out_d_q  <= '0;
      skid_v_q <= 1'b0;
      skid_d_q <= '0;
    end else begin
      out_v_q  <= out_v_d;
      out_d_q  <= out_d_d;
      skid_v_q <= skid_v_d;
      skid_d_q <= skid_d_d;
    end
  end

endmodule

`default_nettype wire
