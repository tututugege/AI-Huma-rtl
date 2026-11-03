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
  input  logic                    wr_page_fault_inst [FETCH_WIDTH],
  input  logic                    wr_inst_valid  [FETCH_WIDTH],
  input  logic                    wr_predict_dir_corrected [FETCH_WIDTH],
  input  logic [31:0]             wr_predict_base_pc,
  input  logic                    wr_alt_pred    [FETCH_WIDTH],
  input  logic [PCPN_W-1:0]       wr_altpcpn     [FETCH_WIDTH],
  input  logic [PCPN_W-1:0]       wr_pcpn        [FETCH_WIDTH],
  input  logic [TAGE_IDX_W-1:0]   wr_tage_idx    [FETCH_WIDTH][TN_MAX],
  input  logic [TAGE_TAG_W-1:0]   wr_tage_tag    [FETCH_WIDTH][TN_MAX],
  input  logic                    wr_sc_used     [FETCH_WIDTH],
  input  logic                    wr_sc_pred     [FETCH_WIDTH],
  input  logic [SC_SUM_W-1:0]     wr_sc_sum      [FETCH_WIDTH],
  input  logic [SC_IDX_W-1:0]     wr_sc_idx      [FETCH_WIDTH][SC_NTABLE],
  input  logic                    wr_loop_used   [FETCH_WIDTH],
  input  logic                    wr_loop_hit    [FETCH_WIDTH],
  input  logic                    wr_loop_pred   [FETCH_WIDTH],
  input  logic [LOOP_IDX_W-1:0]   wr_loop_idx    [FETCH_WIDTH],
  input  logic [LOOP_TAG_W-1:0]   wr_loop_tag    [FETCH_WIDTH],
  input  logic [31:0]             wr_predict_next_fetch_address_corrected,
  output logic                    rd_valid,
  output logic [31:0]             rd_fetch_group [FETCH_WIDTH],
  output logic                    rd_page_fault_inst [FETCH_WIDTH],
  output logic                    rd_inst_valid  [FETCH_WIDTH],
  output logic                    rd_predict_dir_corrected [FETCH_WIDTH],
  output logic [31:0]             rd_predict_base_pc,
  output logic                    rd_alt_pred    [FETCH_WIDTH],
  output logic [PCPN_W-1:0]       rd_altpcpn     [FETCH_WIDTH],
  output logic [PCPN_W-1:0]       rd_pcpn        [FETCH_WIDTH],
  output logic [TAGE_IDX_W-1:0]   rd_tage_idx    [FETCH_WIDTH][TN_MAX],
  output logic [TAGE_TAG_W-1:0]   rd_tage_tag    [FETCH_WIDTH][TN_MAX],
  output logic                    rd_sc_used     [FETCH_WIDTH],
  output logic                    rd_sc_pred     [FETCH_WIDTH],
  output logic [SC_SUM_W-1:0]     rd_sc_sum      [FETCH_WIDTH],
  output logic [SC_IDX_W-1:0]     rd_sc_idx      [FETCH_WIDTH][SC_NTABLE],
  output logic                    rd_loop_used   [FETCH_WIDTH],
  output logic                    rd_loop_hit    [FETCH_WIDTH],
  output logic                    rd_loop_pred   [FETCH_WIDTH],
  output logic [LOOP_IDX_W-1:0]   rd_loop_idx    [FETCH_WIDTH],
  output logic [LOOP_TAG_W-1:0]   rd_loop_tag    [FETCH_WIDTH],
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
      wr_entry.meta.sc_used[i]      = wr_sc_used[i];
      wr_entry.meta.sc_pred[i]      = wr_sc_pred[i];
      wr_entry.meta.sc_sum[i]       = wr_sc_sum[i];
      wr_entry.meta.loop_used[i]    = wr_loop_used[i];
      wr_entry.meta.loop_hit[i]     = wr_loop_hit[i];
      wr_entry.meta.loop_pred[i]    = wr_loop_pred[i];
      wr_entry.meta.loop_idx[i]     = wr_loop_idx[i];
      wr_entry.meta.loop_tag[i]     = wr_loop_tag[i];
      for (int j = 0; j < TN_MAX; j++) begin
        wr_entry.meta.tage_idx[i][j] = wr_tage_idx[i][j];
        wr_entry.meta.tage_tag[i][j] = wr_tage_tag[i][j];
      end
      for (int t = 0; t < SC_NTABLE; t++) wr_entry.meta.sc_idx[i][t] = wr_sc_idx[i][t];
      rd_fetch_group[i]            = rd_entry.fetch_group[i];
      rd_page_fault_inst[i]        = rd_entry.page_fault_inst[i];
      rd_inst_valid[i]             = rd_entry.inst_valid[i];
      rd_predict_dir_corrected[i]  = rd_entry.predict_dir_corrected[i];
      rd_alt_pred[i]          = rd_entry.meta.alt_pred[i];
      rd_altpcpn[i]           = rd_entry.meta.altpcpn[i];
      rd_pcpn[i]              = rd_entry.meta.pcpn[i];
      rd_sc_used[i]           = rd_entry.meta.sc_used[i];
      rd_sc_pred[i]           = rd_entry.meta.sc_pred[i];
      rd_sc_sum[i]            = rd_entry.meta.sc_sum[i];
      rd_loop_used[i]         = rd_entry.meta.loop_used[i];
      rd_loop_hit[i]          = rd_entry.meta.loop_hit[i];
      rd_loop_pred[i]         = rd_entry.meta.loop_pred[i];
      rd_loop_idx[i]          = rd_entry.meta.loop_idx[i];
      rd_loop_tag[i]          = rd_entry.meta.loop_tag[i];
      for (int j = 0; j < TN_MAX; j++) begin
        rd_tage_idx[i][j] = rd_entry.meta.tage_idx[i][j];
        rd_tage_tag[i][j] = rd_entry.meta.tage_tag[i][j];
      end
      for (int t = 0; t < SC_NTABLE; t++) rd_sc_idx[i][t] = rd_entry.meta.sc_idx[i][t];
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
