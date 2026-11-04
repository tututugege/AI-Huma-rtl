`default_nettype none
// Ref: AXI_LLC.cpp  drive_write_path (memory write channel: victim write-back, bypass write issue)
// Memory write request mux: a victim write-back (full line, strobe all ones, id 0) has priority; otherwise the
// bypass write picked by the write scheduler is sent with its own address (byte address), strobe, size and id.
module axi_llc_memwr
  import axi_llc_pkg::*;
(
  input  logic v_valid,
  input  addr_t v_addr,
  input  line_t v_data,
  input  logic [NW-1:0] bp_grant,
  input  logic [NW-1:0][31:0] bp_addr,
  input  logic [NW-1:0][511:0] bp_data,
  input  logic [NW-1:0][63:0] bp_strb,
  input  logic [NW-1:0][7:0] bp_size,
  input  logic [NW-1:0][3:0] bp_id,
  output logic mwr_v,
  output addr_t mwr_addr,
  output line_t mwr_data,
  output logic [63:0] mwr_strb,
  output logic [7:0] mwr_size,
  output logic [3:0] mwr_id
);
  always_comb begin
    mwr_v = v_valid || (|bp_grant);
    mwr_addr = v_addr;
    mwr_data = v_data;
    mwr_strb = '1;
    mwr_size = 8'd63;
    mwr_id = 4'd0;
    if (!v_valid) begin
      mwr_addr = '0;
      mwr_data = '0;
      mwr_strb = '0;
      mwr_size = '0;
      mwr_id = '0;
      for (int w = 0; w < NW; w++) begin
        mwr_addr |= bp_addr[w] & {32{bp_grant[w]}};
        mwr_data |= bp_data[w] & {512{bp_grant[w]}};
        mwr_strb |= bp_strb[w] & {64{bp_grant[w]}};
        mwr_size |= bp_size[w] & {8{bp_grant[w]}};
        mwr_id |= bp_id[w] & {4{bp_grant[w]}};
      end
    end
  end
endmodule

`default_nettype wire
