// Ref: front-end/fifo/PTAB.cpp  PTAB_comb + model; front_top.cpp ptab_write_data
`default_nettype none

// PTAB: queue of BPU predictions (one per fetch group, compact 2-taken {is_pair, base_b, a_len}, no bpu_ck).
module ptab import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    refetch,
  input  logic                    rd_en,
  input  logic                    wr_en,
  input  logic [XLEN_BITS-1:0]    wr_predict_next_fetch_address,
  input  logic [FETCH_WIDTH-1:0]  wr_predict_dir,
  input  logic [XLEN_BITS-1:0]    wr_predict_base_pc,
  input  logic                    wr_is_pair,
  input  logic [XLEN_BITS-1:0]    wr_base_b,
  input  logic [3:0]              wr_a_len,
  input  logic [FETCH_WIDTH-1:0]  wr_alt_pred,
  input  logic [PCPN_W-1:0]       wr_pcpn        [FETCH_WIDTH],
  input  logic [BLK_ID_W-1:0]     wr_blk_id,
  output logic                    rd_valid,
  output logic [XLEN_BITS-1:0]    rd_predict_next_fetch_address,
  output logic [FETCH_WIDTH-1:0]  rd_predict_dir,
  output logic [XLEN_BITS-1:0]    rd_predict_base_pc,
  output logic                    rd_is_pair,
  output logic [XLEN_BITS-1:0]    rd_base_b,
  output logic [3:0]              rd_a_len,
  output logic [FETCH_WIDTH-1:0]  rd_alt_pred,
  output logic [PCPN_W-1:0]       rd_pcpn        [FETCH_WIDTH],
  output logic [BLK_ID_W-1:0]     rd_blk_id,
  output logic                    full,
  output logic                    empty,
  output logic [$clog2(PTAB_DEPTH + 1)-1:0] size
);

  ptab_entry_t wr_entry;
  ptab_entry_t rd_entry;

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      wr_entry.predict_dir[i]   = wr_predict_dir[i];
      wr_entry.meta.alt_pred[i] = wr_alt_pred[i];
      wr_entry.meta.pcpn[i]     = wr_pcpn[i];
      rd_predict_dir[i]         = rd_entry.predict_dir[i];
      rd_alt_pred[i]            = rd_entry.meta.alt_pred[i];
      rd_pcpn[i]                = rd_entry.meta.pcpn[i];
    end
    wr_entry.is_pair                    = wr_is_pair;
    wr_entry.base_b                     = wr_base_b;
    wr_entry.a_len                      = wr_a_len;
    wr_entry.meta.blk_id                = wr_blk_id;
    wr_entry.meta.predict_base_pc       = wr_predict_base_pc;
    wr_entry.predict_next_fetch_address = wr_predict_next_fetch_address;
    rd_is_pair                          = rd_entry.is_pair;
    rd_base_b                           = rd_entry.base_b;
    rd_a_len                            = rd_entry.a_len;
    rd_blk_id                           = rd_entry.meta.blk_id;
    rd_predict_base_pc                  = rd_entry.meta.predict_base_pc;
    rd_predict_next_fetch_address       = rd_entry.predict_next_fetch_address;
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic head_fresh_unused;
  /* verilator lint_on UNUSEDSIGNAL */

  front_fifo #(.DEPTH(PTAB_DEPTH), .W($bits(ptab_entry_t)), .FULL_AT(PTAB_FULL_AT),
                  .BYPASS((FE_RFAST & 2) != 0)) u_fifo (
    .clk, .rst_n,
    .clear   (refetch),
    .rd_en, .wr_en, .drop_tail(1'b0),
    .wdata   (wr_entry),
    .rd_valid,
    .rdata   (rd_entry),
    .full, .empty, .size, .head_fresh(head_fresh_unused)
  );

endmodule

`default_nettype wire
