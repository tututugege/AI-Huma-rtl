// Ref: front-end/fifo/PTAB.cpp  PTAB_comb + model; front_top.cpp front_ptab_write_comb
`default_nettype none

// PTAB: 16 x 2152b queue of BPU predictions (one per fetch group).  Port adaptation only.
// The entry keeps the lane-0 pc: lane i of the C++ entry is lane0 + 4*i by construction (front_ptab_write_comb), so
// the per-lane pc ports of the C++ interface are replaced by the single base pc.
module ptab import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    refetch,
  input  logic                    rd_en,
  input  logic                    wr_en,
  input  logic [XLEN_BITS-1:0]             wr_predict_next_fetch_address,
  input  logic [FETCH_WIDTH-1:0] wr_predict_dir,
  input  logic [XLEN_BITS-1:0]             wr_predict_base_pc,
  input  logic [FETCH_WIDTH-1:0] wr_alt_pred,
  input  logic [PCPN_W-1:0]       wr_altpcpn     [FETCH_WIDTH],
  input  logic [PCPN_W-1:0]       wr_pcpn        [FETCH_WIDTH],
  input  logic [TAGE_IDX_W-1:0]   wr_tage_idx    [FETCH_WIDTH][TN_MAX],
  input  logic [TAGE_TAG_W-1:0]   wr_tage_tag    [FETCH_WIDTH][TN_MAX],
  input  logic [BCK_W-1:0]        wr_bpu_ck,
  output logic                    rd_valid,
  output logic [XLEN_BITS-1:0]             rd_predict_next_fetch_address,
  output logic [FETCH_WIDTH-1:0] rd_predict_dir,
  output logic [XLEN_BITS-1:0]             rd_predict_base_pc,
  output logic [FETCH_WIDTH-1:0] rd_alt_pred,
  output logic [PCPN_W-1:0]       rd_altpcpn     [FETCH_WIDTH],
  output logic [PCPN_W-1:0]       rd_pcpn        [FETCH_WIDTH],
  output logic [TAGE_IDX_W-1:0]   rd_tage_idx    [FETCH_WIDTH][TN_MAX],
  output logic [TAGE_TAG_W-1:0]   rd_tage_tag    [FETCH_WIDTH][TN_MAX],
  output logic [BCK_W-1:0]        rd_bpu_ck,
  output logic                    full,
  output logic                    empty,
  output logic [$clog2(PTAB_DEPTH + 1)-1:0] size
);

  ptab_entry_t wr_entry;
  ptab_entry_t rd_entry;

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      wr_entry.predict_dir[i]       = wr_predict_dir[i];
      wr_entry.meta.alt_pred[i]     = wr_alt_pred[i];
      wr_entry.meta.altpcpn[i]      = wr_altpcpn[i];
      wr_entry.meta.pcpn[i]         = wr_pcpn[i];
      for (int j = 0; j < TN_MAX; j++) begin
        wr_entry.meta.tage_idx[i][j] = wr_tage_idx[i][j];
        wr_entry.meta.tage_tag[i][j] = wr_tage_tag[i][j];
      end
      rd_predict_dir[i]       = rd_entry.predict_dir[i];
      rd_alt_pred[i]          = rd_entry.meta.alt_pred[i];
      rd_altpcpn[i]           = rd_entry.meta.altpcpn[i];
      rd_pcpn[i]              = rd_entry.meta.pcpn[i];
      for (int j = 0; j < TN_MAX; j++) begin
        rd_tage_idx[i][j] = rd_entry.meta.tage_idx[i][j];
        rd_tage_tag[i][j] = rd_entry.meta.tage_tag[i][j];
      end
    end
    wr_entry.bpu_ck                       = wr_bpu_ck;
    rd_bpu_ck                             = rd_entry.bpu_ck;
    wr_entry.meta.predict_base_pc         = wr_predict_base_pc;
    wr_entry.predict_next_fetch_address   = wr_predict_next_fetch_address;
    rd_predict_base_pc                    = rd_entry.meta.predict_base_pc;
    rd_predict_next_fetch_address         = rd_entry.predict_next_fetch_address;
  end

  front_fifo #(.DEPTH(PTAB_DEPTH), .W($bits(ptab_entry_t)), .FULL_AT(PTAB_FULL_AT),
                  .BYPASS((FE_RFAST & 2) != 0)) u_fifo (
    .clk, .rst_n,
    .clear   (refetch),
    .rd_en, .wr_en, .drop_tail(1'b0),
    .wdata   (wr_entry),
    .rd_valid,
    .rdata   (rd_entry),
    .full, .empty, .size
  );

endmodule

`default_nettype wire
