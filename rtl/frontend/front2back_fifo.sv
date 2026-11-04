// Ref: front-end/fifo/front2bank_FIFO.cpp  front2back_FIFO_comb + model
`default_nettype none

// front2back_FIFO: 32 x 2424b queue of checked fetch groups waiting for the back end.  Port adaptation only.
// The entry keeps the lane-0 pc: lane i of the C++ entry is lane0 + 4*i (it is copied from the PTAB entry), so the
// per-lane pc ports of the C++ interface are replaced by the single base pc.
module front2back_fifo import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    refetch,
  input  logic                    rd_en,
  input  logic                    wr_en,
  input  logic [31:0]             wr_fetch_group [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0] wr_page_fault_inst,
  input  logic [FETCH_WIDTH-1:0] wr_inst_valid,
  input  logic [FETCH_WIDTH-1:0] wr_predict_dir_corrected,
  input  logic [31:0]             wr_predict_base_pc,
  input  logic [FETCH_WIDTH-1:0] wr_alt_pred,
  input  logic [PCPN_W-1:0]       wr_altpcpn     [FETCH_WIDTH],
  input  logic [PCPN_W-1:0]       wr_pcpn        [FETCH_WIDTH],
  input  logic [TAGE_IDX_W-1:0]   wr_tage_idx    [FETCH_WIDTH][TN_MAX],
  input  logic [TAGE_TAG_W-1:0]   wr_tage_tag    [FETCH_WIDTH][TN_MAX],
  input  logic [31:0]             wr_predict_next_fetch_address_corrected,
  output logic                    rd_valid,
  output logic [31:0]             rd_fetch_group [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0] rd_page_fault_inst,
  output logic [FETCH_WIDTH-1:0] rd_inst_valid,
  output logic [FETCH_WIDTH-1:0] rd_predict_dir_corrected,
  output logic [31:0]             rd_predict_base_pc,
  output logic [FETCH_WIDTH-1:0] rd_alt_pred,
  output logic [PCPN_W-1:0]       rd_altpcpn     [FETCH_WIDTH],
  output logic [PCPN_W-1:0]       rd_pcpn        [FETCH_WIDTH],
  output logic [TAGE_IDX_W-1:0]   rd_tage_idx    [FETCH_WIDTH][TN_MAX],
  output logic [TAGE_TAG_W-1:0]   rd_tage_tag    [FETCH_WIDTH][TN_MAX],
  output logic [31:0]             rd_predict_next_fetch_address_corrected,
  output logic                    full,
  output logic                    empty
);

  f2b_fifo_entry_t wr_entry;
  f2b_fifo_entry_t rd_entry;

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      wr_entry.fetch_group[i]            = wr_fetch_group[i];
      wr_entry.page_fault_inst[i]        = wr_page_fault_inst[i];
      wr_entry.inst_valid[i]             = wr_inst_valid[i];
      wr_entry.predict_dir_corrected[i]  = wr_predict_dir_corrected[i];
      wr_entry.meta.alt_pred[i]     = wr_alt_pred[i];
      wr_entry.meta.altpcpn[i]      = wr_altpcpn[i];
      wr_entry.meta.pcpn[i]         = wr_pcpn[i];
      for (int j = 0; j < TN_MAX; j++) begin
        wr_entry.meta.tage_idx[i][j] = wr_tage_idx[i][j];
        wr_entry.meta.tage_tag[i][j] = wr_tage_tag[i][j];
      end
      rd_fetch_group[i]            = rd_entry.fetch_group[i];
      rd_page_fault_inst[i]        = rd_entry.page_fault_inst[i];
      rd_inst_valid[i]             = rd_entry.inst_valid[i];
      rd_predict_dir_corrected[i]  = rd_entry.predict_dir_corrected[i];
      rd_alt_pred[i]          = rd_entry.meta.alt_pred[i];
      rd_altpcpn[i]           = rd_entry.meta.altpcpn[i];
      rd_pcpn[i]              = rd_entry.meta.pcpn[i];
      for (int j = 0; j < TN_MAX; j++) begin
        rd_tage_idx[i][j] = rd_entry.meta.tage_idx[i][j];
        rd_tage_tag[i][j] = rd_entry.meta.tage_tag[i][j];
      end
    end
    wr_entry.meta.predict_base_pc                   = wr_predict_base_pc;
    wr_entry.predict_next_fetch_address_corrected   = wr_predict_next_fetch_address_corrected;
    rd_predict_base_pc                              = rd_entry.meta.predict_base_pc;
    rd_predict_next_fetch_address_corrected         = rd_entry.predict_next_fetch_address_corrected;
  end

  front_fifo #(.DEPTH(F2B_FIFO_DEPTH), .W($bits(f2b_fifo_entry_t)), .FULL_AT(F2B_FIFO_FULL_AT)) u_fifo (
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
