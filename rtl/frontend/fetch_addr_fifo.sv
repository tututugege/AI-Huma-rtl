// Ref: front-end/fifo/fetch_address_FIFO.cpp  fetch_address_FIFO_comb + FetchAddressFifoModel
`default_nettype none

// fetch_address_FIFO: 16 x 32b queue of BPU fetch addresses waiting for the icache.  Port adaptation only.
module fetch_addr_fifo import front_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        refetch,
  input  logic        rd_en,
  input  logic        wr_en,
  input  logic        drop_tail,
  input  logic [31:0] wr_fetch_address,
  output logic        rd_valid,
  output logic [31:0] rd_fetch_address,
  output logic        full,
  output logic        empty,
  output logic [$clog2(FETCH_ADDR_FIFO_DEPTH + 1)-1:0] size
);

  front_fifo #(.DEPTH(FETCH_ADDR_FIFO_DEPTH), .W(32), .FULL_AT(FETCH_ADDR_FIFO_FULL_AT)) u_fifo (
    .clk, .rst_n,
    .clear   (refetch),
    .rd_en, .wr_en, .drop_tail,
    .wdata   (wr_fetch_address),
    .rd_valid,
    .rdata   (rd_fetch_address),
    .full, .empty, .size
  );

endmodule

`default_nettype wire
