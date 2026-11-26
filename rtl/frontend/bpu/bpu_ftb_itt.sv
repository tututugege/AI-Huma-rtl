// Ref: front-end/BPU/BpuFtb.h  struct BlockItt (single block-level 3-table indirect target table, strict sync 1R1W SRAM)
`default_nettype none

module bpu_ftb_itt import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; #(
  parameter int    N_ENT   = FTB_ITT_N,
  parameter bit    HAS_RD2 = 1'b0,
  /* verilator lint_off UNUSEDPARAM */
  parameter [255:0] TAG    = "BPU_ITT"
  /* verilator lint_on UNUSEDPARAM */
) (
  input  logic                 clk,
  input  logic                 rst_n,
  // Predict sync read launch (1-cycle latency; WF=0 READ_FIRST)
  input  logic                 rd_en,
  input  logic                 rd2_en,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ftb_ix_t              rd_ix,
  input  ftb_ix_t              rd2_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  output ftb_itt_raw_t         rd_raw,
  output ftb_itt_raw_t         rd2_raw,
  // T0 sync read launch for commit update (WF=1 WRITE_FIRST)
  input  logic                 t0_upd_en,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ftb_ix_t              t0_upd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  // T1 single-branch commit update execute & write
  input  logic                 t1_upd_en,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ftb_ix_t              t1_upd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [XLEN_BITS-1:0] t1_upd_target
);

  localparam int IDX_W = $clog2(N_ENT);
  localparam int N_RD  = HAS_RD2 ? 3 : 2;
  localparam logic [N_RD-1:0] WF_MASK = N_RD'(3'b010);

  logic             rd_en_v [NITT][N_RD];
  logic [IDX_W-1:0] rd_addr [NITT][N_RD];
  ftb_itt_ent_t     rd_data [NITT][N_RD];
  logic             wr_en   [NITT];
  logic [IDX_W-1:0] wr_addr [NITT];
  ftb_itt_ent_t     wr_data [NITT];

  for (genvar k = 0; k < NITT; k++) begin : g_tbl
    bpu_sram_sync #(
      .W      ($bits(ftb_itt_ent_t)),
      .DEPTH  (N_ENT),
      .N_RD   (N_RD),
      .T      (ftb_itt_ent_t),
      .WF_MASK(WF_MASK),
      .TAG    (TAG)
    ) u_mem (
      .clk,
      .rd_en(rd_en_v[k]), .rd_addr(rd_addr[k]), .rd_data(rd_data[k]),
      .wr_en(wr_en[k]), .wr_addr(wr_addr[k]), .wr_data(wr_data[k])
    );
  end

  if (HAS_RD2) begin : g_rd2
    always_comb begin
      for (int k = 0; k < NITT; k++) begin
        rd_en_v[k][2] = rd2_en;
        rd_addr[k][2] = rd2_ix.idx[ITT_TBL[k]][IDX_W-1:0];
        rd2_raw[k]    = rd_data[k][2];
      end
    end
  end else begin : g_nord2
    assign rd2_raw = '0;
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_rd2;
    assign unused_rd2 = rd2_en;
    /* verilator lint_on UNUSEDSIGNAL */
  end

  logic         hit_found, correct, alloc_found;
  logic [1:0]   hit_k, start_k, alloc_k;
  ftb_itt_ent_t hit_ent_new;
  logic [1:0]   conf_dec;

  always_comb begin
    for (int k = 0; k < NITT; k++) begin
      rd_en_v[k][0] = rd_en;
      rd_en_v[k][1] = t0_upd_en;
      rd_addr[k][0] = rd_ix.idx[ITT_TBL[k]][IDX_W-1:0];
      rd_addr[k][1] = t0_upd_ix.idx[ITT_TBL[k]][IDX_W-1:0];
      rd_raw[k]     = rd_data[k][0];
    end

    hit_found = 1'b0;
    hit_k     = 2'd0;
    for (int k = 0; k < NITT; k++) begin
      if (rd_data[k][1].valid && (rd_data[k][1].tag == t1_upd_ix.tag[ITT_TBL[k]])) begin
        hit_found = 1'b1;
        hit_k     = 2'(k);
      end
    end

    correct     = hit_found && (rd_data[hit_k][1].target == t1_upd_target);
    hit_ent_new = rd_data[hit_k][1];
    conf_dec    = (hit_ent_new.conf > 2'd0) ? (hit_ent_new.conf - 2'd1) : 2'd0;
    if (correct) begin
      hit_ent_new.conf = (hit_ent_new.conf < 2'd3) ? (hit_ent_new.conf + 2'd1) : 2'd3;
      hit_ent_new.u    = 1'b1;
    end else begin
      if (conf_dec == 2'd0) begin
        hit_ent_new.target = t1_upd_target;
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
      wr_en[k]   = 1'b0;
      wr_addr[k] = t1_upd_ix.idx[ITT_TBL[k]][IDX_W-1:0];
      wr_data[k] = rd_data[k][1];
      if (t1_upd_en) begin
        if (hit_found && (2'(k) == hit_k)) begin
          wr_en[k]   = 1'b1;
          wr_data[k] = hit_ent_new;
        end else if (!correct) begin
          if (alloc_found && (2'(k) == alloc_k)) begin
            wr_en[k]   = 1'b1;
            wr_data[k] = '{
              valid:  1'b1,
              tag:    t1_upd_ix.tag[ITT_TBL[k]],
              conf:   2'd1,
              u:      1'b0,
              target: t1_upd_target
            };
          end else if (!alloc_found && (2'(k) >= start_k)) begin
            wr_en[k]     = 1'b1;
            wr_data[k].u = 1'b0;
          end
        end
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_rst;
  assign unused_rst = rst_n;
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
