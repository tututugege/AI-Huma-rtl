// Ref: front-end/fifo/fetch_address_FIFO.cpp  fetch_address_FIFO_comb + FetchAddressFifoModel
`default_nettype none

// fetch_address_FIFO: queue of BPU fetch addresses + optional 2-taken FetchPair descriptors waiting for the icache.
module fetch_addr_fifo import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        refetch,
  input  logic        rd_en,
  input  logic        wr_en,
  input  logic        drop_tail,
  input  logic [XLEN_BITS-1:0] wr_fetch_address,
  input  fetch_pair_t wr_pair,
  output logic        rd_valid,
  output logic [XLEN_BITS-1:0] rd_fetch_address,
  output fetch_pair_t rd_pair,
  output logic [XLEN_BITS-1:0] next_rd_address,
  output fetch_pair_t next_rd_pair,
  output logic        full,
  output logic        empty,
  output logic [$clog2(FETCH_ADDR_FIFO_DEPTH + 1)-1:0] size,
  output logic        head_fresh
);

  typedef struct packed {
    fetch_pair_t          pair;
    logic [XLEN_BITS-1:0] addr;
  } fa_entry_t;

  fa_entry_t wdata, rdata, next_rdata;
  assign wdata            = '{pair: wr_pair, addr: wr_fetch_address};
  assign rd_fetch_address = rdata.addr;
  assign rd_pair          = rdata.pair;
  assign next_rd_address  = next_rdata.addr;
  assign next_rd_pair     = next_rdata.pair;

  front_fifo #(.DEPTH(FETCH_ADDR_FIFO_DEPTH), .W($bits(fa_entry_t)), .FULL_AT(FETCH_ADDR_FIFO_FULL_AT)) u_fifo (
    .clk, .rst_n,
    .clear   (refetch),
    .rd_en, .wr_en, .drop_tail,
    .wdata,
    .rd_valid,
    .rdata,
    .next_rdata,
    .full, .empty, .size, .head_fresh
  );

endmodule

`default_nettype wire
