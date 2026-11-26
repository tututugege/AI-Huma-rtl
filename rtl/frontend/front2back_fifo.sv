// Ref: front-end/fifo/front2bank_FIFO.cpp  front2back_FIFO_comb + model
`default_nettype none

// front2back_FIFO: queue of checked fetch groups waiting for the back end (compact 2-taken {is_pair, base_b, a_len}).
module front2back_fifo import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    refetch,
  input  logic                    rd_en,
  input  logic                    wr_en,
  input  logic [31:0]             wr_fetch_group [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0]  wr_page_fault_inst,
  input  logic [FETCH_WIDTH-1:0]  wr_pf_inst_hi,
  input  logic [FETCH_WIDTH-1:0]  wr_inst_valid,
  input  logic [FETCH_WIDTH-1:0]  wr_predict_dir_corrected,
  input  logic [XLEN_BITS-1:0]    wr_predict_base_pc,
  input  logic                    wr_is_pair,
  input  logic [XLEN_BITS-1:0]    wr_base_b,
  input  logic [3:0]              wr_a_len,
  input  logic [FETCH_WIDTH-1:0]  wr_alt_pred,
  input  logic [PCPN_W-1:0]       wr_pcpn        [FETCH_WIDTH],
  input  logic [BLK_ID_W-1:0]     wr_blk_id,
  input  logic [XLEN_BITS-1:0]    wr_predict_next_fetch_address_corrected,
  input  logic [FETCH_WIDTH-1:0][KIND_W-1:0] wr_slot_kind,
  input  logic [FETCH_WIDTH-1:0]  wr_is_rvc,
  input  logic                    wr_carry,
  output logic                    rd_valid,
  output logic [31:0]             rd_fetch_group [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0]  rd_page_fault_inst,
  output logic [FETCH_WIDTH-1:0]  rd_pf_inst_hi,
  output logic [FETCH_WIDTH-1:0]  rd_inst_valid,
  output logic [FETCH_WIDTH-1:0]  rd_predict_dir_corrected,
  output logic [XLEN_BITS-1:0]    rd_predict_base_pc,
  output logic                    rd_is_pair,
  output logic [XLEN_BITS-1:0]    rd_base_b,
  output logic [3:0]              rd_a_len,
  output logic [FETCH_WIDTH-1:0]  rd_alt_pred,
  output logic [PCPN_W-1:0]       rd_pcpn        [FETCH_WIDTH],
  output logic [BLK_ID_W-1:0]     rd_blk_id,
  output logic [XLEN_BITS-1:0]    rd_predict_next_fetch_address_corrected,
  output logic [FETCH_WIDTH-1:0][KIND_W-1:0] rd_slot_kind,
  output logic [FETCH_WIDTH-1:0]  rd_is_rvc,
  output logic                    rd_carry,
  output logic                    full,
  output logic                    empty
);

  f2b_fifo_entry_t wr_entry;
  f2b_fifo_entry_t rd_entry;

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      wr_entry.fetch_group[i]           = wr_fetch_group[i];
      wr_entry.page_fault_inst[i]       = wr_page_fault_inst[i];
      wr_entry.pf_inst_hi[i]            = wr_pf_inst_hi[i];
      wr_entry.inst_valid[i]            = wr_inst_valid[i];
      wr_entry.predict_dir_corrected[i] = wr_predict_dir_corrected[i];
      wr_entry.is_rvc[i]                = wr_is_rvc[i];
      rd_is_rvc[i]                      = rd_entry.is_rvc[i];
      wr_entry.meta.alt_pred[i]         = wr_alt_pred[i];
      wr_entry.meta.pcpn[i]             = wr_pcpn[i];
      rd_fetch_group[i]                 = rd_entry.fetch_group[i];
      rd_page_fault_inst[i]             = rd_entry.page_fault_inst[i];
      rd_pf_inst_hi[i]                  = rd_entry.pf_inst_hi[i];
      rd_inst_valid[i]                  = rd_entry.inst_valid[i];
      rd_predict_dir_corrected[i]       = rd_entry.predict_dir_corrected[i];
      rd_alt_pred[i]                    = rd_entry.meta.alt_pred[i];
      rd_pcpn[i]                        = rd_entry.meta.pcpn[i];
    end
    wr_entry.carry                                = wr_carry;
    rd_carry                                      = rd_entry.carry;
    wr_entry.is_pair                              = wr_is_pair;
    wr_entry.base_b                               = wr_base_b;
    wr_entry.a_len                                = wr_a_len;
    rd_is_pair                                    = rd_entry.is_pair;
    rd_base_b                                     = rd_entry.base_b;
    rd_a_len                                      = rd_entry.a_len;
    wr_entry.meta.blk_id                          = wr_blk_id;
    rd_blk_id                                     = rd_entry.meta.blk_id;
    wr_entry.slot_kind                            = wr_slot_kind;
    rd_slot_kind                                  = rd_entry.slot_kind;
    wr_entry.meta.predict_base_pc                 = wr_predict_base_pc;
    wr_entry.predict_next_fetch_address_corrected = wr_predict_next_fetch_address_corrected;
    rd_predict_base_pc                            = rd_entry.meta.predict_base_pc;
    rd_predict_next_fetch_address_corrected       = rd_entry.predict_next_fetch_address_corrected;
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic [$clog2(F2B_FIFO_DEPTH + 1)-1:0] size_unused;
  logic head_fresh_unused;
  f2b_fifo_entry_t next_rdata_unused;
  /* verilator lint_on UNUSEDSIGNAL */

  front_fifo #(.DEPTH(F2B_FIFO_DEPTH), .W($bits(f2b_fifo_entry_t)), .FULL_AT(F2B_FIFO_FULL_AT)) u_fifo (
    .clk, .rst_n,
    .clear   (refetch),
    .rd_en, .wr_en, .drop_tail(1'b0),
    .wdata   (wr_entry),
    .rd_valid,
    .rdata   (rd_entry),
    .next_rdata (next_rdata_unused),
    .full, .empty, .size(size_unused), .head_fresh(head_fresh_unused)
  );

endmodule

`default_nettype wire
