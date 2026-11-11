// Ref: front-end/front_top.cpp  front_comb_calc S5 (fetch_addr FIFO), S8 (predecode + instruction_FIFO write)
`default_nettype none

// Fetch side buffers of the front end: the fetch-address queue that feeds the icache and the instruction queue that
// receives the predecoded fetch groups coming out of the icache.
//   fetch_addr_fifo      : BPU fetch address in, icache request out
//   predecode + seq pc   : combinational on the icache response (8 lanes, valid-prefix sequential next pc)
//   inst_fifo            : predecoded group in (when the icache completes a read and no refetch), checker side out
module front_fetch_buf import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        global_refetch,
  // fetch address queue
  input  logic        fa_rd_en,
  input  logic        fa_wr_en,
  input  logic        fa_drop_tail,
  input  logic [XLEN_BITS-1:0] fa_wr_address,
  output logic        fa_rd_valid,
  output logic [XLEN_BITS-1:0] fa_rd_address,
  output logic        fa_full,
  output logic        fa_empty,
  output logic [$clog2(FETCH_ADDR_FIFO_DEPTH + 1)-1:0] fa_size,
  // icache response
  input  logic        ic_read_complete,
  input  logic [XLEN_BITS-1:0] ic_fetch_pc,
  input  logic [FETCH_WIDTH-1:0] ic_inst_valid,
  input  logic [FETCH_WIDTH-1:0] ic_page_fault_inst,
  input  logic [31:0] ic_fetch_group     [FETCH_WIDTH],
  // instruction queue read side (head of the queue, valid when predecode_can_run)
  input  logic        inst_rd_en,
  output logic        inst_empty,
  output logic [31:0] inst_rd_instructions            [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0] inst_rd_page_fault_inst,
  output logic [FETCH_WIDTH-1:0] inst_rd_inst_valid,
  output logic [1:0]  inst_rd_predecode_type          [FETCH_WIDTH],
  output logic [XLEN_BITS-1:0] inst_rd_predecode_target_address [FETCH_WIDTH],
  output logic [XLEN_BITS-1:0] inst_rd_seq_next_pc
);

  logic [1:0]  predecode_type           [FETCH_WIDTH];
  logic [XLEN_BITS-1:0] predecode_target_address [FETCH_WIDTH];
  logic [XLEN_BITS-1:0] seq_next_pc;
  logic        inst_wr_en;

  fetch_addr_fifo u_fa_fifo (
    .clk, .rst_n,
    .refetch          (global_refetch),
    .rd_en            (fa_rd_en),
    .wr_en            (fa_wr_en),
    .drop_tail        (fa_drop_tail),
    .wr_fetch_address (fa_wr_address),
    .rd_valid         (fa_rd_valid),
    .rd_fetch_address (fa_rd_address),
    .full             (fa_full),
    .empty            (fa_empty),
    .size             (fa_size)
  );

  predecode u_predecode (
    .clk, .rst_n,
    .fetch_pc                 (ic_fetch_pc),
    .inst                     (ic_fetch_group),
    .inst_valid               (ic_inst_valid),
    .predecode_type,
    .predecode_target_address
  );

  sequential_next_pc u_seq_next_pc (
    .clk, .rst_n,
    .fetch_pc    (ic_fetch_pc),
    .inst_valid  (ic_inst_valid),
    .seq_next_pc
  );

  // front_top.cpp:1624 `!inst_fifo_full_for_write && icache_slot0_data_valid && !refetch`; the queue can never be full
  // here (instruction entries <= PTAB entries <= 15, frontend-boundary.md 3.4), so the full term is dropped.
  assign inst_wr_en = ic_read_complete && !global_refetch;

  /* verilator lint_off UNUSEDSIGNAL */
  logic inst_full;       // never full (see above); front_fifo asserts against an overflowing write
  logic inst_rd_valid;   // = predecode_can_run, known to the caller
  /* verilator lint_on UNUSEDSIGNAL */
  inst_fifo u_inst_fifo (
    .clk, .rst_n,
    .refetch                     (global_refetch),
    .rd_en                       (inst_rd_en),
    .wr_en                       (inst_wr_en),
    .wr_instructions             (ic_fetch_group),
    .wr_page_fault_inst          (ic_page_fault_inst),
    .wr_inst_valid               (ic_inst_valid),
    .wr_predecode_type           (predecode_type),
    .wr_predecode_target_address (predecode_target_address),
    .wr_seq_next_pc              (seq_next_pc),
    .rd_valid                    (inst_rd_valid),
    .rd_instructions             (inst_rd_instructions),
    .rd_page_fault_inst          (inst_rd_page_fault_inst),
    .rd_inst_valid               (inst_rd_inst_valid),
    .rd_predecode_type           (inst_rd_predecode_type),
    .rd_predecode_target_address (inst_rd_predecode_target_address),
    .rd_seq_next_pc              (inst_rd_seq_next_pc),
    .full                        (inst_full),
    .empty                       (inst_empty)
  );

endmodule

`default_nettype wire
