`default_nettype none
// Ref: AXI_LLC.cpp  merge_write_into_line
// Bytes of `data` selected by `strb` are placed at byte offset addr[5:0] of `base` (at most `size`+1 bytes and
// never past the end of the line).
module axi_llc_merge
  import axi_llc_pkg::*;
(
  input  line_t base,
  input  logic [5:0] offset,
  input  line_t data,
  input  logic [63:0] strb,
  input  logic [7:0] size,
  output line_t merged
);
  logic [6:0] limit;

  always_comb begin
    limit = 7'd64 - {1'b0, offset};
    if ({1'b0, size} + 9'd1 < {2'b0, limit}) limit = size[6:0] + 7'd1;
    merged = base;
    for (int b = 0; b < 64; b++) begin
      if (7'(b) < limit && strb[b]) merged[(32'(offset) + b) * 8 +: 8] = data[b * 8 +: 8];
    end
  end
endmodule

`default_nettype wire
