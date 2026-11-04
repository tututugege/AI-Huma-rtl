// Ref: front-end/fifo/instruction_FIFO.cpp  instruction_FIFO_comb + model
`default_nettype none

// instruction_FIFO: 16 x 576b queue of predecoded fetch groups.  Port adaptation only (the per-lane debug pc of the
// C++ entry is not stored: its only reader is an exit(1) consistency check, front_top.cpp:1737).
module inst_fifo import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        refetch,
  input  logic        rd_en,
  input  logic        wr_en,
  input  logic [31:0] wr_instructions            [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0] wr_page_fault_inst,
  input  logic [FETCH_WIDTH-1:0] wr_inst_valid,
  input  logic [1:0]  wr_predecode_type          [FETCH_WIDTH],
  input  logic [31:0] wr_predecode_target_address [FETCH_WIDTH],
  input  logic [31:0] wr_seq_next_pc,
  output logic        rd_valid,
  output logic [31:0] rd_instructions            [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0] rd_page_fault_inst,
  output logic [FETCH_WIDTH-1:0] rd_inst_valid,
  output logic [1:0]  rd_predecode_type          [FETCH_WIDTH],
  output logic [31:0] rd_predecode_target_address [FETCH_WIDTH],
  output logic [31:0] rd_seq_next_pc,
  output logic        full,
  output logic        empty
);

  inst_fifo_entry_t wr_entry;
  inst_fifo_entry_t rd_entry;

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      wr_entry.instructions[i]             = wr_instructions[i];
      wr_entry.page_fault_inst[i]          = wr_page_fault_inst[i];
      wr_entry.inst_valid[i]               = wr_inst_valid[i];
      wr_entry.predecode_type[i]           = wr_predecode_type[i];
      wr_entry.predecode_target_address[i] = wr_predecode_target_address[i];
      rd_instructions[i]             = rd_entry.instructions[i];
      rd_page_fault_inst[i]          = rd_entry.page_fault_inst[i];
      rd_inst_valid[i]               = rd_entry.inst_valid[i];
      rd_predecode_type[i]           = rd_entry.predecode_type[i];
      rd_predecode_target_address[i] = rd_entry.predecode_target_address[i];
    end
    wr_entry.seq_next_pc = wr_seq_next_pc;
    rd_seq_next_pc       = rd_entry.seq_next_pc;
  end

  front_fifo #(.DEPTH(INST_FIFO_DEPTH), .W($bits(inst_fifo_entry_t)), .FULL_AT(INST_FIFO_FULL_AT)) u_fifo (
    .clk, .rst_n,
    .clear   (refetch),
    .rd_en, .wr_en,
    .wdata   (wr_entry),
    .rd_valid,
    .rdata   (rd_entry),
    .full, .empty
  );

endmodule

`default_nettype wire
