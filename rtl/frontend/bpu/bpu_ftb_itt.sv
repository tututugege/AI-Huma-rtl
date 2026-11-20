// Ref: front-end/BPU/BpuFtb.h  struct BlockItt (single block-level 3-table indirect target table)
`default_nettype none

module bpu_ftb_itt import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; #(
  parameter int N_ENT = FTB_ITT_N
) (
  input  logic                 clk,
  input  logic                 rst_n,
  // Predict read port
  /* verilator lint_off UNUSEDSIGNAL */
  input  ftb_ix_t              rd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  output ftb_itt_raw_t         rd_raw,
  // Single-branch commit update port
  input  logic                 upd_en,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ftb_ix_t              upd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [XLEN_BITS-1:0] upd_target
);

  localparam int IDX_W = $clog2(N_ENT);

  logic [IDX_W-1:0] rd_addr [NITT][2];
  ftb_itt_ent_t     rd_data [NITT][2];
  logic             wr_en   [NITT][1];
  logic [IDX_W-1:0] wr_addr [NITT][1];
  ftb_itt_ent_t     wr_data [NITT][1];

  for (genvar k = 0; k < NITT; k++) begin : g_tbl
    bpu_mem #(
      .W     ($bits(ftb_itt_ent_t)),
      .DEPTH (N_ENT),
      .N_RD  (2),
      .N_WR  (1),
      .T     (ftb_itt_ent_t)
    ) u_mem (
      .clk, .rst_n,
      .rd_addr(rd_addr[k]), .rd_data(rd_data[k]),
      .wr_en(wr_en[k]), .wr_addr(wr_addr[k]), .wr_data(wr_data[k])
    );
  end

  logic       hit_found, correct, alloc_found;
  logic [1:0] hit_k, start_k, alloc_k;
  ftb_itt_ent_t hit_ent_new;
  logic [1:0]   conf_dec;

  always_comb begin
    for (int k = 0; k < NITT; k++) begin
      rd_addr[k][0] = rd_ix.idx[ITT_TBL[k]][IDX_W-1:0];
      rd_addr[k][1] = upd_ix.idx[ITT_TBL[k]][IDX_W-1:0];
      rd_raw[k]     = rd_data[k][0];
    end

    hit_found = 1'b0;
    hit_k     = 2'd0;
    for (int k = 0; k < NITT; k++) begin
      if (rd_data[k][1].valid && (rd_data[k][1].tag == upd_ix.tag[ITT_TBL[k]])) begin
        hit_found = 1'b1;
        hit_k     = 2'(k);
      end
    end

    correct     = hit_found && (rd_data[hit_k][1].target == upd_target);
    hit_ent_new = rd_data[hit_k][1];
    conf_dec    = (hit_ent_new.conf > 2'd0) ? (hit_ent_new.conf - 2'd1) : 2'd0;
    if (correct) begin
      hit_ent_new.conf = (hit_ent_new.conf < 2'd3) ? (hit_ent_new.conf + 2'd1) : 2'd3;
      hit_ent_new.u    = 1'b1;
    end else begin
      if (conf_dec == 2'd0) begin
        hit_ent_new.target = upd_target;
        hit_ent_new.conf   = 2'd1;
      end else begin
        hit_ent_new.conf   = conf_dec;
      end
      hit_ent_new.u = 1'b0;
    end

    start_k     = hit_found ? (hit_k + 2'd1) : 2'd0;
    alloc_found = 1'b0;
    alloc_k     = 2'd0;
    for (int k = 0; k < NITT; k++) begin
      if (!alloc_found && (2'(k) >= start_k) && (!rd_data[k][1].valid || !rd_data[k][1].u)) begin
        alloc_found = 1'b1;
        alloc_k     = 2'(k);
      end
    end
  end

  always_comb begin
    for (int k = 0; k < NITT; k++) begin
      wr_en[k][0]   = 1'b0;
      wr_addr[k][0] = upd_ix.idx[ITT_TBL[k]][IDX_W-1:0];
      wr_data[k][0] = rd_data[k][1];
      if (upd_en) begin
        if (hit_found && (2'(k) == hit_k)) begin
          wr_en[k][0]   = 1'b1;
          wr_data[k][0] = hit_ent_new;
        end else if (!correct) begin
          if (alloc_found && (2'(k) == alloc_k)) begin
            wr_en[k][0]   = 1'b1;
            wr_data[k][0] = '{
              valid:  1'b1,
              tag:    upd_ix.tag[ITT_TBL[k]],
              conf:   2'd1,
              u:      1'b0,
              target: upd_target
            };
          end else if (!alloc_found && (2'(k) >= start_k)) begin
            wr_en[k][0]     = 1'b1;
            wr_data[k][0].u = 1'b0;
          end
        end
      end
    end
  end

endmodule

`default_nettype wire
